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

@Test func generatedStoredDeviceTypesFollowUILanguage() {
    let phone = Peer(id: "phone", name: "Example · OPPO Phone", brand: "OPPO", kind: .phone)
    let tablet = Peer(id: "tablet", name: "Example · OPPO Tablet", brand: "OPPO", kind: .tablet)
    #expect(phone.title(aliases: [:], chinese: true) == "Example · OPPO 手机")
    #expect(tablet.title(aliases: [:], chinese: true) == "Example · OPPO 平板")
    #expect(phone.title(aliases: [:], chinese: false) == "Example · OPPO Phone")
    let savedChinese = Peer(id: "tablet", name: "Example · OPPO 平板", brand: "OPPO", kind: .tablet)
    #expect(savedChinese.title(aliases: [:], chinese: false) == "Example · OPPO Tablet")
}

@Test func hiddenDevicesPersistWithoutTheRawIdentity() throws {
    let peer = Peer(id: "AA:BB:CC:DD", name: "Work phone", brand: "OPPO", kind: .phone)
    var hidden = HiddenDevices()
    hidden.hide(peer)
    let data = try JSONEncoder().encode(hidden)
    let text = try #require(String(data: data, encoding: .utf8))
    #expect(!text.contains("AA:BB:CC:DD"))
    #expect(text.contains(peer.aliasKey))
    let restored = try JSONDecoder().decode(HiddenDevices.self, from: data)
    #expect(restored == hidden)
    // The stored record still describes the device while it is offline.
    let device = try #require(restored.devices.first)
    #expect(device.title(aliases: [:], chinese: false) == "Work phone")
    #expect(device.subtitle(aliases: [:], chinese: true) == "OPPO 手机")
    #expect(device.title(aliases: [peer.aliasKey: "Travel phone"], chinese: false) == "Travel phone")
    #expect(device.subtitle(aliases: [peer.aliasKey: "Travel phone"], chinese: false) == "OPPO Phone · Work phone")
}

@Test func hidingOneOfTwoSameNamedDevicesKeepsTheOtherVisible() {
    let first = Peer(id: "first", name: "Shared account", brand: "OPPO", kind: .phone)
    let second = Peer(id: "second", name: "Shared account", brand: "OPPO", kind: .phone)
    var hidden = HiddenDevices()
    hidden.hide(first)
    #expect(hidden.contains(first))
    #expect(!hidden.contains(second))
    #expect(hidden.visible([first, second]).map(\.id) == ["second"])
}

@Test func rediscoveryKeepsADeviceHiddenUntilItIsShownAgain() {
    let peer = Peer(id: "phone", name: "Work phone", brand: "OPPO", kind: .phone)
    var hidden = HiddenDevices()
    hidden.hide(peer)
    let rediscovered = Peer(id: "phone", name: "Renamed account", brand: "OPPO", kind: .tablet)
    hidden.hide(rediscovered)
    #expect(hidden.devices.count == 1)
    #expect(hidden.visible([rediscovered]).isEmpty)
    let device = hidden.devices[0]
    hidden.show(device)
    #expect(hidden.devices.isEmpty)
    #expect(hidden.visible([rediscovered]).map(\.id) == ["phone"])
}

@Test func hiddenDevicesWithTheSameNameKeepSeparateIdentities() {
    let first = Peer(id: "first", name: "Shared account", brand: "OPPO", kind: .phone)
    let second = Peer(id: "second", name: "Shared account", brand: "OPPO", kind: .phone)
    var hidden = HiddenDevices()
    hidden.hide(first); hidden.hide(second)
    let devices = hidden.devices
    #expect(devices.count == 2)
    #expect(devices[0].isAmbiguous(among: devices, aliases: [:], chinese: false))
    #expect(devices[0].distinguishingCode(among: devices) != devices[1].distinguishingCode(among: devices))
    // Showing one identity again never affects the other.
    hidden.show(HiddenDevice(peer: second))
    #expect(hidden.devices.map(\.id) == [first.aliasKey])
    #expect(hidden.contains(first) && !hidden.contains(second))
    #expect(hidden.visible([first, second]).map(\.id) == ["second"])
}

@Test func typeLocalizationPreservesUserNamesAndAliases() {
    let phone = Peer(id: "phone", name: "Work Phone", brand: "OPPO", kind: .phone)
    #expect(phone.title(aliases: [:], chinese: true) == "Work Phone")
    let stored = Peer(id: "stored", name: "Example · OPPO Phone", brand: "OPPO", kind: .phone)
    #expect(stored.title(aliases: [stored.aliasKey: "Travel Tablet"], chinese: true) == "Travel Tablet")
    let unknown = Peer(id: "unknown", name: "Example · OPPO Phone")
    #expect(unknown.title(aliases: [:], chinese: true) == "Example · OPPO Phone")
}

@Test func computerTypeAppliesAcrossBrandsAndSurvivesHiddenStorage() throws {
    for brand in ["Huawei", "HONOR", "Xiaomi"] {
        let computer = Peer(id: brand + "-pc", name: "Desk", brand: brand, kind: .computer)
        let phone = Peer(id: brand + "-phone", name: "Desk", brand: brand, kind: .phone)
        #expect(computer.symbol == "desktopcomputer")
        #expect(computer.deviceLabel(chinese: false) == brand + " Computer")
        #expect(computer.deviceLabel(chinese: true) == brand + " 电脑")
        #expect(!computer.isAmbiguous(among: [computer, phone], aliases: [:], chinese: false))
        var hidden = HiddenDevices(); hidden.hide(computer)
        let decoded = try JSONDecoder().decode(HiddenDevices.self, from: JSONEncoder().encode(hidden))
        #expect(decoded.devices.first?.displayPeer.kind == .computer)
        #expect(decoded.devices.first?.displayPeer.symbol == "desktopcomputer")
        let savedName = Peer(id: computer.id, name: "Desk · " + brand + " Computer", brand: brand, kind: .computer)
        #expect(savedName.localizedName(chinese: true) == "Desk · " + brand + " 电脑")
    }
}
