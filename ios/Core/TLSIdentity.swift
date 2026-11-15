// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Security

public struct EphemeralIdentity {
    public let identity: SecIdentity
    public let certificate: Data
    public init() throws {
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey([kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
                                              kSecAttrKeySizeInBits: 256] as CFDictionary, &error),
              let publicKey = SecKeyCopyPublicKey(key),
              let publicBytes = SecKeyCopyExternalRepresentation(publicKey, &error) as Data?
        else { throw TransferFailure.invalid("Could not create the session TLS key.") }
        let algorithm = DER.sequence(Data([0x06,0x08,0x2a,0x86,0x48,0xce,0x3d,0x04,0x03,0x02]))
        let name = DER.sequence(DER.tag(0x31, DER.sequence(Data([0x06,0x03,0x55,0x04,0x03]) + DER.tag(0x0c, Data("anDrop".utf8)))))
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyMMddHHmmss'Z'"
        let now = Date()
        let validity = DER.sequence(DER.tag(0x17, Data(formatter.string(from: now.addingTimeInterval(-60)).utf8)) + DER.tag(0x17, Data(formatter.string(from: now.addingTimeInterval(86400)).utf8)))
        let spki = DER.sequence(Data([0x30,0x13,0x06,0x07,0x2a,0x86,0x48,0xce,0x3d,0x02,0x01,0x06,0x08,0x2a,0x86,0x48,0xce,0x3d,0x03,0x01,0x07]) + DER.tag(0x03, Data([0]) + publicBytes))
        var serial = Data(count: 16)
        let randomResult = serial.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        guard randomResult == errSecSuccess else { throw TransferFailure.invalid("Could not generate a certificate serial.") }
        serial[0] = (serial[0] & 0x7f) | 1
        let body = DER.sequence(Data([0xa0,0x03,0x02,0x01,0x02]) + DER.tag(0x02, serial) + algorithm + name + validity + name + spki)
        guard let signature = SecKeyCreateSignature(key, .ecdsaSignatureMessageX962SHA256, body as CFData, &error) as Data?
        else { throw TransferFailure.invalid("Could not sign the session certificate.") }
        certificate = DER.sequence(body + algorithm + DER.tag(0x03, Data([0]) + signature))
        guard let cert = SecCertificateCreateWithData(nil, certificate as CFData),
              let identity = SecIdentityCreate(nil, cert, key) else { throw TransferFailure.invalid("Could not create the TLS identity.") }
        self.identity = identity
    }
}

private enum DER {
    static func sequence(_ body: Data) -> Data { tag(0x30, body) }
    static func tag(_ tag: UInt8, _ body: Data) -> Data {
        var size = body.count
        var bytes = Data()
        if size < 128 { bytes.append(UInt8(size)) }
        else {
            while size > 0 { bytes.insert(UInt8(size & 255), at: 0); size >>= 8 }
            bytes.insert(0x80 | UInt8(bytes.count), at: 0)
        }
        return Data([tag]) + bytes + body
    }
}
