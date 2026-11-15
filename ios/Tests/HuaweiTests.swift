// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import CryptoKit
import Testing
@testable import anDropProtocol

@Test func huaweiVarintsAndFramesRejectTruncationAndOverflow() throws {
    for value in [0, 1, 127, 128, 16_384, (1 << 28) - 1] {
        var reader = HuaweiReader(HuaweiWire.variable(value)); #expect(try reader.variable() == value)
        #expect(reader.remaining == 0)
    }
    #expect(try HuaweiWire.fields(Data()).isEmpty)
    for malformed in [Data([1,2,3,4,5]), Data([0x81,0x8a,0x80])] {
        #expect(throws: (any Error).self) { _ = try HuaweiWire.fields(malformed) }
    }
    let key = Data(repeating: 19, count: 32)
    let frame = try HuaweiWire.encrypted(Data(repeating: 65, count: 16), HuaweiWire.tlv(1, "user_confirm"), key: key, sequence: 1)
    #expect(try HuaweiWire.decrypt(frame, key: key) == HuaweiWire.tlv(1, "user_confirm"))
    var altered = frame; altered[altered.count - 1] ^= 1
    #expect(throws: (any Error).self) { _ = try HuaweiWire.decrypt(altered, key: key) }
    #expect(throws: (any Error).self) { _ = try HuaweiWire.Envelope(frame + Data([0])) }
}

@Test func huaweiDFileAuthenticatesBothContentAndInnerHeader() throws {
    let key = Data(repeating: 51, count: 32)
    let packet = try HuaweiWire.dfileControl(6, body: Data([0,1,0,2]), key: key)
    #expect(try HuaweiWire.decodeDFileControl(Data(packet.prefix(8)), body: Data(packet.dropFirst(8)), key: key) == Data([0,1,0,2]))
    var header = Data(packet.prefix(8)); header[0] = 7
    #expect(throws: (any Error).self) { _ = try HuaweiWire.decodeDFileControl(header, body: Data(packet.dropFirst(8)), key: key) }
    var body = Data(packet.dropFirst(8)); body[0] ^= 1
    #expect(throws: (any Error).self) { _ = try HuaweiWire.decodeDFileControl(Data(packet.prefix(8)), body: body, key: key) }
}

@Test func huaweiRSAExchangeUses2048BitSPKIAndOAEP() throws {
    let sender = try HuaweiIdentity(); let receiver = try HuaweiIdentity()
    let content = try HuaweiWire.random(48)
    let encrypted = try sender.encrypt(content, peerDER: receiver.publicDER)
    #expect(encrypted.count == 256 && receiver.publicDER.count == 294)
    #expect(try receiver.decrypt(encrypted) == content)
    #expect(throws: (any Error).self) { _ = try sender.decrypt(encrypted) }
    #expect(throws: (any Error).self) { _ = try sender.encrypt(content, peerDER: Data([0])) }
    #expect(sender.deviceHash.count == 16 && sender.identity.count == 12 && sender.nodeID.count == 64)
}

@MainActor @Test func huaweiDiscoveryBindsAdvertisedEndpointToDirectedLANPeer() throws {
    let network = WiFiIPv4Address(address: "192.168.25.2", netmask: "255.255.255.0")
    func packet(host: String = "192.168.25.3", service: String = "port:34567,", name: String = "Huawei QA") throws -> Data {
        Data([0x42,0x02,0,1,0,2,0xbd,0x02]) + Data("device_discover".utf8) + Data([0x11,0x32,0xff]) + (try HuaweiWire.json(["wlanIp": host, "bType": 5, "mode": 10, "type": 14, "capabilityBitmap": [0], "deviceId": "ephemeral QA", "serviceData": service, "devicename": name]))
    }
    let peer = try HuaweiDiscovery.decode(packet(), host: "192.168.25.3", network: network)
    #expect(peer.port == 34567 && peer.name == "Huawei QA" && peer.discoveryID.count == 64)
    for invalid in [try packet(host: "192.168.25.4"), try packet(service: "port:1,port:2,"), try packet(service: "port:0,"), try packet(name: "bad\nname")] {
        #expect(throws: (any Error).self) { _ = try HuaweiDiscovery.decode(invalid, host: "192.168.25.3", network: network) }
    }
    for count in 0..<20 {
        #expect(throws: (any Error).self) { _ = try HuaweiDiscovery.decode(Data(try packet().prefix(count)), host: "192.168.25.3", network: network) }
    }
    #expect(throws: (any Error).self) { _ = try HuaweiSender.port(["P2P_IP": "192.168.25.4", "P2P_PORT": 34567], hostKey: "P2P_IP", expected: "192.168.25.3") }
    #expect(throws: (any Error).self) { _ = try HuaweiSender.port(["P2P_IP": "192.168.25.3", "P2P_PORT": true], hostKey: "P2P_IP", expected: "192.168.25.3") }
    let narrow = WiFiIPv4Address(address: "192.168.25.2", netmask: "255.255.255.128")
    for edge in ["192.168.25.0", "192.168.25.127"] {
        #expect(throws: (any Error).self) { try HuaweiPeer(host: edge, port: 34567, name: "QA", discoveryID: String(repeating: "a", count: 64)).validate(network: narrow) }
    }
    try HuaweiPeer(host: "192.168.24.255", port: 34567, name: "QA", discoveryID: String(repeating: "a", count: 64)).validate(network: .init(address: "192.168.24.2", netmask: "255.255.254.0"))
}

@MainActor @Test func huaweiOfferKeepsPhotoVideoAndMixedTypesDistinct() throws {
    func fields(_ names: [String]) throws -> [Int: Data] {
        Dictionary(uniqueKeysWithValues: try HuaweiWire.fields(HuaweiWire.unwrap(HuaweiSender.offer(names: names, total: 100, sender: "anDrop QA"), tag: 7)))
    }
    #expect(try fields(["photo.HEIC", "another.jpeg"])[1] == Data("1".utf8))
    #expect(try fields(["photo.heic", "video.mov"])[1] == Data("3".utf8))
    #expect(try fields(["文書.pdf"])[7] == Data("{\".pdf\":1}".utf8))
}

@Test func huaweiHandoffPreservesTransportAndRejectsInvalidTargets() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appending(path: "fixture.txt"); try Data([1,2,3]).write(to: source)
    let peer = HuaweiPeer(host: "192.168.2.3", port: 34567, name: "QA Huawei", discoveryID: String(repeating: "a", count: 64))
    let store = BackgroundSendJobStore(directory: root.appending(path: "handoff"))
    let recipient = TransferRecipient(peripheralID: UUID(), discoveryID: peer.discoveryID, name: peer.name, huawei: peer)
    let job = try await store.enqueue([source], recipient: recipient)
    try store.selectRecipient(id: job.id, recipient: recipient)
    #expect(try store.loadReady().0.recipient.huawei == peer)
    let manifest = store.directory.appending(path: "active/manifest.json")
    var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any])
    var target = try #require(object["recipient"] as? [String: Any])
    var transport = try #require(target["huawei"] as? [String: Any]); transport["host"] = "8.8.8.8"
    target["huawei"] = transport; object["recipient"] = target
    try JSONSerialization.data(withJSONObject: object).write(to: manifest)
    #expect(throws: (any Error).self) { _ = try store.loadReady() }
    store.remove(id: job.id)
    #expect(try Data(contentsOf: source) == Data([1,2,3]))
}

#if os(macOS)
/// Opt-in cross-implementation test. Normal tests have no Python dependency.
@MainActor @Test(.enabled(if: ProcessInfo.processInfo.environment["ANDROP_HUAWEI_REFERENCE_ROOT"] != nil), .timeLimit(.minutes(2)), arguments: ["accept", "decline", "tamper", "cancel"])
func huaweiNativeSenderInteroperatesWithMacReferenceReceiver(mode: String) async throws {
    let reference = try #require(ProcessInfo.processInfo.environment["ANDROP_HUAWEI_REFERENCE_ROOT"])
    let network = try #require(WiFiIPv4Address.current().first(where: { LocalNetwork.isPrivateIPv4($0.address) }))
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let output = root.appending(path: "result.json"); let destination = root.appending(path: "received")
    let helper = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appending(path: "TestSupport/Huawei/reference-receiver.py")
    let process = Process(); process.executableURL = URL(fileURLWithPath: reference).appending(path: ".venv/bin/python3")
    process.arguments = [helper.path, "--reference", reference, "--address", network.address, "--output", output.path, "--destination", destination.path, "--mode", mode]
    let diagnostics = Pipe(); process.standardError = diagnostics
    try process.run(); defer { if process.isRunning { process.terminate() } }
    var values: [String: Any] = [:]
    for _ in 0..<100 {
        if let data = try? Data(contentsOf: output), let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { values = result; break }
        if !process.isRunning { break }
        try await Task.sleep(for: .milliseconds(100))
    }
    let port = try #require(values["port"] as? UInt16, Comment(rawValue: "Reference receiver did not start"))
    let names = ["empty.txt", "manifest.json"] + (1...5).map { "華為-元の名前-\($0).bin" }
    let contents = [Data(), Data("{\"fixture\":true}".utf8)] + (1...5).map { Data(repeating: UInt8($0), count: 4 * 1024 * 1024) }
    let files = try zip(names, contents).map { name, data in let url = root.appending(path: name); try data.write(to: url); return url }
    let peer = HuaweiPeer(host: network.address, port: port, name: "QA receiver", discoveryID: String(repeating: "a", count: 64))
    let sender = HuaweiSender(); var stage = ""; var transferred = 0
    sender.onStage = { stage = $0 }; sender.onProgress = { bytes, _ in
        transferred = bytes
        if mode == "cancel", bytes > 0 { sender.stop() }
    }
    var sendError: (any Error)?
    do { try await sender.send(files: files, peer: peer, network: network, identity: HuaweiIdentity(), senderName: "QA sender") }
    catch {
        sendError = error
        if mode == "accept" {
            if process.isRunning { process.terminate() }; process.waitUntilExit()
            let errorText = String(decoding: diagnostics.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            Issue.record("Reference peer: \(errorText)")
            throw error
        }
    }
    for _ in 0..<100 { if !process.isRunning { break }; try await Task.sleep(for: .milliseconds(50)) }
    #expect(!process.isRunning && process.terminationStatus == 0)
    let final = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: output)) as? [String: Any])
    if mode == "accept" {
        #expect(sendError == nil && final["dfile_done_ack_verified"] as? Bool == true)
        #expect(stage == "send_complete" && transferred == contents.reduce(0) { $0 + $1.count })
        for (name, data) in zip(names, contents) { #expect(try Data(contentsOf: destination.appending(path: name)) == data) }
    } else {
        #expect(sendError != nil && stage != "send_complete")
        #expect(final["dfile_done_ack_verified"] as? Bool != true)
        if mode == "decline" { #expect(transferred == 0) }
        for (file, data) in zip(files, contents) { #expect(try Data(contentsOf: file) == data) }
    }
}
#endif
