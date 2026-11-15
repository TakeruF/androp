// SPDX-License-Identifier: GPL-3.0-only
import Foundation

public struct IncomingOffer: Identifiable {
    public let id: String
    public let sender: String
    public let name: String
    public let count: Int
    public let total: Int
    public let mime: String
}

@MainActor public final class TransferReceiver {
    private var sockets: [TLSSocket] = []
    public var onStage: ((String) -> Void)?
    public var onProgress: ((Int, Int?) -> Void)?
    public init() { }
    public func stop() { for socket in sockets { socket.close() }; sockets.removeAll() }
    public func receive(host: String, port: UInt16, expectedCount: Int, destination: URL,
                        approve: @MainActor (IncomingOffer) async -> Bool) async throws -> [ReceivedFile] {
        guard LocalNetwork.isPrivateIPv4(host), port > 0, port < 65535, (1...Limits.files).contains(expectedCount) else { throw TransferFailure.invalid("Unsupported local transfer endpoint.") }
        let control = TLSSocket(host: host, port: port); sockets.append(control)
        defer { stop() }
        onStage?("connecting_control")
        try await control.start()
        guard let certificate = control.peerCertificate else { throw TransferFailure.invalid("The control channel has no TLS certificate.") }
        let ws = WebSocket(socket: control, client: true)
        try await ws.upgrade(host: host, port: port)
        onStage?("control_connected")
        try await ws.send(ControlMessage(kind: "ack", index: 0, name: "wlanBandwidth", payload: ["speed": "0.00"]))
        var request: ControlMessage?
        for _ in 0..<32 {
            let message = try await ws.next()
            guard message.kind == "action" else { continue }
            if message.name == "sendRequest" { request = message; break }
            let payload: [String: Any] = switch message.name {
            case "wlanBandwidth": ["speed": "0.00"]
            case "versionNegotiation": ["version": 1, "threadLimit": 1]
            default: [:]
            }
            try await ws.send(ControlMessage(kind: "ack", index: message.index, name: message.name, payload: payload))
        }
        guard let request, let identifier = request.payload["id"] as? String,
              !identifier.isEmpty, identifier.count <= 256,
              identifier.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }),
              let count = request.payload["fileCount"] as? Int, count == expectedCount,
              let total = request.payload["totalSize"] as? Int, (0...Limits.bytes).contains(total)
        else { throw TransferFailure.invalid("Invalid or oversized transfer offer.") }
        let offer = IncomingOffer(id: identifier, sender: String((request.payload["senderName"] as? String ?? "Android").prefix(100)),
                                  name: String((request.payload["fileName"] as? String ?? "Files").prefix(240)), count: count, total: total,
                                  mime: FileTypes.normalizedDeclaration(request.payload["mimeType"]))
        onStage?("awaiting_approval")
        guard await approve(offer) else {
            try await ws.send(ControlMessage(kind: "action", index: 101, name: "status", payload: ["taskId": identifier, "type": 3, "reason": "declined"]))
            throw TransferFailure.declined
        }
        try Task.checkCancellation()
        try await ws.send(ControlMessage(kind: "ack", index: request.index, name: request.name))
        onStage?("downloading_archive")
        let download = TLSSocket(host: host, port: port, pin: certificate); sockets.append(download)
        try await download.start()
        let archive = try await download.download(host: host, port: port, taskID: identifier, maximum: min(Limits.archive, total + 1024 * 1024), progress: { [weak self] in self?.onProgress?($0, $1) })
        onStage?("checking_archive")
        let files = try await FileArchive.extract(archive, count: count, total: total, destination: destination)
        try await ws.send(ControlMessage(kind: "action", index: 100, name: "status", payload: ["taskId": identifier, "id": identifier, "type": 1, "reason": "ok"]))
        onStage?("receive_complete")
        return files
    }
}
