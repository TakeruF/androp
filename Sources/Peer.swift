// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 anDrop contributors

import Foundation
import CryptoKit

struct Peer: Identifiable, Equatable {
    enum Kind: String, Codable { case phone, tablet, computer, unknown }
    let id: String
    let name: String
    var brand = ""
    var kind: Kind = .unknown

    // Hash the advertised device identity (or Bluetooth endpoint fallback), never the account/display name.
    var aliasKey: String {
        SHA256.hash(data: Data(id.uppercased().utf8)).map { String(format: "%02x", $0) }.joined()
    }
    var symbol: String {
        switch kind {
        case .phone: "smartphone"
        case .tablet: "ipad.landscape"
        case .computer: "desktopcomputer"
        case .unknown: "rectangle.on.rectangle"
        }
    }
    func deviceLabel(chinese: Bool) -> String {
        let type: String
        switch kind {
        case .phone: type = chinese ? "手机" : "Phone"
        case .tablet: type = chinese ? "平板" : "Tablet"
        case .computer: type = chinese ? "电脑" : "Computer"
        case .unknown: type = ""
        }
        return [brand, type].filter { !$0.isEmpty }.joined(separator: " ")
    }
    // Older transfer history saved anDrop's generated type suffix with the name.
    // Localize that exact suffix using metadata, while keeping user names/aliases.
    func localizedName(chinese: Bool) -> String {
        guard kind != .unknown else { return name }
        for label in [deviceLabel(chinese: false), deviceLabel(chinese: true)] {
            let suffix = " · " + label
            if !label.isEmpty, name.hasSuffix(suffix) {
                return String(name.dropLast(suffix.count)) + " · " + deviceLabel(chinese: chinese)
            }
        }
        return name
    }
    func title(aliases: [String: String], chinese: Bool) -> String {
        if let alias = aliases[aliasKey], !alias.isEmpty { return alias }
        let label = deviceLabel(chinese: chinese)
        return name.isEmpty ? label : localizedName(chinese: chinese)
    }
    func subtitle(aliases: [String: String], chinese: Bool) -> String {
        details(excluding: title(aliases: aliases, chinese: chinese), chinese: chinese)
    }
    // Device type and discovered name, minus whatever is already shown as the title.
    func details(excluding title: String, chinese: Bool) -> String {
        [deviceLabel(chinese: chinese), localizedName(chinese: chinese)].reduce(into: [String]()) { result, value in
            if !value.isEmpty, value != title, !result.contains(value) { result.append(value) }
        }.joined(separator: " · ")
    }
    func isAmbiguous(among peers: [Peer], aliases: [String: String], chinese: Bool) -> Bool {
        peers.contains { other in
            other.id != id && other.title(aliases: aliases, chinese: chinese) == title(aliases: aliases, chinese: chinese)
                && other.deviceLabel(chinese: chinese) == deviceLabel(chinese: chinese)
        }
    }
    func distinguishingCode(among peers: [Peer]) -> String {
        let key = aliasKey
        var count = 6
        while count < key.count && peers.contains(where: { $0.id != id && $0.aliasKey.prefix(count) == key.prefix(count) }) { count += 2 }
        return String(key.prefix(count)).uppercased()
    }
    static func normalizedAlias(_ text: String) -> String? {
        let result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.count <= 40, !result.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return result
    }
}

// A device the user keeps out of the recipient list on this Mac.
// Stored under the hashed identity with display metadata only, never the raw ID,
// so the list can be shown and restored while the device is offline.
struct HiddenDevice: Codable, Identifiable, Equatable {
    let id: String
    var name = ""
    var brand = ""
    var kind: Peer.Kind = .unknown

    init(peer: Peer) {
        id = peer.aliasKey; name = peer.name; brand = peer.brand; kind = peer.kind
    }
    // Metadata for the avatar and the labels; carries no identity.
    var displayPeer: Peer { Peer(id: "", name: name, brand: brand, kind: kind) }
    func title(aliases: [String: String], chinese: Bool) -> String {
        if let alias = aliases[id], !alias.isEmpty { return alias }
        return displayPeer.title(aliases: [:], chinese: chinese)
    }
    func subtitle(aliases: [String: String], chinese: Bool) -> String {
        displayPeer.details(excluding: title(aliases: aliases, chinese: chinese), chinese: chinese)
    }
    func isAmbiguous(among devices: [HiddenDevice], aliases: [String: String], chinese: Bool) -> Bool {
        devices.contains { other in
            other.id != id && other.title(aliases: aliases, chinese: chinese) == title(aliases: aliases, chinese: chinese)
        }
    }
    func distinguishingCode(among devices: [HiddenDevice]) -> String {
        var count = 6
        while count < id.count && devices.contains(where: { $0.id != id && $0.id.prefix(count) == id.prefix(count) }) { count += 2 }
        return String(id.prefix(count)).uppercased()
    }
}

// Hiding is always an explicit choice: discovering a device again never clears a record.
struct HiddenDevices: Codable, Equatable {
    private(set) var devices: [HiddenDevice]

    init(devices: [HiddenDevice] = []) { self.devices = devices }
    func contains(_ peer: Peer) -> Bool { devices.contains { $0.id == peer.aliasKey } }
    func visible(_ peers: [Peer]) -> [Peer] { peers.filter { !contains($0) } }
    mutating func hide(_ peer: Peer) {
        guard !contains(peer) else { return }
        devices.insert(HiddenDevice(peer: peer), at: 0)
    }
    mutating func show(_ device: HiddenDevice) { devices.removeAll { $0.id == device.id } }
}
