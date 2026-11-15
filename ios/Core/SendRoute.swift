// SPDX-License-Identifier: GPL-3.0-only
import Foundation

public struct SendRouteCandidate: Sendable, Equatable {
    public enum Source: String, Sendable { case matchingHint, wifiInterface }
    public let network: WiFiIPv4Address
    public let source: Source
}

public enum SendRouteError: String, Error, LocalizedError, Sendable {
    case noWiFiIPv4, invalidConfirmation, peerMismatch, rejected
    public var errorDescription: String? {
        switch self {
        case .noWiFiIPv4: "送信用のWi-Fi IPv4アドレスを取得できませんでした。"
        case .invalidConfirmation: "相手から通知された接続確認のアドレスを検証できませんでした。"
        case .peerMismatch: "Bluetoothの接続確認と、実際の通信相手が一致しませんでした。"
        case .rejected: "相手がLAN接続を確立できませんでした。診断ログを確認してください。"
        }
    }
}

public enum SendRoutePlanner {
    /// The receiver may announce a dormant hotspot address here. Advertise our
    /// live Wi-Fi address first, then verify its actual address during confirmation.
    public static func candidates(peerHint: String, interfaces: [WiFiIPv4Address]) -> [SendRouteCandidate] {
        let available = interfaces.filter { LocalNetwork.isPrivateIPv4($0.address) }
        let ordered = available.filter { $0.reaches(peerHint) }
            + available.filter { !$0.reaches(peerHint) && !$0.address.hasPrefix("169.254.") }
            + available.filter { !$0.reaches(peerHint) && $0.address.hasPrefix("169.254.") }
        var seen = Set<String>()
        return ordered.filter { seen.insert($0.address).inserted }.prefix(4).map {
            SendRouteCandidate(network: $0, source: $0.reaches(peerHint) ? .matchingHint : .wifiInterface)
        }
    }
    public static func diagnostics(peerHint: String, interfaces: [WiFiIPv4Address]) -> [String: String] {
        ["hint_is_private": String(LocalNetwork.isPrivateIPv4(peerHint)),
         "hint_matches_wifi": String(interfaces.contains { $0.reaches(peerHint) }),
         "wifi_ipv4_count": String(min(interfaces.count, 16)),
         "candidate_count": String(candidates(peerHint: peerHint, interfaces: interfaces).count)]
    }
}

/// A hint never authorizes a download. The encrypted BLE confirmation and the
/// actual control connection must agree before file metadata or bytes are sent.
public struct SendPeerAuthorization: Sendable {
    private let network: WiFiIPv4Address
    public private(set) var confirmedHost: String?
    public private(set) var controlHost: String?
    public init(network: WiFiIPv4Address) { self.network = network }
    private func onNetwork(_ host: String) -> Bool {
        LocalNetwork.isPrivateIPv4(host) && (host == network.address || network.reaches(host))
    }
    public func allowsConnection(from host: String) -> Bool {
        onNetwork(host) && (confirmedHost == nil || confirmedHost == host) && (controlHost == nil || controlHost == host)
    }
    public mutating func confirm(_ host: String) throws {
        guard onNetwork(host) else { throw SendRouteError.invalidConfirmation }
        guard (controlHost == nil || controlHost == host), (confirmedHost == nil || confirmedHost == host) else { throw SendRouteError.peerMismatch }
        confirmedHost = host
    }
    public mutating func registerControl(from host: String) throws {
        guard allowsConnection(from: host) else { throw SendRouteError.peerMismatch }
        controlHost = host
    }
    public func allowsDownload(from host: String) -> Bool { confirmedHost == host && controlHost == host }
}
