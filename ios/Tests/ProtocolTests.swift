// SPDX-License-Identifier: GPL-3.0-only
import Testing
import Foundation
import Security
import CryptoKit
@testable import anDropProtocol

@Test func pythonCompatibleKeyExchangeAndEncryption() throws {
    var sender = NegotiationKeys(); var receiver = NegotiationKeys()
    try sender.derive(peer: receiver.publicKey); try receiver.derive(peer: sender.publicKey)
    for text in ["", "123", "日本語のファイル.txt", String(repeating: "a", count: 257)] {
        #expect(try receiver.decrypt(sender.encrypt(text)) == text)
        #expect(try sender.decrypt(receiver.encrypt(text)) == text)
    }
    #expect(throws: (any Error).self) { try sender.derive(peer: "invalid") }
    #expect(throws: (any Error).self) { try sender.decrypt("not base64") }
}

@Test func matchesExistingPythonEngineVector() throws {
    // Generated with androp/Sources/engine.py, P-256 private scalars 1 and 2.
    var keys = try NegotiationKeys(rawPrivateKey: Data(repeating: 0, count: 31) + Data([1]))
    try keys.derive(peer: "MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEfPJ7GI0DT36KUjgDBLUaw8CJaeJ38hs1pgtI/EdmmXgHd1UQ247QQCk9msafdDDbun2t5jzpgimeBLedInhz0Q==")
    #expect(try keys.encrypt("anDrop 日本語.txt") == "VPHItBYsPd7Bt1K8vGd/eYW776biBSpsykGGLeZvjUY=")
    #expect(try keys.decrypt("VPHItBYsPd7Bt1K8vGd/eYW776biBSpsykGGLeZvjUY=") == "anDrop 日本語.txt")
}

@Test func rejectsMalformedControlMessages() throws {
    let message = try ControlMessage("action:2:sendRequest?{\"fileCount\":1}")
    #expect(message.payload["fileCount"] as? Int == 1)
    for raw in ["x:2:sendRequest", "ack:-1:status", "action:1", "action:1:x?[]", "action:1:x?null", String(repeating: "x", count: Limits.control + 1)] {
        #expect(throws: (any Error).self) { try ControlMessage(raw) }
    }
}

@Test func onlySupportsLocalEndpoints() {
    for value in ["192.168.1.1", "10.0.0.1", "172.16.0.1", "172.31.255.255", "169.254.1.1"] { #expect(LocalNetwork.isPrivateIPv4(value)) }
    for value in ["127.0.0.1", "8.8.8.8", "172.32.0.1", "192.168.1.999", "192.168.01.1", "::1", "example.com", "10..1.2"] { #expect(!LocalNetwork.isPrivateIPv4(value)) }
}

@Test func rejectsUnsafePaths() throws {
    for raw in ["../bad", "/absolute", "a/../bad", "a//bad", "bad\0name", "bad:name", "a/./bad", "a/", ""] {
        #expect(throws: (any Error).self) { try FileArchive.safeName(raw) }
    }
    #expect(try FileArchive.safeName("folder/日本語.txt") == "日本語.txt")
}

@Test func freshTLSIdentityMatchesCertificate() throws {
    let first = try EphemeralIdentity(); let second = try EphemeralIdentity()
    #expect(first.certificate != second.certificate)
    var certificate: SecCertificate?
    #expect(SecIdentityCopyCertificate(first.identity, &certificate) == errSecSuccess)
    #expect(certificate.map { SecCertificateCopyData($0) as Data } == first.certificate)
}

@Test func archiveRoundtripAndDuplicatePreservation() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let file = root.appending(path: "日本語.txt"); let original = Data("anDrop iOS test\n".utf8)
    try original.write(to: file)
    let empty = root.appending(path: "empty"); try Data().write(to: empty)
    let prepared = try await FileArchive.prepare([file, empty])
    let destination = root.appending(path: "received")
    let first = try await FileArchive.extract(prepared.archive, count: 2, total: original.count, destination: destination)
    let second = try await FileArchive.extract(prepared.archive, count: 2, total: original.count, destination: destination)
    #expect(first[0].url.lastPathComponent == "日本語.txt")
    #expect(second[0].url.lastPathComponent == "日本語 (1).txt")
    #expect(try Data(contentsOf: first[0].url) == original)
    #expect(first[0].sha256 == SHA256.hash(data: original).map { String(format: "%02x", $0) }.joined())
    await #expect(throws: (any Error).self) { try await FileArchive.extract(prepared.archive, count: 1, total: original.count, destination: destination) }
    await #expect(throws: (any Error).self) { try await FileArchive.extract(prepared.archive, count: 2, total: original.count - 1, destination: destination) }
    var corrupted = prepared.archive
    let content = try #require(corrupted.range(of: original))
    corrupted[content.lowerBound] ^= 1
    await #expect(throws: (any Error).self) { try await FileArchive.extract(corrupted, count: 2, total: original.count, destination: destination) }
}

@Test @MainActor func standardWebSocketUpgrade() throws {
    #expect(WebSocket.acceptKey("dGhlIHNhbXBsZSBub25jZQ==") == "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")
    #expect(throws: (any Error).self) { try HTTPHead(Data("HTTP/1.1 200 OK\r\nContent-Length: 4\r\nContent-Length: 9".utf8)) }
}

@Test func rejectsMalformedHTTPChunkSizesWithoutTrapping() throws {
    #expect(try HTTPHead.chunkSize(Data("a;fixture=yes\r\n".utf8), remaining: 10) == 10)
    #expect(try HTTPHead.chunkSize(Data("0\r\n".utf8), remaining: 0) == 0)
    for line in ["\r\n", ";abc\r\n", "-1\r\n", "garbage\r\n", "100\r\n", "FFFFFFFFFFFFFFFFFFFFFFFF\r\n", "1\n"] {
        #expect(throws: (any Error).self) { try HTTPHead.chunkSize(Data(line.utf8), remaining: 10) }
    }
}
