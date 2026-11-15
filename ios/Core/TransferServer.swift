// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Network
import Security

@MainActor public final class TransferServer {
    public let taskID = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    public private(set) var port: UInt16 = 0
    public var awaitingConfirmation: Bool { downloaded && !acknowledged }
    private var authorization: SendPeerAuthorization
    public var onStage: ((String) -> Void)?
    public var onComplete: (() -> Void)?
    public var onFailure: (((any Error)) -> Void)?
    public var onProgress: ((Int, Int?) -> Void)?
    private let files: PreparedFiles
    private let senderName: String
    private let network: WiFiIPv4Address
    private let identity: EphemeralIdentity
    private var listener: NWListener?
    private var sockets: [TLSSocket] = []
    private var websocket: WebSocket?
    private var offered = false
    private var downloaded = false
    private var acknowledged = false
    private var completed = false
    private var activeDownload = false
    private var startContinuation: CheckedContinuation<Void, any Error>?
    private var bandwidthTask: Task<Void, Never>?
    private var running = false
    private let minimumChunkInterval: Duration
    public init(files: PreparedFiles, senderName: String, network: WiFiIPv4Address, minimumChunkInterval: Duration = .zero) throws {
        guard LocalNetwork.isPrivateIPv4(network.address) else { throw SendRouteError.noWiFiIPv4 }
        self.files = files; self.senderName = senderName; self.network = network
        self.minimumChunkInterval = minimumChunkInterval
        authorization = SendPeerAuthorization(network: network)
        identity = try EphemeralIdentity()
    }
    public func confirmPeer(_ host: String) throws {
        try authorization.confirm(host)
        onStage?("send_lan_confirmed")
    }
    public func start() async throws {
        running = true
        let tls = NWProtocolTLS.Options()
        guard let value = sec_identity_create(identity.identity) else { throw TransferFailure.invalid("TLS identity is unavailable.") }
        sec_protocol_options_set_local_identity(tls.securityProtocolOptions, value)
        let parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(network.address), port: .any)
        let listener = try NWListener(using: parameters, on: .any)
        self.listener = listener
        try await withCheckedThrowingContinuation { continuation in
            startContinuation = continuation
            listener.stateUpdateHandler = { [weak self] state in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    switch state {
                    case .ready:
                        self.port = listener.port?.rawValue ?? 0
                        let pending = self.startContinuation; self.startContinuation = nil; pending?.resume()
                    case .failed(let error):
                        let pending = self.startContinuation; self.startContinuation = nil; pending?.resume(throwing: error)
                        self.onFailure?(error)
                    case .cancelled:
                        let pending = self.startContinuation; self.startContinuation = nil; pending?.resume(throwing: TransferFailure.closed)
                    default: break
                    }
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                MainActor.assumeIsolated { self?.accept(connection) }
            }
            listener.start(queue: .main)
        }
    }
    public func stop() {
        running = false; onFailure = nil; onComplete = nil; onStage = nil; onProgress = nil
        bandwidthTask?.cancel(); bandwidthTask = nil
        listener?.cancel(); listener = nil
        for socket in sockets { socket.close() }; sockets.removeAll(); websocket = nil
    }
    private func accept(_ connection: NWConnection) {
        guard case .hostPort(let host, _) = connection.endpoint,
              authorization.allowsConnection(from: String(describing: host)), sockets.count < 4 else { connection.cancel(); return }
        let peerHost = String(describing: host)
        let socket = TLSSocket(accepted: connection); sockets.append(socket)
        Task {
            defer { socket.close(); sockets.removeAll { $0 === socket } }
            do { try await socket.start(); try await handle(socket, peerHost: peerHost) }
            catch { if running && !acknowledged { onFailure?(downloaded ? TransferFailure.completionUnconfirmed : error) } }
        }
    }
    private func handle(_ socket: TLSSocket, peerHost: String) async throws {
        let head = try await socket.headers()
        let pieces = head.firstLine.split(separator: " ")
        guard pieces.count == 3, pieces[0] == "GET", pieces[2] == "HTTP/1.1" else { throw TransferFailure.invalid("Invalid transfer request.") }
        let path = String(pieces[1])
        if path == "/websocket", websocket == nil, head.fields["upgrade"]?.lowercased() == "websocket",
           let key = head.fields["sec-websocket-key"], Data(base64Encoded: key)?.count == 16 {
            try authorization.registerControl(from: peerHost)
            let ws = WebSocket(socket: socket, client: false); websocket = ws
            try await socket.send(Data("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(WebSocket.acceptKey(key))\r\n\r\n".utf8))
            onStage?("control_connected")
            bandwidthTask = Task { [weak self] in
                guard let self, port < 65535 else { return }
                let udp = NWConnection(host: NWEndpoint.Host(peerHost), port: NWEndpoint.Port(rawValue: port + 1)!, using: .udp)
                udp.start(queue: .main)
                defer { udp.cancel() }
                do {
                    try await Task.sleep(for: .milliseconds(150))
                    for _ in 0..<256 {
                        try Task.checkCancellation()
                        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                            udp.send(content: Data(count: 4096), completion: .contentProcessed { error in
                                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                            })
                        }
                        try await Task.sleep(for: .milliseconds(1))
                    }
                } catch { /* Bandwidth probes are advisory; the TLS channel remains usable. */ }
            }
            try await ws.send(ControlMessage(kind: "action", index: 0, name: "wlanBandwidth"))
            while true {
                let message = try await ws.next()
                if message.kind == "ack", message.name == "wlanBandwidth" {
                    try await ws.send(ControlMessage(kind: "action", index: 1, name: "versionNegotiation", payload: ["versions": [1], "version": 1]))
                } else if message.kind == "ack", message.name == "versionNegotiation" {
                    // GATT confirmation and the TCP connection can arrive in either order.
                    for _ in 0..<80 {
                        if authorization.confirmedHost != nil { break }
                        try await Task.sleep(for: .milliseconds(100))
                    }
                    guard authorization.allowsDownload(from: peerHost) else { throw SendRouteError.peerMismatch }
                    offered = true
                    try await ws.send(ControlMessage(kind: "action", index: 2, name: "sendRequest", payload: files.sendRequest(taskID: taskID, senderName: senderName)))
                    onStage?("awaiting_acceptance")
                } else if message.kind == "action" {
                    if message.name == "status", message.payload["taskId"] as? String == taskID {
                        if message.payload["type"] as? Int == 1 { acknowledged = true; completeIfReady() }
                        else if [2, 3].contains(message.payload["type"] as? Int ?? 0) { throw TransferFailure.declined }
                    }
                    // A peer can close immediately after reporting successful receipt.
                    // Record that confirmation before attempting its best-effort ACK.
                    try await ws.send(ControlMessage(kind: "ack", index: message.index, name: message.name, payload: message.payload))
                }
            }
        } else if path == "/download?taskId=\(taskID)", offered, authorization.allowsDownload(from: peerHost), !activeDownload, !downloaded {
            activeDownload = true
            defer { activeDownload = false }
            try await socket.send(Data("HTTP/1.1 200 OK\r\nContent-Type: application/zip\r\nContent-Length: \(files.archive.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n".utf8))
            onStage?("sending_archive")
            onProgress?(0, files.archive.count)
            for offset in stride(from: 0, to: files.archive.count, by: 65_536) {
                let end = min(offset + 65_536, files.archive.count)
                try await socket.send(Data(files.archive[offset..<end]))
                onProgress?(end, files.archive.count)
                if minimumChunkInterval > .zero { try await Task.sleep(for: minimumChunkInterval) }
            }
            downloaded = true; onStage?("awaiting_confirmation"); completeIfReady()
        } else { try await socket.send(Data("HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)) }
    }
    private func completeIfReady() {
        guard downloaded, acknowledged, !completed else { return }
        completed = true; onStage?("send_complete"); onComplete?()
    }
}
