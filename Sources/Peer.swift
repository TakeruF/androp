// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 anDrop contributors

import Foundation
import CryptoKit

struct Peer: Identifiable, Equatable {
    enum Kind: String { case phone, tablet, unknown }
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
        case .unknown: "rectangle.on.rectangle"
        }
    }
    func deviceLabel(chinese: Bool) -> String {
        let type: String
        switch kind {
        case .phone: type = chinese ? "手机" : "Phone"
        case .tablet: type = chinese ? "平板" : "Tablet"
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
        let title = title(aliases: aliases, chinese: chinese)
        return [deviceLabel(chinese: chinese), localizedName(chinese: chinese)].reduce(into: [String]()) { result, value in
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
