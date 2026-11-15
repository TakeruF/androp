// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Network
import Security
import CryptoKit

@MainActor public final class TLSSocket {
    public let connection: NWConnection
    public private(set) var peerCertificate: Data?
    private var buffer = Data()
    private var ready: CheckedContinuation<Void, any Error>?
    private var closed = false
    public init(accepted: NWConnection) { connection = accepted }
    public init(host: String, port: UInt16, pin: Data? = nil) {
        let tls = NWProtocolTLS.Options()
        // The first control certificate is session-pinned for the HTTP download.
        // The protocol itself does not provide an independently trusted identity.
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, trust, complete in
            let value = sec_trust_copy_ref(trust).takeRetainedValue()
            guard let chain = SecTrustCopyCertificateChain(value) as? [SecCertificate], let first = chain.first else { complete(false); return }
            let bytes = SecCertificateCopyData(first) as Data
            complete(pin == nil || bytes == pin)
        }, .main)
        let parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: parameters)
    }
    public func start() async throws {
        try await withCheckedThrowingContinuation { continuation in
            ready = continuation
            connection.stateUpdateHandler = { [weak self] state in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    switch state {
                    case .ready:
                        if let metadata = self.connection.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata {
                            sec_protocol_metadata_access_peer_certificate_chain(metadata.securityProtocolMetadata) { certificate in
                                if self.peerCertificate == nil { self.peerCertificate = sec_certificate_copy_ref(certificate).takeRetainedValue().data }
                            }
                        }
                        self.finishStart(nil)
                    case .failed(let error): self.finishStart(error)
                    case .cancelled: self.finishStart(TransferFailure.closed)
                    default: break
                    }
                }
            }
            connection.start(queue: .main)
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(10))
                if self?.ready != nil { self?.finishStart(TransferFailure.timeout); self?.close() }
            }
        }
    }
    private func finishStart(_ error: (any Error)?) {
        let pending = ready; ready = nil
        if let error { pending?.resume(throwing: error) } else { pending?.resume() }
    }
    public func close() { closed = true; connection.cancel() }
    public func send(_ data: Data) async throws {
        guard !closed else { throw TransferFailure.closed }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }
    private func receive() async throws -> Data {
        guard !closed else { throw TransferFailure.closed }
        let deadline = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(35)); self?.close() } catch { }
        }
        defer { deadline.cancel() }
        return try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { bytes, _, _, error in
                if let bytes, !bytes.isEmpty { continuation.resume(returning: bytes) }
                else { continuation.resume(throwing: error ?? TransferFailure.closed) }
            }
        }
    }
    public func read(_ count: Int) async throws -> Data {
        guard count >= 0, count <= Limits.archive else { throw TransferFailure.invalid("Invalid network read size.") }
        while buffer.count < count { buffer.append(try await receive()) }
        let result = Data(buffer.prefix(count)); buffer.removeFirst(count); return result
    }
    public func headers() async throws -> HTTPHead {
        let separator = Data("\r\n\r\n".utf8)
        while true {
            if let range = buffer.range(of: separator) {
                guard range.upperBound <= 8192 else { throw TransferFailure.invalid("HTTP headers are too large.") }
                let value = Data(buffer[..<range.lowerBound]); buffer.removeSubrange(..<range.upperBound)
                return try HTTPHead(value)
            }
            guard buffer.count < 8192 else { throw TransferFailure.invalid("HTTP headers are too large.") }
            buffer.append(try await receive())
        }
    }
    public func download(host: String, port: UInt16, taskID: String, maximum: Int, progress: (Int, Int?) -> Void = { _, _ in }) async throws -> Data {
        guard taskID.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }), taskID.count <= 256 else { throw TransferFailure.invalid("Invalid transfer identifier.") }
        try await send(Data("GET /download?taskId=\(taskID) HTTP/1.1\r\nHost: \(host):\(port)\r\nConnection: close\r\n\r\n".utf8))
        let head = try await headers()
        guard head.firstLine.hasPrefix("HTTP/1.1 200 ") || head.firstLine.hasPrefix("HTTP/1.0 200 ") else { throw TransferFailure.invalid("The download was rejected.") }
        if let raw = head.fields["content-length"], let size = Int(raw), (0...maximum).contains(size), head.fields["transfer-encoding"] == nil {
            var result = Data(); progress(0, size)
            while result.count < size {
                result.append(try await read(min(65_536, size - result.count)))
                progress(result.count, size)
            }
            return result
        }
        guard head.fields["transfer-encoding"]?.lowercased() == "chunked", head.fields["content-length"] == nil else { throw TransferFailure.invalid("Missing or invalid archive length.") }
        var result = Data()
        while true {
            var line = Data()
            while !line.suffix(2).elementsEqual([13,10]) {
                guard line.count < 128 else { throw TransferFailure.invalid("Invalid HTTP chunk.") }
                line.append(try await read(1))
            }
            let size = try HTTPHead.chunkSize(line, remaining: maximum - result.count)
            if size == 0 { break }
            result.append(try await read(size))
            progress(result.count, nil)
            guard try await read(2) == Data([13,10]) else { throw TransferFailure.invalid("Invalid HTTP chunk ending.") }
        }
        return result
    }
}

private extension SecCertificate { var data: Data { SecCertificateCopyData(self) as Data } }

public struct HTTPHead {
    public let firstLine: String
    public let fields: [String: String]
    static func chunkSize(_ line: Data, remaining: Int) throws -> Int {
        guard line.count <= 128, line.suffix(2) == Data([13,10]),
              let text = String(data: line.dropLast(2), encoding: .utf8),
              let digits = text.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false).first,
              !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isHexDigit }),
              let size = Int(digits, radix: 16), size <= remaining else { throw TransferFailure.invalid("Invalid or oversized HTTP chunk.") }
        return size
    }
    public init(_ bytes: Data) throws {
        guard bytes.count <= 8192, let text = String(data: bytes, encoding: .utf8) else { throw TransferFailure.invalid("Invalid HTTP header.") }
        let lines = text.components(separatedBy: "\r\n")
        guard let first = lines.first, !first.isEmpty else { throw TransferFailure.invalid("Missing HTTP start line.") }
        firstLine = first
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { throw TransferFailure.invalid("Invalid HTTP header field.") }
            let key = parts[0].lowercased()
            guard headers[key] == nil else { throw TransferFailure.invalid("Duplicate HTTP header field.") }
            headers[key] = parts[1].trimmingCharacters(in: .whitespaces)
        }
        fields = headers
    }
}

@MainActor public final class WebSocket {
    public let socket: TLSSocket
    private let client: Bool
    public init(socket: TLSSocket, client: Bool) { self.socket = socket; self.client = client }
    public static func acceptKey(_ key: String) -> String {
        Data(Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))).base64EncodedString()
    }
    public func upgrade(host: String, port: UInt16) async throws {
        let key = Data((0..<16).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
        try await socket.send(Data("GET /websocket HTTP/1.1\r\nHost: \(host):\(port)\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: \(key)\r\nSec-WebSocket-Version: 13\r\n\r\n".utf8))
        let response = try await socket.headers()
        guard response.firstLine.hasPrefix("HTTP/1.1 101 "), response.fields["sec-websocket-accept"] == Self.acceptKey(key),
              response.fields["upgrade"]?.lowercased() == "websocket" else { throw TransferFailure.invalid("WebSocket upgrade failed.") }
    }
    public func send(_ message: ControlMessage) async throws { try await frame(Data(message.encoded().utf8), opcode: 1) }
    public func frame(_ payload: Data, opcode: UInt8) async throws {
        guard payload.count <= Limits.control else { throw TransferFailure.invalid("WebSocket frame is too large.") }
        var bytes = Data([0x80 | opcode]); let flag: UInt8 = client ? 0x80 : 0
        if payload.count < 126 { bytes.append(flag | UInt8(payload.count)) }
        else if payload.count <= 65535 { bytes.append(flag | 126); bytes.append(contentsOf: [UInt8(payload.count >> 8), UInt8(payload.count & 255)]) }
        else { bytes.append(flag | 127); bytes.append(contentsOf: (0..<8).reversed().map { UInt8((UInt64(payload.count) >> ($0 * 8)) & 255) }) }
        if client {
            let mask = (0..<4).map { _ in UInt8.random(in: 0...255) }; bytes.append(contentsOf: mask)
            bytes.append(contentsOf: payload.enumerated().map { $0.element ^ mask[$0.offset % 4] })
        } else { bytes.append(payload) }
        try await socket.send(bytes)
    }
    public func next() async throws -> ControlMessage {
        var message = Data(); var started = false
        while true {
            let prefix = [UInt8](try await socket.read(2)); let opcode = prefix[0] & 15
            guard prefix[0] & 0x70 == 0, (prefix[1] & 0x80 != 0) == !client else { throw TransferFailure.invalid("Invalid WebSocket frame.") }
            var size = UInt64(prefix[1] & 127)
            if size == 126 { size = try await socket.read(2).reduce(UInt64(0)) { $0 << 8 | UInt64($1) } }
            if size == 127 { size = try await socket.read(8).reduce(UInt64(0)) { $0 << 8 | UInt64($1) } }
            guard size <= UInt64(Limits.control) else { throw TransferFailure.invalid("WebSocket frame exceeds its limit.") }
            let final = prefix[0] & 0x80 != 0
            if opcode >= 8, (!final || size > 125) { throw TransferFailure.invalid("Invalid WebSocket control frame.") }
            let mask = !client ? [UInt8](try await socket.read(4)) : []
            var payload = try await socket.read(Int(size))
            if !client { payload = Data(payload.enumerated().map { $0.element ^ mask[$0.offset % 4] }) }
            if opcode == 8 { throw TransferFailure.closed }
            if opcode == 9 { try await frame(payload, opcode: 10); continue }
            if opcode == 10 { continue }
            guard (opcode == 1 || opcode == 2) && !started || opcode == 0 && started else { throw TransferFailure.invalid("Invalid WebSocket continuation.") }
            started = true
            guard payload.count <= Limits.control - message.count else { throw TransferFailure.invalid("Control message exceeds its limit.") }
            message.append(payload)
            if final {
                guard let text = String(data: message, encoding: .utf8) else { throw TransferFailure.invalid("Invalid control encoding.") }
                return try ControlMessage(text)
            }
        }
    }
}
