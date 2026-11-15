// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Network

/// Plain TCP carries Huawei's independently authenticated encrypted messages.
/// One consumer reads each socket; cancellation closes pending network reads.
@MainActor final class HuaweiSocket {
    let connection: NWConnection
    private var buffer = Data()
    private var ready: CheckedContinuation<Void, any Error>?
    init(host: String, port: UInt16, udp: Bool = false) {
        let parameters = udp ? NWParameters.udp : NWParameters.tcp
        if udp { parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.any), port: 5684) }
        connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: parameters)
    }
    func start() async throws {
        try Task.checkCancellation()
        try await withCheckedThrowingContinuation { continuation in
            ready = continuation
            connection.stateUpdateHandler = { [weak self] state in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    switch state {
                    case .ready: self.finishStart(nil)
                    case .failed(let error): self.finishStart(error)
                    case .cancelled: self.finishStart(TransferFailure.closed)
                    default: break
                    }
                }
            }
            connection.start(queue: .main)
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(5))
                if self?.ready != nil { self?.finishStart(TransferFailure.timeout); self?.close() }
            }
        }
        try Task.checkCancellation()
    }
    private func finishStart(_ error: (any Error)?) {
        let pending = ready; ready = nil
        if let error { pending?.resume(throwing: error) } else { pending?.resume() }
    }
    func close() { connection.cancel() }
    func send(_ data: Data) async throws {
        try Task.checkCancellation()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }
    private func receive(datagram: Bool = false, timeout: Duration = .seconds(35)) async throws -> Data {
        try Task.checkCancellation()
        let deadline = Task { [weak self] in
            do { try await Task.sleep(for: timeout); self?.close() } catch { }
        }
        defer { deadline.cancel() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let complete: @Sendable (Data?, NWConnection.ContentContext?, Bool, NWError?) -> Void = { data, _, _, error in
                    if let data, !data.isEmpty { continuation.resume(returning: data) }
                    else { continuation.resume(throwing: error ?? TransferFailure.closed) }
                }
                if datagram { connection.receiveMessage(completion: complete) }
                else { connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536, completion: complete) }
            }
        } onCancel: { [connection] in connection.cancel() }
    }
    func datagram() async throws -> Data { try await receive(datagram: true, timeout: .seconds(4)) }
    func read(_ count: Int) async throws -> Data {
        guard (0...1_048_604).contains(count) else { throw HuaweiFailure.invalid }
        while buffer.count < count { buffer.append(try await receive()) }
        let data = Data(buffer.prefix(count)); buffer.removeFirst(count); return data
    }
    func frame() async throws -> Data {
        let bytes = try await read(24); let header = try HuaweiWire.Header(bytes)
        guard header.magic == HuaweiWire.magic, header.size <= 65_536 else { throw HuaweiFailure.invalid }
        return try await bytes + read(header.size)
    }
    func dfile() async throws -> (Data, Data) {
        let header = try await read(8); var reader = HuaweiReader(header)
        let kind = try reader.integer(1); _ = try reader.take(5); let size = Int(try reader.integer(2))
        guard (1...14).contains(kind), size <= 14_720 else { throw HuaweiFailure.invalid }
        return try await (header, read(size))
    }
    func preview(key: Data) async throws -> Data {
        var reader = HuaweiReader(try await read(16))
        guard try reader.integer(4, little: true) == HuaweiWire.magic else { throw HuaweiFailure.invalid }
        _ = try reader.take(4)
        guard try reader.integer(4, little: true) == 0 else { throw HuaweiFailure.invalid }
        let size = Int(try reader.integer(4, little: true))
        guard (28...1_048_604).contains(size) else { throw HuaweiFailure.invalid }
        let payload = try await read(size)
        return try HuaweiWire.open(Data(payload.dropFirst(12)), key: key, nonce: Data(payload.prefix(12)))
    }
}
