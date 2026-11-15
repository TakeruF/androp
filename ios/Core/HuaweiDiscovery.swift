// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import CryptoKit

public struct HuaweiPeer: Codable, Sendable, Equatable {
    public let host: String
    public let port: UInt16
    public let name: String
    public let discoveryID: String
    func validateMetadata() throws {
        guard LocalNetwork.isPrivateIPv4(host), port != 0,
              (1...100).contains(name.count), !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              discoveryID.count == 64, discoveryID.allSatisfy({ $0.isHexDigit && $0.isASCII }) else { throw HuaweiFailure.target }
    }
    public func validate(network: WiFiIPv4Address) throws {
        try validateMetadata()
        guard network.reaches(host) || host == network.address else { throw HuaweiFailure.target }
        func number(_ value: String) throws -> UInt32 {
            let fields = value.split(separator: ".").compactMap { UInt8($0) }
            guard fields.count == 4 else { throw HuaweiFailure.target }
            return fields.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        }
        let address = try number(host); let mask = try number(network.netmask); let subnet = try number(network.address) & mask
        guard mask != 0, address != subnet, address != subnet | ~mask else { throw HuaweiFailure.target }
    }
}

public enum HuaweiDiscovery {
    /// Directed CoAP only. No broadcast, multicast, subnet scan or hotspot.
    @MainActor public static func find(host: String, network: WiFiIPv4Address, name: String) async throws -> HuaweiPeer {
        guard LocalNetwork.isPrivateIPv4(host), network.reaches(host), host != network.address else { throw HuaweiFailure.target }
        try HuaweiPeer(host: host, port: 1, name: "Probe", discoveryID: String(repeating: "0", count: 64)).validate(network: network)
        let socket = HuaweiSocket(host: host, port: 5684, udp: true)
        defer { socket.close() }
        try await socket.start()
        // Discoverer mode does not publish a receiver that this app cannot serve.
        let object: [String: Any] = ["deviceId": "{\"UDID\":\"\(UUID().uuidString)\"}", "devicename": name,
            "type": 14, "mode": 1, "hicomversion": "", "deviceHash": "", "serviceData": "port:1,",
            "extendServiceData": "osType:2,nbVer:9", "wlanIp": network.address, "capabilityBitmap": [256],
            "bType": 5, "seqNo": Int.random(in: 0...65_535), "coapUri": "coap://\(network.address):5684/device_discover"]
        let packet = Data([0x42,0x02]) + (try HuaweiWire.random(4)) + Data([0xbd,0x02]) + Data("device_discover".utf8) + Data([0x11,0x32,0xff]) + (try HuaweiWire.json(object, nul: false))
        try await socket.send(packet)
        for _ in 0..<8 {
            let bytes = try await socket.datagram()
            if bytes.count == 4, bytes[0] == 0x60 { continue }
            let peer = try decode(bytes, host: host, network: network)
            if (bytes[0] >> 4) & 3 == 0 { try await socket.send(Data([0x60,0]) + bytes[2..<4]) }
            return peer
        }
        throw HuaweiFailure.discovery
    }
    static func decode(_ data: Data, host: String, network: WiFiIPv4Address) throws -> HuaweiPeer {
        guard (4...8192).contains(data.count) else { throw HuaweiFailure.invalid }
        var reader = HuaweiReader(data)
        let first = Int(try reader.integer(1)); let type = (first >> 4) & 3
        guard first >> 6 == 1, first & 15 <= 8, [0,1].contains(type), try reader.integer(1) == 2 else { throw HuaweiFailure.invalid }
        _ = try reader.take(2 + (first & 15))
        var number = 0; var options: [Int: Data] = [:]; var payload = false
        func extended(_ nibble: Int, _ reader: inout HuaweiReader) throws -> Int {
            if nibble < 13 { return nibble }
            guard nibble < 15 else { throw HuaweiFailure.invalid }
            return Int(try reader.integer(nibble == 13 ? 1 : 2)) + (nibble == 13 ? 13 : 269)
        }
        while reader.remaining > 0 {
            let byte = Int(try reader.integer(1))
            if byte == 255 { payload = true; break }
            number += try extended(byte >> 4, &reader); let size = try extended(byte & 15, &reader)
            guard options.count < 16, options[number] == nil, [3,11,12].contains(number) else { throw HuaweiFailure.invalid }
            options[number] = try reader.take(size)
        }
        guard payload, options[11] == Data("device_discover".utf8),
              options[12] == nil || options[12] == Data("2".utf8),
              options[3] == nil || [host, network.address].contains(String(decoding: options[3]!, as: UTF8.self)) else { throw HuaweiFailure.invalid }
        let object = try HuaweiWire.object(reader.take(reader.remaining))
        guard object["wlanIp"] as? String == host, object["bType"] as? Int == 5,
              let mode = object["mode"] as? Int, [0,1,2,10].contains(mode),
              let kind = object["type"] as? Int, let caps = object["capabilityBitmap"] as? [UInt32], (1...4).contains(caps.count),
              caps[0] & 256 != 0 || [14,17].contains(kind),
              let identity = object["deviceId"] as? String, (1...512).contains(identity.count),
              let service = object["serviceData"] as? String, service.count <= 256,
              let name = object["devicename"] as? String else { throw HuaweiFailure.invalid }
        let ports = service.split(separator: ",").filter { $0.hasPrefix("port:") }.map { $0.dropFirst(5) }
        guard ports.count == 1, ports[0].allSatisfy({ $0.isASCII && $0.isNumber }), let port = UInt16(ports[0]), port > 0 else { throw HuaweiFailure.invalid }
        let id = SHA256.hash(data: Data((host + "\0" + identity).utf8)).map { String(format: "%02x", $0) }.joined()
        let peer = HuaweiPeer(host: host, port: port, name: name, discoveryID: id)
        try peer.validate(network: network); return peer
    }
}
