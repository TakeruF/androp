// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Darwin

public struct WiFiIPv4Address: Equatable, Sendable {
    public let address: String
    public let netmask: String
    public init(address: String, netmask: String) { self.address = address; self.netmask = netmask }
    public func reaches(_ peer: String) -> Bool {
        guard LocalNetwork.isPrivateIPv4(peer), LocalNetwork.isPrivateIPv4(address),
              let local = Self.number(address), let remote = Self.number(peer), let mask = Self.number(netmask), mask != 0,
              local != remote else { return false }
        return local & mask == remote & mask
    }
    private static func number(_ text: String) -> UInt32? {
        let fields = text.split(separator: ".", omittingEmptySubsequences: false)
        guard fields.count == 4 else { return nil }
        let numbers = fields.compactMap { UInt8($0) }
        guard numbers.count == 4 else { return nil }
        return numbers.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }
    public static func current() -> [WiFiIPv4Address] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { return [] }
        defer { freeifaddrs(list) }
        var current = list; var result: [WiFiIPv4Address] = []
        while let item = current {
            defer { current = item.pointee.ifa_next }
            guard String(cString: item.pointee.ifa_name) == "en0", item.pointee.ifa_flags & UInt32(IFF_UP) != 0,
                  let raw = item.pointee.ifa_addr, raw.pointee.sa_family == UInt8(AF_INET), let mask = item.pointee.ifa_netmask else { continue }
            var address = UnsafeRawPointer(raw).assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr
            var netmask = UnsafeRawPointer(mask).assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr
            func text(_ value: inout in_addr) -> String? {
                var bytes = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                guard inet_ntop(AF_INET, &value, &bytes, socklen_t(bytes.count)) != nil else { return nil }
                return String(decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            }
            if let ip = text(&address), let mask = text(&netmask) { result.append(.init(address: ip, netmask: mask)) }
        }
        return result
    }
}

public struct ReceiveNetworkOffer: Sendable {
    public enum Mode: String, Sendable { case lan, direct, reuse, other }
    public let host: String?
    public let port: String?
    public let mode: Mode
    public init(host: String?, port: String?, mode: Mode) { self.host = host; self.port = port; self.mode = mode }
    public init(payload: [String: Any], keys: NegotiationKeys) throws {
        if payload["wlan"] != nil { mode = .lan }
        else if payload["ssid"] != nil { mode = .direct }
        else if let value = payload["reuse"] as? String, try keys.decrypt(value) == "true" { mode = .reuse }
        else { mode = .other }
        host = try (payload["ip"] as? String).map { try keys.decrypt($0) }
        if let value = payload["port"] {
            guard let value = value as? String else { throw ReceiveRouteError.invalidPort }
            port = try keys.decrypt(value)
        } else { port = nil }
    }
}

public struct ReceiveRoute: Equatable, Sendable {
    public enum Source: String, Sendable { case advertised, initialHint, lanHint, reusedHint }
    public let host: String
    public let port: UInt16
    public let localAddress: String
    public let source: Source
    public let acknowledgeLAN: Bool
}

public enum ReceiveRouteError: String, Error, LocalizedError, Sendable {
    case invalidPort, missingSessionAddress, invalidAddress, noWiFiIPv4, noMatchingWiFiAddress
    public var errorDescription: String? {
        switch self {
        case .invalidPort: "相手から通知された接続先ポートが無効でした。"
        case .missingSessionAddress: "相手の接続先アドレスがまだ通知されていません。"
        case .invalidAddress: "相手から通知された接続先アドレスに対応していません。"
        case .noWiFiIPv4: "この端末のWi-Fi用IPv4アドレスを取得できませんでした。"
        case .noMatchingWiFiAddress: "相手が通知した接続先に対応するWi-Fiアドレスを特定できませんでした。診断ログを確認してください。"
        }
    }
}

/// Hints live only for one BLE receive session. Never borrow another peer's route.
public struct ReceiveRoutePlanner: Sendable {
    public private(set) var initialHint: String?
    public private(set) var lanHint: String?
    public init(initialHint: String? = nil) { self.initialHint = initialHint.flatMap { LocalNetwork.isPrivateIPv4($0) ? $0 : nil } }
    public mutating func resolve(_ offer: ReceiveNetworkOffer, interfaces: [WiFiIPv4Address]) throws -> ReceiveRoute? {
        guard let rawPort = offer.port else { return nil }
        guard let port = UInt16(rawPort), port > 0, port < 65535 else { throw ReceiveRouteError.invalidPort }
        if offer.mode == .lan, let host = offer.host, LocalNetwork.isPrivateIPv4(host) { lanHint = host }
        var candidates: [(String, ReceiveRoute.Source)] = []
        if offer.mode == .direct {
            if let lanHint { candidates.append((lanHint, .lanHint)) }
            if let initialHint { candidates.append((initialHint, .initialHint)) }
        }
        if let host = offer.host { candidates.append((host, .advertised)) }
        else if offer.mode == .reuse, let initialHint { candidates.append((initialHint, .reusedHint)) }
        guard !candidates.isEmpty else { throw ReceiveRouteError.missingSessionAddress }
        guard candidates.contains(where: { LocalNetwork.isPrivateIPv4($0.0) }) else { throw ReceiveRouteError.invalidAddress }
        guard !interfaces.isEmpty else { throw ReceiveRouteError.noWiFiIPv4 }
        for (host, source) in candidates {
            // A link-local or unmatched first address must not hide later Wi-Fi addresses.
            if let local = interfaces.first(where: { $0.reaches(host) }) {
                return ReceiveRoute(host: host, port: port, localAddress: local.address, source: source, acknowledgeLAN: offer.mode == .lan)
            }
        }
        throw ReceiveRouteError.noMatchingWiFiAddress
    }
    public func diagnosticFields(for offer: ReceiveNetworkOffer, interfaces: [WiFiIPv4Address]) -> [String: String] {
        ["offer_mode": offer.mode.rawValue,
         "has_ip": String(offer.host != nil), "has_port": String(offer.port != nil),
         "has_initial_hint": String(initialHint != nil), "has_lan_hint": String(lanHint != nil),
         "wifi_ipv4_count": String(min(interfaces.count, 16)),
         "advertised_address_matches_wifi": String(offer.host.map { host in interfaces.contains { $0.reaches(host) } } ?? false)]
    }
}
