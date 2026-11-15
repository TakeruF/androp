// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Testing
import Darwin
@testable import anDropProtocol

private func localNetwork() -> WiFiIPv4Address? {
    var list: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&list) == 0 else { return nil }
    defer { freeifaddrs(list) }
    var item = list
    while let current = item {
        defer { item = current.pointee.ifa_next }
        guard let raw = current.pointee.ifa_addr, raw.pointee.sa_family == UInt8(AF_INET),
              ["en0", "en1"].contains(String(cString: current.pointee.ifa_name)), let rawMask = current.pointee.ifa_netmask else { continue }
        var address = UnsafeRawPointer(raw).assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr
        var bytes = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &address, &bytes, socklen_t(bytes.count)) != nil else { continue }
        let value = String(decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        var mask = UnsafeRawPointer(rawMask).assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr
        guard inet_ntop(AF_INET, &mask, &bytes, socklen_t(bytes.count)) != nil else { continue }
        let maskText = String(decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        if LocalNetwork.isPrivateIPv4(value) { return .init(address: value, netmask: maskText) }
    }
    return nil
}

@Test @MainActor func realTLSWebSocketHTTPTransfer() async throws {
    guard let network = localNetwork() else { Issue.record("No local IPv4 address is available for the TLS integration test."); return }
    let address = network.address
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let source = root.appending(path: "fixture.txt")
    let bytes = Data("Real TLS + WebSocket + HTTP + ZIP\n日本語\n".utf8)
    try bytes.write(to: source)
    let prepared = try await FileArchive.prepare([source])
    let server = try TransferServer(files: prepared, senderName: "Fixture sender", network: network)
    try server.confirmPeer(address)
    var confirmed = false; var stages: [String] = []
    var sentProgress: [Int] = []; var receivedProgress: [Int] = []
    server.onComplete = { confirmed = true }
    server.onStage = { stages.append($0) }
    server.onProgress = { completed, _ in sentProgress.append(completed) }
    try await server.start()
    defer { server.stop() }
    let receiver = TransferReceiver()
    receiver.onProgress = { completed, _ in receivedProgress.append(completed) }
    let saved = try await receiver.receive(host: address, port: server.port, expectedCount: 1, destination: root.appending(path: "received")) { offer in
        #expect(offer.mime == "text/plain")
        return offer.name == "fixture.txt" && offer.total == bytes.count
    }
    #expect(saved.count == 1)
    #expect(try Data(contentsOf: saved[0].url) == bytes)
    for _ in 0..<20 {
        if confirmed { break }
        try await Task.sleep(for: .milliseconds(50))
    }
    #expect(confirmed)
    #expect(stages.contains("send_complete"))
    #expect(sentProgress.last == prepared.archive.count)
    #expect(receivedProgress.last == prepared.archive.count)
    #expect(zip(sentProgress, sentProgress.dropFirst()).allSatisfy { $0 <= $1 })
    #expect(zip(receivedProgress, receivedProgress.dropFirst()).allSatisfy { $0 <= $1 })
}

@Test @MainActor func fivePhotoSizedFilesOverSixteenMiBTransfer() async throws {
    guard let network = localNetwork() else { Issue.record("No local IPv4 address is available."); return }
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    var originals: [URL] = []
    for index in 1...5 {
        let file = root.appending(path: "photo-\(index).jpg")
        try Data(repeating: UInt8(index), count: 4 * 1024 * 1024).write(to: file)
        originals.append(file)
    }
    let importer = SharedFileImporter(baseDirectory: root); defer { importer.cleanup() }
    let batch = try await importer.load(originals.map { NSItemProvider(item: $0 as NSURL, typeIdentifier: "public.file-url") })
    #expect(batch.files.count == 5 && batch.totalBytes == 20 * 1024 * 1024)
    let prepared = try await FileArchive.prepare(batch.files)
    #expect(prepared.count == 5 && prepared.total == batch.totalBytes)
    #expect(prepared.archive.count > batch.totalBytes && prepared.mime == "image/jpeg")
    let server = try TransferServer(files: prepared, senderName: "Fixture", network: network)
    try server.confirmPeer(network.address)
    var complete = false; server.onComplete = { complete = true }
    try await server.start(); defer { server.stop() }
    let receiver = TransferReceiver()
    let saved = try await receiver.receive(host: network.address, port: server.port, expectedCount: 5, destination: root.appending(path: "received")) { offer in
        #expect(offer.total == 20 * 1024 * 1024 && offer.mime == "image/jpeg")
        return true
    }
    #expect(saved.count == originals.count)
    for (original, file) in zip(originals, saved) {
        #expect(file.url.lastPathComponent == original.lastPathComponent)
        #expect(try Data(contentsOf: original) == Data(contentsOf: file.url))
    }
    for _ in 0..<20 { if complete { break }; try await Task.sleep(for: .milliseconds(50)) }
    #expect(complete)
}

@Test @MainActor func typedOffersPreserveHTTPZipAndOriginalBytes() async throws {
    guard let network = localNetwork() else { Issue.record("No local IPv4 address is available."); return }
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    for (names, expected) in [(["fixture.pdf"], "application/pdf"), (["a.jpg", "b.png"], "image/*"), (["a.pdf", "b.jpg"], "file/*")] {
        var urls: [URL] = []
        for name in names { let file = root.appending(path: name); try Data("fixture \(name)".utf8).write(to: file); urls.append(file) }
        let prepared = try await FileArchive.prepare(urls)
        let server = try TransferServer(files: prepared, senderName: "Fixture", network: network)
        try server.confirmPeer(network.address); var completions = 0; server.onComplete = { completions += 1 }
        try await server.start()
        defer { server.stop() }
        let control = TLSSocket(host: network.address, port: server.port)
        try await control.start()
        let ws = WebSocket(socket: control, client: true)
        try await ws.upgrade(host: network.address, port: server.port)
        var offer: ControlMessage?
        for _ in 0..<8 {
            let message = try await ws.next()
            if message.name == "sendRequest" { offer = message; break }
            try await ws.send(ControlMessage(kind: "ack", index: message.index, name: message.name))
        }
        let request = try #require(offer)
        #expect(request.payload["mimeType"] as? String == expected)
        #expect(request.payload["fileCount"] as? Int == names.count)
        let download = TLSSocket(host: network.address, port: server.port, pin: control.peerCertificate)
        try await download.start()
        try await download.send(Data("GET /download?taskId=\(server.taskID) HTTP/1.1\r\nHost: fixture\r\n\r\n".utf8))
        let headers = try await download.headers()
        #expect(headers.fields["content-type"] == "application/zip")
        let length = try #require(headers.fields["content-length"].flatMap(Int.init))
        let archive = try await download.read(length)
        download.close()
        let files = try await FileArchive.extract(archive, count: names.count, total: prepared.total, destination: root.appending(path: UUID().uuidString))
        for (original, result) in zip(urls, files) { #expect(try Data(contentsOf: original) == Data(contentsOf: result.url)) }
        try await ws.send(ControlMessage(kind: "action", index: 10, name: "status", payload: ["taskId": server.taskID, "type": 1]))
        try await ws.send(ControlMessage(kind: "action", index: 11, name: "status", payload: ["taskId": server.taskID, "type": 1]))
        control.close() // A successful peer may leave before reading our ACK.
        for _ in 0..<20 { if completions > 0 { break }; try await Task.sleep(for: .milliseconds(50)) }
        #expect(completions == 1)
        server.stop()
    }
}

@Test @MainActor func declinesWithoutDownloading() async throws {
    guard let network = localNetwork() else { Issue.record("No local IPv4 address is available."); return }
    let address = network.address
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let file = root.appending(path: "fixture.txt"); try Data([1,2,3]).write(to: file)
    let server = try TransferServer(files: await FileArchive.prepare([file]), senderName: "Fixture", network: network)
    try server.confirmPeer(address)
    var downloaded = false; server.onStage = { if $0 == "sending_archive" { downloaded = true } }
    try await server.start(); defer { server.stop() }
    let receiver = TransferReceiver()
    await #expect(throws: (any Error).self) {
        try await receiver.receive(host: address, port: server.port, expectedCount: 1, destination: root.appending(path: "received")) { _ in false }
    }
    #expect(!downloaded)
    #expect(!FileManager.default.fileExists(atPath: root.appending(path: "received").path))
}

@Test @MainActor func refusesDifferentDownloadCertificate() async throws {
    guard let network = localNetwork() else { Issue.record("No local IPv4 address is available."); return }
    let address = network.address
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let file = root.appending(path: "fixture.txt"); try Data([1]).write(to: file)
    let server = try TransferServer(files: await FileArchive.prepare([file]), senderName: "Fixture", network: network)
    try await server.start(); defer { server.stop() }
    let socket = TLSSocket(host: address, port: server.port, pin: Data([0,1,2]))
    defer { socket.close() }
    await #expect(throws: (any Error).self) { try await socket.start() }
}

@Test @MainActor func hotspotHintTransfersWithControlConnectionBeforeBLEConfirmation() async throws {
    guard let network = localNetwork() else { Issue.record("No local IPv4 address is available."); return }
    let hint = network.reaches("192.168.49.1") ? "172.30.255.1" : "192.168.49.1"
    let candidate = try #require(SendRoutePlanner.candidates(peerHint: hint, interfaces: [network]).first)
    #expect(candidate.source == .wifiInterface)
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let file = root.appending(path: "fixture.txt"); let content = Data("Send over existing Wi-Fi, ignoring dormant hotspot hint.".utf8)
    try content.write(to: file)
    let server = try TransferServer(files: await FileArchive.prepare([file]), senderName: "Fixture", network: candidate.network)
    var completed = false; server.onComplete = { completed = true }
    try await server.start(); defer { server.stop() }
    let receiver = TransferReceiver()
    receiver.onStage = { stage in
        if stage == "control_connected" { do { try server.confirmPeer(network.address) } catch { Issue.record(error) } }
    }
    let files = try await receiver.receive(host: candidate.network.address, port: server.port, expectedCount: 1, destination: root.appending(path: "received")) { _ in true }
    #expect(try Data(contentsOf: files[0].url) == content)
    for _ in 0..<20 { if completed { break }; try await Task.sleep(for: .milliseconds(50)) }
    #expect(completed)
}

@Test @MainActor func downloadDeniedUntilBLEAndControlAgree() async throws {
    guard let network = localNetwork() else { Issue.record("No local IPv4 address is available."); return }
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let file = root.appending(path: "fixture.txt"); try Data([1,2,3]).write(to: file)
    let server = try TransferServer(files: await FileArchive.prepare([file]), senderName: "Fixture", network: network)
    try await server.start(); defer { server.stop() }
    let control = TLSSocket(host: network.address, port: server.port); defer { control.close() }
    try await control.start()
    let ws = WebSocket(socket: control, client: true)
    try await ws.upgrade(host: network.address, port: server.port)
    let download = TLSSocket(host: network.address, port: server.port, pin: control.peerCertificate); defer { download.close() }
    try await download.start()
    try await download.send(Data("GET /download?taskId=\(server.taskID) HTTP/1.1\r\nHost: fixture\r\n\r\n".utf8))
    let response = try await download.headers()
    #expect(response.firstLine.hasPrefix("HTTP/1.1 403 "))
}
