// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import CryptoKit
import CommonCrypto

public enum TransferFailure: Error, LocalizedError, Sendable {
    case invalid(String)
    case timeout
    case closed
    case declined
    case completionUnconfirmed
    public var errorDescription: String? {
        switch self {
        case .invalid(let reason): reason
        case .timeout: "The connection timed out. Keep sharing open and try again."
        case .closed: "The other device closed the connection."
        case .declined: "転送が拒否またはキャンセルされました。"
        case .completionUnconfirmed: "ファイルの送信後、相手の受信完了通知を確認できませんでした。相手側の保存結果を確認してください。"
        }
    }
}

public enum Limits {
    public static let files = 16
    public static let byteLimitMiB = 64
    public static let bytes = byteLimitMiB * 1024 * 1024
    public static var summary: String { "\(files)ファイル・合計\(byteLimitMiB)MiBまで" }
    public static let control = 131_072
    public static let archive = bytes + 1024 * 1024
}

/// This derivation and fixed IV reproduce the existing Alliance protocol.
/// They are interoperability requirements, not a new cryptographic design.
public struct NegotiationKeys: Sendable {
    private let privateKey: P256.KeyAgreement.PrivateKey
    private var secret: Data?
    private static let spki = Data([0x30,0x59,0x30,0x13,0x06,0x07,0x2a,0x86,0x48,0xce,0x3d,0x02,0x01,0x06,0x08,0x2a,0x86,0x48,0xce,0x3d,0x03,0x01,0x07,0x03,0x42,0x00])
    public init() { privateKey = .init() }
    init(rawPrivateKey: Data) throws { privateKey = try .init(rawRepresentation: rawPrivateKey) }
    public var publicKey: String { (Self.spki + privateKey.publicKey.x963Representation).base64EncodedString() }
    public mutating func derive(peer: String) throws {
        guard peer.utf8.count <= 1024, let der = Data(base64Encoded: peer), der.count == 91,
              der.starts(with: Self.spki) else { throw TransferFailure.invalid("Invalid peer key.") }
        let key = try P256.KeyAgreement.PublicKey(x963Representation: der.dropFirst(Self.spki.count))
        let shared = try privateKey.sharedSecretFromKeyAgreement(with: key)
        secret = shared.withUnsafeBytes { Data(Data($0).base64EncodedData().prefix(16)) }
    }
    public func encrypt(_ text: String) throws -> String { try crypt(Data(text.utf8), operation: CCOperation(kCCEncrypt)).base64EncodedString() }
    public func decrypt(_ value: String) throws -> String {
        guard value.count <= 65_536, let bytes = Data(base64Encoded: value),
              let text = String(data: try crypt(bytes, operation: CCOperation(kCCDecrypt)), encoding: .utf8)
        else { throw TransferFailure.invalid("Invalid encrypted value.") }
        return text
    }
    private func crypt(_ input: Data, operation: CCOperation) throws -> Data {
        guard let secret else { throw TransferFailure.invalid("Key exchange has not completed.") }
        let iv = Data("0102030405060708".utf8)
        var output = Data(count: input.count + kCCBlockSizeAES128)
        var written = 0
        let capacity = output.count
        let result = output.withUnsafeMutableBytes { destination in
            input.withUnsafeBytes { source in
                secret.withUnsafeBytes { key in
                    iv.withUnsafeBytes { vector in
                        CCCrypt(operation, CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                                key.baseAddress, secret.count, vector.baseAddress, source.baseAddress,
                                input.count, destination.baseAddress, capacity, &written)
                    }
                }
            }
        }
        guard result == kCCSuccess else { throw TransferFailure.invalid("Invalid encrypted protocol message.") }
        return output.prefix(written)
    }
}

public struct ControlMessage {
    public let kind: String
    public let index: Int
    public let name: String
    public let payload: [String: Any]
    public init(kind: String, index: Int, name: String, payload: [String: Any] = [:]) {
        self.kind = kind; self.index = index; self.name = name; self.payload = payload
    }
    public init(_ raw: String) throws {
        guard raw.utf8.count <= Limits.control else { throw TransferFailure.invalid("Control message is too large.") }
        let parts = raw.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let head = parts[0].split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        guard head.count == 3, ["action", "ack"].contains(String(head[0])),
              !head[1].isEmpty, head[1].allSatisfy({ $0.isASCII && $0.isNumber }),
              let number = Int(head[1]), !head[2].isEmpty else { throw TransferFailure.invalid("Invalid control message.") }
        kind = String(head[0]); index = number; name = String(head[2])
        if parts.count == 2, !parts[1].isEmpty {
            guard let value = try JSONSerialization.jsonObject(with: Data(parts[1].utf8)) as? [String: Any]
            else { throw TransferFailure.invalid("Invalid control payload.") }
            payload = value
        } else { payload = [:] }
    }
    public func encoded() throws -> String {
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys, .withoutEscapingSlashes])
        return "\(kind):\(index):\(name)?" + String(decoding: data, as: UTF8.self)
    }
}

public enum LocalNetwork {
    public static func isPrivateIPv4(_ value: String) -> Bool {
        let fields = value.split(separator: ".", omittingEmptySubsequences: false)
        guard fields.count == 4 else { return false }
        let bytes = fields.compactMap { UInt8($0) }
        guard bytes.count == 4, zip(fields, bytes).allSatisfy({ String($0.1) == $0.0 }) else { return false }
        return bytes[0] == 10 || (bytes[0] == 172 && (16...31).contains(bytes[1])) || (bytes[0] == 192 && bytes[1] == 168) || (bytes[0] == 169 && bytes[1] == 254)
    }
}
