// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import CryptoKit
import Security

public enum HuaweiFailure: Error, LocalizedError, Sendable {
    case invalid, unsupported, target, discovery, key
    public var errorDescription: String? {
        switch self {
        case .invalid: "Huawei Shareの応答を検証できませんでした。"
        case .unsupported: "この端末のHuawei Share方式にはまだ対応していません。"
        case .target: "同じWi-Fi上の端末のIPv4アドレスを指定してください。"
        case .discovery: "Huawei端末を確認できませんでした。IPアドレスと華為分享の公開設定を確認してください。"
        case .key: "Huawei Shareの鍵を準備できませんでした。"
        }
    }
}

struct HuaweiReader {
    let bytes: [UInt8]
    var offset = 0
    init(_ data: Data) { bytes = Array(data) }
    var remaining: Int { bytes.count - offset }
    mutating func take(_ count: Int) throws -> Data {
        guard count >= 0, count <= remaining else { throw HuaweiFailure.invalid }
        defer { offset += count }
        return Data(bytes[offset..<offset + count])
    }
    mutating func integer(_ size: Int, little: Bool = false) throws -> UInt64 {
        let data = try take(size)
        return (little ? Array(data.reversed()) : Array(data)).reduce(0) { ($0 << 8) | UInt64($1) }
    }
    mutating func variable() throws -> Int {
        var value = 0
        for shift in stride(from: 0, to: 28, by: 7) {
            let byte = Int(try integer(1)); value |= (byte & 127) << shift
            if byte & 128 != 0 { return value }
        }
        throw HuaweiFailure.invalid
    }
}

enum HuaweiWire {
    static let magic: UInt64 = 0xbabeface
    static func number(_ value: UInt64, _ size: Int, little: Bool = false) -> Data {
        Data((0..<size).map { UInt8(truncatingIfNeeded: value >> ((little ? $0 : size - $0 - 1) * 8)) })
    }
    static func variable(_ value: Int) -> Data {
        precondition((0..<(1 << 28)).contains(value))
        var value = value; var output = Data()
        while value >= 128 { output.append(UInt8(value & 127)); value >>= 7 }
        output.append(UInt8(value) | 128); return output
    }
    static func tlv(_ tag: Int, _ data: Data) -> Data { variable(tag) + variable(data.count) + data }
    static func tlv(_ tag: Int, _ text: String) -> Data { tlv(tag, Data(text.utf8)) }
    static func fields(_ data: Data) throws -> [(Int, Data)] {
        var reader = HuaweiReader(data); var output: [(Int, Data)] = []
        while reader.remaining > 0 {
            guard output.count < 32 else { throw HuaweiFailure.invalid }
            let tag = try reader.variable(); let size = try reader.variable()
            output.append((tag, try reader.take(size)))
        }
        return output
    }
    static func unwrap(_ data: Data, tag: Int) throws -> Data {
        let values = try fields(data)
        guard values.count == 1, values[0].0 == tag else { throw HuaweiFailure.invalid }
        return values[0].1
    }
    static func json(_ value: [String: Any], nul: Bool = true) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]) + (nul ? Data([0]) : Data())
    }
    static func object(_ data: Data) throws -> [String: Any] {
        var data = data; if data.last == 0 { data.removeLast() }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw HuaweiFailure.invalid }
        return object
    }
    static func random(_ count: Int) throws -> Data {
        var data = Data(count: count)
        guard data.withUnsafeMutableBytes({ SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!) }) == errSecSuccess else { throw HuaweiFailure.key }
        return data
    }
    static func seal(_ data: Data, key: Data, nonce: Data, aad: Data = Data()) throws -> Data {
        let box = try AES.GCM.seal(data, using: SymmetricKey(data: key), nonce: AES.GCM.Nonce(data: nonce), authenticating: aad)
        return box.ciphertext + box.tag
    }
    static func open(_ data: Data, key: Data, nonce: Data, aad: Data = Data()) throws -> Data {
        guard data.count >= 16 else { throw HuaweiFailure.invalid }
        return try AES.GCM.open(AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: nonce), ciphertext: data.dropLast(16), tag: data.suffix(16)), using: SymmetricKey(data: key), authenticating: aad)
    }
    struct Header {
        let magic: UInt64, module: UInt64, sequence: UInt64, flags: UInt64, size: Int
        init(_ data: Data) throws {
            guard data.count == 24 else { throw HuaweiFailure.invalid }
            var r = HuaweiReader(data)
            magic = try r.integer(4, little: true); module = try r.integer(4, little: true)
            sequence = try r.integer(8, little: true); flags = try r.integer(4, little: true); size = Int(try r.integer(4, little: true))
            guard size <= 1_048_604 else { throw HuaweiFailure.invalid }
        }
    }
    static func frame(_ module: UInt64, _ sequence: UInt64, _ body: Data, magic: UInt64 = magic, flags: UInt64 = 0) -> Data {
        number(magic, 4, little: true) + number(module, 4, little: true) + number(sequence, 8, little: true)
            + number(flags, 4, little: true) + number(UInt64(body.count), 4, little: true) + body
    }
    struct Envelope {
        let hash: Data, mode: Int, metadata: Data, body: Data
        init(_ packet: Data) throws {
            let header = try Header(Data(packet.prefix(24)))
            guard header.magic == HuaweiWire.magic, header.module == 9, header.size == packet.count - 24, header.size <= 65_536 else { throw HuaweiFailure.invalid }
            var reader = HuaweiReader(Data(packet.dropFirst(24)))
            hash = try reader.take(16)
            guard try reader.variable() == 1, try reader.variable() == 101 else { throw HuaweiFailure.unsupported }
            mode = try reader.variable(); let size = try reader.variable(); metadata = try reader.take(size)
            let count = try reader.variable(); body = try reader.take(count)
            guard reader.remaining == 0 else { throw HuaweiFailure.invalid }
        }
    }
    static func envelope(_ hash: Data, _ body: Data, sequence: UInt64, mode: Int = 0, metadata: Data = Data()) -> Data {
        frame(9, sequence, hash + variable(1) + variable(101) + variable(mode) + variable(metadata.count) + metadata + variable(body.count) + body)
    }
    static func encrypted(_ hash: Data, _ body: Data, key: Data, sequence: UInt64) throws -> Data {
        let nonce = try random(16)
        return envelope(hash, try seal(body, key: key, nonce: nonce), sequence: sequence, mode: 2, metadata: tlv(1, nonce))
    }
    static func decrypt(_ packet: Data, key: Data) throws -> Data {
        let envelope = try Envelope(packet); let nonce = try unwrap(envelope.metadata, tag: 1)
        guard envelope.mode == 2, [12, 16].contains(nonce.count) else { throw HuaweiFailure.invalid }
        return try open(envelope.body, key: key, nonce: nonce)
    }
    static func channel(_ kind: UInt64, module: UInt64, flags: UInt64 = 0, body: Data, key: Data, sequence: UInt64) throws -> Data {
        let nonce = try random(12)
        return frame(21, sequence, frame(module, sequence, nonce + (try seal(body, key: key, nonce: nonce)), magic: kind, flags: flags))
    }
    static func decodeChannel(_ packet: Data, key: Data) throws -> (Header, Data) {
        let header = try Header(Data(packet.prefix(24)))
        guard header.magic == magic, header.module == 21, header.size == packet.count - 24 else { throw HuaweiFailure.invalid }
        let inner = try Header(Data(packet.dropFirst(24).prefix(24)))
        let data = Data(packet.dropFirst(48))
        guard inner.size == data.count, data.count >= 28 else { throw HuaweiFailure.invalid }
        return (inner, try open(Data(data.dropFirst(12)), key: key, nonce: Data(data.prefix(12))))
    }
    static let dfileAAD = Data(repeating: 65, count: 64)
    static func dfile(_ kind: Int, flags: Int = 0, transaction: Int = 1, body: Data) throws -> Data {
        guard (1...14).contains(kind), (0...255).contains(flags), (0...65_535).contains(transaction), body.count <= 14_720 else { throw HuaweiFailure.invalid }
        return Data([UInt8(kind), UInt8(flags)]) + number(0, 2) + number(UInt64(transaction), 2) + number(UInt64(body.count), 2) + body
    }
    static func dfileControl(_ kind: Int, body: Data, key: Data) throws -> Data {
        let nonce = try random(12)
        let inner = try dfile(kind, body: body)
        return try dfile(kind, body: seal(number(0, 8) + inner, key: Data(key.prefix(16)), nonce: nonce, aad: dfileAAD) + nonce)
    }
    static func decodeDFileControl(_ header: Data, body: Data, key: Data) throws -> Data {
        guard header.count == 8, body.count >= 44 else { throw HuaweiFailure.invalid }
        let plain = try open(Data(body.dropLast(12)), key: Data(key.prefix(16)), nonce: Data(body.suffix(12)), aad: dfileAAD)
        guard plain.count >= 16, plain[8..<14] == header.prefix(6) else { throw HuaweiFailure.invalid }
        var reader = HuaweiReader(Data(plain[14..<16]))
        guard try reader.integer(2) == plain.count - 16 else { throw HuaweiFailure.invalid }
        return Data(plain.dropFirst(16))
    }
}

/// RSA is provided by Security.framework. Keys are not peer/vendor credentials.
/// A stable local key only allows a phone to remember the sender across runs.
public final class HuaweiIdentity {
    let key: SecKey
    let publicDER: Data
    var hash: Data { Data(HMAC<SHA256>.authenticationCode(for: publicDER, using: SymmetricKey(data: publicDER.prefix(16)))) }
    var deviceHash: Data { Data(hash.prefix(8).map { String(format: "%02X", $0) }.joined().utf8) }
    var identity: String { hash.prefix(6).map { String(format: "%02X", $0) }.joined() }
    var nodeID: String { HMAC<SHA256>.authenticationCode(for: Data("anDrop META_NODE_ID\0".utf8) + publicDER, using: SymmetricKey(data: publicDER.prefix(16))).map { String(format: "%02X", $0) }.joined() }
    public init(tag: String? = nil) throws {
        var attributes: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits as String: 2048]
        if let tag {
            let query: [String: Any] = [kSecClass as String: kSecClassKey, kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecAttrApplicationTag as String: Data(tag.utf8), kSecReturnRef as String: true]
            var found: CFTypeRef?
            if SecItemCopyMatching(query as CFDictionary, &found) == errSecSuccess, let found {
                key = (found as! SecKey); publicDER = try Self.export(key); return
            }
            attributes[kSecPrivateKeyAttrs as String] = [kSecAttrIsPermanent as String: true, kSecAttrApplicationTag as String: Data(tag.utf8), kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        }
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else { throw HuaweiFailure.key }
        self.key = key; publicDER = try Self.export(key)
    }
    private static func export(_ key: SecKey) throws -> Data {
        guard let publicKey = SecKeyCopyPublicKey(key), let raw = SecKeyCopyExternalRepresentation(publicKey, nil) as Data? else { throw HuaweiFailure.key }
        // RSA-2048 SubjectPublicKeyInfo prefix around Security's PKCS#1 key.
        guard raw.count == 270 else { throw HuaweiFailure.key }
        return Data([0x30,0x82,0x01,0x22,0x30,0x0d,0x06,0x09,0x2a,0x86,0x48,0x86,0xf7,0x0d,0x01,0x01,0x01,0x05,0x00,0x03,0x82,0x01,0x0f,0x00]) + raw
    }
    func encrypt(_ data: Data, peerDER: Data) throws -> Data {
        let prefix = publicDER.prefix(24)
        guard peerDER.count == 294, peerDER.starts(with: prefix),
              let peer = SecKeyCreateWithData(Data(peerDER.dropFirst(24)) as CFData, [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPublic, kSecAttrKeySizeInBits: 2048] as CFDictionary, nil),
              let encrypted = SecKeyCreateEncryptedData(peer, .rsaEncryptionOAEPSHA256, data as CFData, nil) as Data? else { throw HuaweiFailure.key }
        return encrypted
    }
    func decrypt(_ data: Data) throws -> Data {
        guard data.count == 256, let plain = SecKeyCreateDecryptedData(key, .rsaEncryptionOAEPSHA256, data as CFData, nil) as Data? else { throw HuaweiFailure.invalid }
        return plain
    }
}
