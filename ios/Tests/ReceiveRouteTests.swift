// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Testing
@testable import anDropProtocol

private let wifi = [WiFiIPv4Address(address: "192.168.5.10", netmask: "255.255.255.0")]

@Test func normalLANOfferUsesAdvertisedEndpoint() throws {
    var planner = ReceiveRoutePlanner()
    let selected = try planner.resolve(.init(host: "192.168.5.2", port: "9000", mode: .lan), interfaces: wifi)
    let route = try #require(selected)
    #expect(route.host == "192.168.5.2" && route.port == 9000)
    #expect(route.localAddress == "192.168.5.10")
    #expect(route.source == .advertised && route.acknowledgeLAN)
}

@Test func hotspotOfferKeepsSameSessionWiFiAddress() throws {
    // The phone remains on Wi-Fi while its offer names a Wi-Fi Direct endpoint.
    // Use the LAN hint from that same BLE session with the newly announced port.
    var planner = ReceiveRoutePlanner(initialHint: "192.168.5.2")
    let selected = try planner.resolve(.init(host: "192.168.49.1", port: "9002", mode: .direct), interfaces: wifi)
    let route = try #require(selected)
    #expect(route.host == "192.168.5.2" && route.port == 9002)
    #expect(route.source == .initialHint && !route.acknowledgeLAN)
}

@Test func laterLANHintTakesPriorityOverInitialHint() throws {
    var planner = ReceiveRoutePlanner(initialHint: "192.168.5.2")
    _ = try planner.resolve(.init(host: "192.168.5.3", port: "9000", mode: .lan), interfaces: wifi)
    let selected = try planner.resolve(.init(host: "192.168.49.1", port: "9002", mode: .direct), interfaces: wifi)
    let route = try #require(selected)
    #expect(route.host == "192.168.5.3")
    #expect(route.source == .lanHint)
}

@Test func reuseOfferUsesOnlyCurrentSessionsHint() throws {
    var first = ReceiveRoutePlanner(initialHint: "192.168.5.2")
    let selected = try first.resolve(.init(host: nil, port: "9000", mode: .reuse), interfaces: wifi)
    let route = try #require(selected)
    #expect(route.host == "192.168.5.2" && route.source == .reusedHint)
    var next = ReceiveRoutePlanner()
    #expect(throws: ReceiveRouteError.missingSessionAddress) {
        try next.resolve(.init(host: nil, port: "9000", mode: .reuse), interfaces: wifi)
    }
}

@Test func searchesAllWiFiAddressesInsteadOfStoppingAtFirstMismatch() throws {
    let interfaces = [WiFiIPv4Address(address: "169.254.3.4", netmask: "255.255.0.0")] + wifi
    var planner = ReceiveRoutePlanner()
    let selected = try planner.resolve(.init(host: "192.168.5.2", port: "9000", mode: .lan), interfaces: interfaces)
    let route = try #require(selected)
    #expect(route.localAddress == "192.168.5.10")
}

@Test func rejectsUnmatchedAddressWithoutClaimingDifferentWiFi() throws {
    var planner = ReceiveRoutePlanner()
    #expect(throws: ReceiveRouteError.noMatchingWiFiAddress) {
        try planner.resolve(.init(host: "192.168.49.1", port: "9000", mode: .direct), interfaces: wifi)
    }
    #expect(throws: ReceiveRouteError.invalidAddress) {
        try planner.resolve(.init(host: "8.8.8.8", port: "9000", mode: .lan), interfaces: wifi)
    }
    #expect(throws: ReceiveRouteError.noWiFiIPv4) {
        try planner.resolve(.init(host: "192.168.5.2", port: "9000", mode: .lan), interfaces: [])
    }
    for port in ["-1", "0", "65535", "70000", "invalid"] {
        #expect(throws: ReceiveRouteError.invalidPort) {
            try planner.resolve(.init(host: "192.168.5.2", port: port, mode: .lan), interfaces: wifi)
        }
    }
}

@Test func decodesOriginalEncryptedOfferFieldsBeforeSelectingRoute() throws {
    var sender = NegotiationKeys(); var receiver = NegotiationKeys()
    try sender.derive(peer: receiver.publicKey); try receiver.derive(peer: sender.publicKey)
    let initialIP = try receiver.decrypt(sender.encrypt("192.168.5.2"))
    var planner = ReceiveRoutePlanner(initialHint: initialIP)
    let direct = try ReceiveNetworkOffer(payload: ["ssid": sender.encrypt("fixture"), "ip": sender.encrypt("192.168.49.1"), "port": sender.encrypt("9002")], keys: receiver)
    let selected = try planner.resolve(direct, interfaces: wifi)
    let route = try #require(selected)
    #expect(route.host == "192.168.5.2" && route.port == 9002)
    let reuse = try ReceiveNetworkOffer(payload: ["reuse": sender.encrypt("true"), "port": sender.encrypt("9004")], keys: receiver)
    let reused = try planner.resolve(reuse, interfaces: wifi)
    #expect(reused?.port == 9004)
    let diagnostic = planner.diagnosticFields(for: direct, interfaces: wifi)
    #expect(diagnostic["offer_mode"] == "direct")
    #expect(diagnostic["has_initial_hint"] == "true")
    #expect(diagnostic["advertised_address_matches_wifi"] == "false")
    let output = try JSONSerialization.data(withJSONObject: diagnostic)
    let text = String(decoding: output, as: UTF8.self)
    #expect(!text.contains("192.168.") && !text.contains("fixture") && !text.contains("9002"))
}
