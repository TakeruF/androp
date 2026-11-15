// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Darwin

/// Experimental LAN sender for the Apple-compatible Huawei Share session.
/// No vendor certificate bypass, account credentials, Wi-Fi switching or ZIP.
@MainActor public final class HuaweiSender {
    public var onStage: (@MainActor (String) -> Void)?
    public var onProgress: (@MainActor (Int, Int) -> Void)?
    private var sockets: [HuaweiSocket] = []
    private var stopped = false
    public init() {}
    public func stop() { stopped = true; sockets.forEach { $0.close() }; sockets.removeAll() }
    private func connect(_ host: String, _ port: UInt16) async throws -> HuaweiSocket {
        try Task.checkCancellation(); guard !stopped else { throw CancellationError() }
        let socket = HuaweiSocket(host: host, port: port); sockets.append(socket)
        try await socket.start(); return socket
    }
    private struct Entry { let url: URL; let name: String; let size: Int }
    public func send(files: [URL], peer: HuaweiPeer, network: WiFiIPv4Address, identity: HuaweiIdentity, senderName: String, deviceType: Int = 14) async throws {
        try peer.validate(network: network)
        guard (1...Limits.files).contains(files.count) else { throw HuaweiFailure.invalid }
        var total = 0; var names = Set<String>(); var entries: [Entry] = []
        for file in files {
            let name = try FileArchive.safeName(file.lastPathComponent)
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard name == file.lastPathComponent, name.utf8.count <= 255, names.insert(name.lowercased()).inserted,
                  values.isRegularFile == true, values.isSymbolicLink != true, let size = values.fileSize,
                  (0...(Limits.bytes - total)).contains(size) else { throw HuaweiFailure.invalid }
            entries.append(Entry(url: file, name: name, size: size)); total += size
        }
        defer { stop() }
        onStage?("huawei_authenticating")
        let socket = try await connect(peer.host, peer.port)
        let key = try await authenticate(socket, identity: identity)
        var sequence: UInt64 = 5
        func app(_ body: Data) async throws {
            try await socket.send(HuaweiWire.encrypted(identity.deviceHash, body, key: key, sequence: sequence)); sequence += 1
        }
        func channel(_ kind: UInt64, module: UInt64, flags: UInt64 = 0, _ body: Data) async throws {
            try await socket.send(HuaweiWire.channel(kind, module: module, flags: flags, body: body, key: key, sequence: sequence)); sequence += 1
        }
        try await app(Self.offer(names: entries.map(\.name), total: total, sender: senderName))
        onStage?("waiting_for_recipient")
        var accepted = false; var networkSent = false; var logicalSent = false; var metadataSent = false; var endpointRequested = false
        var bytesSocket: HuaweiSocket?; let byteKey = try HuaweiWire.random(32); let fileKey = try HuaweiWire.random(32)
        for _ in 0..<64 {
            let packet = try await socket.frame(); let header = try HuaweiWire.Header(Data(packet.prefix(24)))
            if header.module == 9 {
                let fields = try HuaweiWire.fields(HuaweiWire.decrypt(packet, key: key))
                for (tag, body) in fields {
                    if tag == 1 {
                        let controls = try HuaweiWire.fields(body)
                        if controls.contains(where: { [Data("user_reject".utf8), Data("receiverCancel".utf8)].contains($0.1) }) { throw TransferFailure.declined }
                        if controls.contains(where: { $0.0 == 1 && $0.1 == Data("user_confirm".utf8) }), !networkSent {
                            accepted = true; networkSent = true; onStage?("negotiating_network")
                            try await app(HuaweiWire.tlv(4, HuaweiWire.tlv(1, "") + HuaweiWire.tlv(2, "") + HuaweiWire.tlv(3, "") + HuaweiWire.tlv(4, network.address)))
                        }
                    } else if tag == 5, accepted, networkSent, !logicalSent {
                        logicalSent = true; try await app(HuaweiWire.tlv(10, HuaweiWire.tlv(1, network.address)))
                    } else if tag == 10 {
                        guard accepted, try HuaweiWire.unwrap(body, tag: 1) == Data(peer.host.utf8) else { throw HuaweiFailure.target }
                    }
                }
                continue
            }
            guard accepted else { throw HuaweiFailure.invalid }
            let (inner, plain) = try HuaweiWire.decodeChannel(packet, key: key)
            switch inner.magic {
            case 0xffff0002:
                let object = try HuaweiWire.object(plain)
                guard object["DEVICE_NAME"] is String, object["DEVICE_TYPE_ID"] is Int, object["META_NODE_ID"] is String, object["FLAG"] is Int else { throw HuaweiFailure.invalid }
                if !metadataSent {
                    metadataSent = true
                    try await channel(inner.magic, module: inner.module, flags: inner.flags, HuaweiWire.json(["DEVICE_NAME": senderName, "DEVICE_TYPE_ID": deviceType, "META_NODE_ID": identity.nodeID, "FLAG": 100], nul: false))
                }
            case 0xffff0008:
                guard plain == Data("META_DEVICE_INFO_ACK\0".utf8) else { throw HuaweiFailure.invalid }
                try await channel(inner.magic, module: inner.module, flags: inner.flags, plain)
                if !endpointRequested {
                    endpointRequested = true
                    try await channel(0xffff0004, module: 16, HuaweiWire.json(["CODE": 3, "P2P_IP": network.address, "P2P_PORT": Self.ephemeralPort(), "PROTOCOL_TYPE": 4]))
                }
            case 0xffff0004:
                let object = try HuaweiWire.object(plain)
                if inner.module == 16, inner.flags == 1, object["CODE"] as? Int == 3, bytesSocket == nil {
                    let port = try Self.port(object, hostKey: "P2P_IP", expected: peer.host)
                    let bytes = try await connect(peer.host, port); bytesSocket = bytes
                    let handshake = try HuaweiWire.json(["CODE": 1, "API_VERSION": 2, "BUS_NAME": "IShareReceiverBytesSession", "CLIENT_BUS_NAME": "IShareSenderBytesSession", "PKG_NAME": "ohos.InterConnection.iShare", "MTU_SIZE": 4194304, "TRANS_CAPABILITY": 0, "ROUTE_TYPE": 2, "DEVICE_ID": identity.identity, "BUSINESS_TYPE": 1, "TRANS_FLAGS": 2, "SESSION_KEY": byteKey.base64EncodedString()])
                    try await bytes.send(Data(HuaweiWire.channel(HuaweiWire.magic, module: 6, flags: 0x94, body: handshake, key: key, sequence: 0).dropFirst(24)))
                    let (ack, body) = try await HuaweiWire.decodeChannel(HuaweiWire.frame(21, 0, bytes.frame()), key: key)
                    let value = try HuaweiWire.object(body)
                    guard ack.module == 6, ack.flags == 0x95, value["CODE"] as? Int == 1, value["ERR_CODE"] == nil else { throw HuaweiFailure.invalid }
                    try await channel(0xffff0004, module: 17, HuaweiWire.json(["MY_CHANNEL_ID": 1, "MY_IP": network.address, "DEVICE_ID": identity.identity, "CODE": 1538, "API_VERSION": 2, "BUSINESS_TYPE": 3, "STREAM_TYPE": 255, "CHANNEL_TYPE": 1, "UDP_CONN_TYPE": 1, "BUS_NAME": "IShareReceiverFileSession", "CLIENT_BUS_NAME": "IShareSenderFileSession", "PKG_NAME": "ohos.InterConnection.iShare", "TRANS_CAPABILITY": 0, "SESSION_KEY": fileKey.base64EncodedString()]))
                } else if inner.module == 17, inner.flags == 1, object["CODE"] as? Int == 1538, let bytesSocket {
                    let port = try Self.port(object, hostKey: "MY_IP", expected: peer.host)
                    let fileSocket = try await connect(peer.host, port)
                    try await transfer(entries, total: total, file: fileSocket, preview: bytesSocket, hash: identity.deviceHash, key: key, byteKey: byteKey, fileKey: fileKey)
                    onStage?("send_complete"); return
                } else { throw HuaweiFailure.unsupported }
            default: throw HuaweiFailure.unsupported
            }
        }
        throw TransferFailure.timeout
    }
    private func authenticate(_ socket: HuaweiSocket, identity: HuaweiIdentity) async throws -> Data {
        try await socket.send(HuaweiWire.frame(8, 1, HuaweiWire.json(["CODE": 4, "DEVICE_ID": identity.identity, "PEER_NETWORK_ID": identity.identity, "PKG_NAME": "ohos.InterConnection.iShare", "SRC_BUS_NAME": "IShareEcologyAuthSession", "DST_BUS_NAME": "IShareEcologyAuthSession", "REQ_ID": "0", "API_VERSION": 2, "MTU_SIZE": 39968, "ROUTE_TYPE": 2])))
        let opening = try await socket.frame(); let header = try HuaweiWire.Header(Data(opening.prefix(24)))
        guard header.module == 8, header.flags == 1, try HuaweiWire.object(Data(opening.dropFirst(24)))["CODE"] as? Int == 4 else { throw HuaweiFailure.unsupported }
        try await socket.send(HuaweiWire.envelope(identity.deviceHash, HuaweiWire.tlv(2, HuaweiWire.tlv(1, "1") + HuaweiWire.tlv(2, "1.0.0") + HuaweiWire.tlv(3, "iOS") + HuaweiWire.tlv(4, "arm64")), sequence: 2))
        let capability = try HuaweiWire.Envelope(await socket.frame())
        guard capability.mode == 0 else { throw HuaweiFailure.unsupported }
        let versions = try HuaweiWire.fields(HuaweiWire.unwrap(capability.body, tag: 3))
        guard let version = versions.first(where: { $0.0 == 1 })?.1, version.count <= 10,
              version.allSatisfy({ (48...57).contains($0) }) else { throw HuaweiFailure.unsupported }
        // Security's OAEP-SHA256 uses MGF1-SHA256. Never downgrade a peer
        // requesting the separate SHA1-MGF variant or ignore its version bit.
        guard (Int(String(decoding: version, as: UTF8.self)) ?? 0) & 1 == 0 else { throw HuaweiFailure.unsupported }
        try await socket.send(HuaweiWire.envelope(identity.deviceHash, HuaweiWire.tlv(6, HuaweiWire.tlv(1, identity.publicDER)), sequence: 3))
        let publicPacket = try HuaweiWire.Envelope(await socket.frame())
        guard publicPacket.mode == 0, publicPacket.hash == capability.hash else { throw HuaweiFailure.invalid }
        let peerKey = try HuaweiWire.unwrap(HuaweiWire.unwrap(publicPacket.body, tag: 6), tag: 2)
        let nonce = try HuaweiWire.random(16); let challengeKey = try HuaweiWire.random(32)
        let challenge = try identity.encrypt(HuaweiWire.tlv(6, HuaweiWire.tlv(3, nonce + challengeKey)), peerDER: peerKey)
        try await socket.send(HuaweiWire.envelope(identity.deviceHash, challenge, sequence: 4, mode: 3, metadata: HuaweiWire.tlv(1, HuaweiWire.random(8))))
        let response = try HuaweiWire.Envelope(await socket.frame())
        guard response.mode == 3, response.hash == publicPacket.hash else { throw HuaweiFailure.invalid }
        let encrypted = try HuaweiWire.unwrap(HuaweiWire.unwrap(identity.decrypt(response.body), tag: 6), tag: 4)
        let session = try HuaweiWire.open(encrypted, key: challengeKey, nonce: nonce)
        guard session.count == 32 else { throw HuaweiFailure.invalid }
        return session
    }
    static func offer(names: [String], total: Int, sender: String) throws -> Data {
        var extensions: [String: Int] = [:]
        for name in names {
            let suffix = URL(fileURLWithPath: name).pathExtension.lowercased()
            extensions[suffix.isEmpty ? "" : "." + suffix, default: 0] += 1
        }
        let photos: Set<String> = ["jpg","jpeg","jpe","png","heic","heif","avif","webp","gif","bmp","tif","tiff"]
        let photoOnly = names.allSatisfy { photos.contains(URL(fileURLWithPath: $0).pathExtension.lowercased()) }
        let summary = try JSONSerialization.data(withJSONObject: extensions, options: [.sortedKeys])
        let values: [(Int, Data)] = [(1, Data((photoOnly ? "1" : "3").utf8)), (2, Data(String(sender.prefix(60)).utf8)),
            (3, Data(String(names.count).utf8)), (4, Data(String(total).utf8)), (5, Data("0".utf8)),
            (6, Data(String(names.count).utf8)), (7, summary), (16, Data("0".utf8))]
        return HuaweiWire.tlv(7, values.reduce(into: Data()) { $0 += HuaweiWire.tlv($1.0, $1.1) })
    }
    static func port(_ object: [String: Any], hostKey: String, expected: String) throws -> UInt16 {
        guard object[hostKey] as? String == expected, let value = object["P2P_PORT"] as? Int, (1...65_535).contains(value), !(object["P2P_PORT"] is Bool) else { throw HuaweiFailure.target }
        return UInt16(value)
    }
    private static func ephemeralPort() throws -> Int {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0); guard descriptor >= 0 else { throw HuaweiFailure.target }
        defer { Darwin.close(descriptor) }
        var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = UInt8(AF_INET)
        let result = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard result == 0 else { throw HuaweiFailure.target }
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &size) } }
        guard named == 0 else { throw HuaweiFailure.target }; return Int(UInt16(bigEndian: address.sin_port))
    }
    private func transfer(_ entries: [Entry], total: Int, file: HuaweiSocket, preview: HuaweiSocket, hash: Data, key: Data, byteKey: Data, fileKey: Data) async throws {
        let parts = [HuaweiWire.number(1472, 2), HuaweiWire.number(2, 2), HuaweiWire.number(1, 4), Data(repeating: 0, count: 8),
                     HuaweiWire.number(1472, 4), HuaweiWire.number(256, 4), Data(repeating: 0, count: 67), Data([1]),
                     Data(repeating: 0, count: 4), HuaweiWire.number(1, 4)]
        let settings = parts.reduce(into: Data()) { $0 += $1 }
        try await file.send(HuaweiWire.dfile(8, transaction: 0, body: settings))
        let (header, response) = try await file.dfile()
        guard header[0] == 8, response.count >= 100, response[2..<4] == HuaweiWire.number(2, 2), response[91] == 1,
              response[99] & 1 != 0 else { throw HuaweiFailure.unsupported }
        var capabilities = HuaweiReader(Data(response[20..<24]))
        guard try capabilities.integer(4) & 256 != 0 else { throw HuaweiFailure.unsupported }
        let metadata = try HuaweiWire.json(["date_added": entries.map { _ in -1 }, "date_taken": entries.map { _ in -1 }, "detail_time": entries.map { _ in "" }], nul: false)
        let names = entries.map(\.name).joined(separator: "|")
        let inner = try HuaweiWire.encrypted(hash, HuaweiWire.tlv(8, HuaweiWire.tlv(11, names) + HuaweiWire.tlv(13, metadata)), key: key, sequence: 0)
        let nonce = try HuaweiWire.random(12)
        let body = nonce + (try HuaweiWire.seal(Data(inner.dropFirst(24)), key: byteKey, nonce: nonce))
        try await preview.send(HuaweiWire.number(HuaweiWire.magic, 4, little: true) + Data(repeating: 0, count: 8) + HuaweiWire.number(UInt64(body.count), 4, little: true) + body)
        var previewOK = false
        for _ in 0..<4 {
            let plain = try HuaweiWire.decrypt(HuaweiWire.frame(9, 0, await preview.preview(key: byteKey)), key: key)
            let fields = try HuaweiWire.fields(HuaweiWire.unwrap(plain, tag: 1))
            if fields.count == 1, fields[0].0 == 8, fields[0].1 == Data("previewOK".utf8) { previewOK = true; break }
            guard fields.count == 1, fields[0].0 == 15, fields[0].1.count <= 65_536 else { throw HuaweiFailure.invalid }
        }
        guard previewOK else { throw HuaweiFailure.invalid }
        var metadataPacket = HuaweiWire.number(UInt64(entries.count), 2)
        for (index, entry) in entries.enumerated() {
            let unit = HuaweiWire.number(UInt64(index + 1), 2) + HuaweiWire.number(UInt64(entry.size), 8) + HuaweiWire.number(UInt64(entry.name.utf8.count), 2) + Data(entry.name.utf8)
            if metadataPacket.count + unit.count > 1400 {
                try await file.send(HuaweiWire.dfileControl(1, body: metadataPacket, key: fileKey)); metadataPacket = HuaweiWire.number(UInt64(entries.count), 2)
            }
            metadataPacket += unit
        }
        try await file.send(HuaweiWire.dfileControl(1, body: metadataPacket, key: fileKey))
        // Drain authenticated ACKs during writes so a large send cannot block
        // behind the peer's full receive window. Keep control buffering bounded.
        let (controls, continuation) = AsyncThrowingStream<(Int, Data), any Error>.makeStream(bufferingPolicy: .bufferingOldest(64))
        let reader = Task { @MainActor in
            do {
                while !Task.isCancelled {
                    let (header, data) = try await file.dfile(); let kind = Int(header[0])
                    if kind == 11 { continue }
                    guard [2,3,5,6,9].contains(kind), header[1..<6] == Data([0,0,0,0,1]) else { throw HuaweiFailure.invalid }
                    let plain = try HuaweiWire.decodeDFileControl(header, body: data, key: fileKey)
                    if kind == 9 { throw TransferFailure.declined }
                    if kind != 5 {
                        if case .dropped = continuation.yield((kind, plain)) { throw HuaweiFailure.invalid }
                    }
                }
                continuation.finish()
            } catch { continuation.finish(throwing: error) }
        }
        defer { reader.cancel(); file.close(); continuation.finish() }
        var sent = Set<Int>(); var done = Set<Int>(); var completed = 0
        onStage?("sending_archive"); onProgress?(0, total)
        for try await (kind, payload) in controls {
            var ids = HuaweiReader(payload); var list = Set<Int>()
            guard ids.remaining > 0, ids.remaining % 2 == 0 else { throw HuaweiFailure.invalid }
            while ids.remaining > 0 {
                let id = Int(try ids.integer(2)); guard (1...entries.count).contains(id), list.insert(id).inserted else { throw HuaweiFailure.invalid }
            }
            if kind == 2 || kind == 3 {
                for id in list.sorted() where !sent.contains(id) {
                    let entry = entries[id - 1]; let source = try FileHandle(forReadingFrom: entry.url)
                    defer { try? source.close() }
                    var offset = 0; var sequence: UInt64 = 0
                    while offset < entry.size {
                        try Task.checkCancellation(); guard !stopped else { throw CancellationError() }
                        guard let content = try source.read(upToCount: min(1422, entry.size - offset)), !content.isEmpty else { throw HuaweiFailure.invalid }
                        let fields = HuaweiWire.number(UInt64(id), 2) + HuaweiWire.number(sequence, 4)
                        let nonce = try HuaweiWire.random(12)
                        let encrypted = try HuaweiWire.seal(fields + HuaweiWire.number(1, 2) + content, key: Data(fileKey.prefix(16)), nonce: nonce, aad: HuaweiWire.dfileAAD)
                        let flags = offset + content.count == entry.size ? 3 : sequence == 0 ? 0 : 1
                        try await file.send(HuaweiWire.dfile(4, flags: flags, body: fields + encrypted + nonce))
                        offset += content.count; sequence += 1; onProgress?(completed + offset, total)
                    }
                    guard (try source.read(upToCount: 1) ?? Data()).isEmpty else { throw HuaweiFailure.invalid }
                    sent.insert(id); completed += entry.size
                }
                if sent.count == entries.count { onStage?("awaiting_confirmation") }
            } else if kind == 6 {
                guard list.isSubset(of: sent) else { throw HuaweiFailure.invalid }
                done.formUnion(list)
                if done.count == entries.count { try await file.send(HuaweiWire.dfileControl(7, body: Data(), key: fileKey)); return }
            }
        }
        throw TransferFailure.completionUnconfirmed
    }
}
