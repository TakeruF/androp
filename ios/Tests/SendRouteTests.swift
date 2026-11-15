// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Testing
@testable import anDropProtocol

private let sendWiFi = WiFiIPv4Address(address: "192.168.5.10", netmask: "255.255.255.0")

@Test func hotspotAndInvalidHintsDoNotPreventAdvertisingWiFi() {
    for hint in ["192.168.49.1", "0.0.0.0", "bad", "8.8.8.8"] {
        let candidates = SendRoutePlanner.candidates(peerHint: hint, interfaces: [sendWiFi])
        #expect(candidates.count == 1)
        #expect(candidates.first?.network == sendWiFi)
        #expect(candidates.first?.source == .wifiInterface)
    }
    #expect(SendRoutePlanner.candidates(peerHint: "192.168.49.1", interfaces: []).isEmpty)
}

@Test func directHintRanksFirstAndLinkLocalRanksLast() {
    let link = WiFiIPv4Address(address: "169.254.3.4", netmask: "255.255.0.0")
    let second = WiFiIPv4Address(address: "192.168.7.10", netmask: "255.255.255.0")
    let candidates = SendRoutePlanner.candidates(peerHint: "192.168.7.2", interfaces: [link, sendWiFi, second, second])
    #expect(candidates.map(\.network) == [second, sendWiFi, link])
    #expect(candidates.first?.source == .matchingHint)
}

@Test func authorizesBothConfirmationOrders() throws {
    var ackFirst = SendPeerAuthorization(network: sendWiFi)
    #expect(!ackFirst.allowsDownload(from: "192.168.5.2"))
    try ackFirst.confirm("192.168.5.2")
    #expect(!ackFirst.allowsDownload(from: "192.168.5.2"))
    try ackFirst.registerControl(from: "192.168.5.2")
    #expect(ackFirst.allowsDownload(from: "192.168.5.2"))
    var connectionFirst = SendPeerAuthorization(network: sendWiFi)
    try connectionFirst.registerControl(from: "192.168.5.2")
    #expect(!connectionFirst.allowsDownload(from: "192.168.5.2"))
    try connectionFirst.confirm("192.168.5.2")
    #expect(connectionFirst.allowsDownload(from: "192.168.5.2"))
}

@Test func rejectsMismatchAndOffNetworkConnections() throws {
    var state = SendPeerAuthorization(network: sendWiFi)
    for ip in ["8.8.8.8", "127.0.0.1", "192.168.49.1", "invalid"] { #expect(!state.allowsConnection(from: ip)) }
    try state.registerControl(from: "192.168.5.2")
    #expect(throws: SendRouteError.peerMismatch) { try state.confirm("192.168.5.3") }
    #expect(throws: SendRouteError.invalidConfirmation) { try state.confirm("192.168.49.1") }
    #expect(!state.allowsDownload(from: "192.168.5.2"))
    try state.confirm("192.168.5.2")
    #expect(!state.allowsConnection(from: "192.168.5.3"))
    #expect(throws: SendRouteError.peerMismatch) { try state.registerControl(from: "192.168.5.3") }
}

@Test func sendRouteDiagnosticsDoNotContainAddresses() throws {
    let fields = SendRoutePlanner.diagnostics(peerHint: "192.168.49.1", interfaces: [sendWiFi])
    #expect(fields["hint_matches_wifi"] == "false")
    #expect(fields["candidate_count"] == "1")
    let text = String(decoding: try JSONSerialization.data(withJSONObject: fields), as: UTF8.self)
    #expect(!text.contains("192.168."))
}
