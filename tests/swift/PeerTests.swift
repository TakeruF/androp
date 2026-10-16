// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 anDrop contributors

import Foundation
import Testing
@testable import anDropIdentity

@Test func sameAccountPhoneAndTabletHaveDifferentLabels() {
    let phone = Peer(id: "phone", name: "Shared account", brand: "OPPO", kind: .phone)
    let tablet = Peer(id: "tablet", name: "Shared account", brand: "OPPO", kind: .tablet)
    #expect(phone.title(aliases: [:], chinese: false) == "Shared account")
    #expect(tablet.subtitle(aliases: [:], chinese: true) == "OPPO 平板")
    #expect(phone.symbol != tablet.symbol)
    #expect(!phone.isAmbiguous(among: [phone, tablet], aliases: [:], chinese: false))
}

@Test func aliasPersistsByEndpointAndDoesNotFollowAccountName() throws {
    let first = Peer(id: "first-device", name: "Shared account", brand: "OPPO", kind: .phone)
    let second = Peer(id: "second-device", name: "Shared account", brand: "OPPO", kind: .phone)
    let encoded = try JSONEncoder().encode([first.aliasKey: "Work phone"])
    let aliases = try JSONDecoder().decode([String:String].self, from: encoded)
    let rediscovered = Peer(id: "first-device", name: "Renamed account", brand: "OPPO", kind: .phone)
    #expect(rediscovered.title(aliases: aliases, chinese: false) == "Work phone")
    #expect(second.title(aliases: aliases, chinese: false) == "Shared account")
    #expect(first.aliasKey != second.aliasKey)
}

@Test func identicalPhonesHaveDifferentCodesAndCanBeNamed() {
    let first = Peer(id: "first", name: "Shared account", brand: "OPPO", kind: .phone)
    let second = Peer(id: "second", name: "Shared account", brand: "OPPO", kind: .phone)
    let peers = [first, second]
    #expect(first.isAmbiguous(among: peers, aliases: [:], chinese: false))
    #expect(first.distinguishingCode(among: peers) != second.distinguishingCode(among: peers))
    #expect(!first.isAmbiguous(among: peers, aliases: [first.aliasKey:"Work"], chinese: false))
}

@Test func unknownKindsAndNamesAreNotMadeIntoModels() {
    let peer = Peer(id: "unknown", name: "Example device")
    #expect(peer.title(aliases: [:], chinese: false) == "Example device")
    #expect(peer.deviceLabel(chinese: false).isEmpty)
}

@Test func aliasLimitIsVisibleAndUnicodeAware() {
    #expect(Peer.normalizedAlias("  Work tablet  ") == "Work tablet")
    #expect(Peer.normalizedAlias("") == "")
    #expect(Peer.normalizedAlias(String(repeating: "平", count: 40)) != nil)
    #expect(Peer.normalizedAlias(String(repeating: "平", count: 41)) == nil)
    #expect(Peer.normalizedAlias("Work\nphone") == nil)
}

@Test func sameAliasNeedsACodeEvenWhenHiddenAccountNamesDiffer() {
    let first = Peer(id: "first", name: "Account A", brand: "OPPO", kind: .phone)
    let second = Peer(id: "second", name: "Account B", brand: "OPPO", kind: .phone)
    let aliases = [first.aliasKey: "Work", second.aliasKey: "Work"]
    #expect(first.isAmbiguous(among: [first, second], aliases: aliases, chinese: false))
}
