// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 anDrop contributors

import Testing
@testable import anDropIdentity

private let trustedCentral = "00000000-0000-0000-0000-00000000000A"
private let unknownCentral = "00000000-0000-0000-0000-00000000000B"

@Test func gattUnknownCentralCannotReadOrWriteInTrustedMode() {
    #expect(!ReceiveAccessPolicy.allows(centralID: unknownCentral, enabled: true,
        trustedOnly: true, trustedIDs: [trustedCentral]))
    #expect(ReceiveAccessPolicy.allows(centralID: trustedCentral.lowercased(), enabled: true,
        trustedOnly: true, trustedIDs: [trustedCentral]))
    #expect(!ReceiveAccessPolicy.allows(centralID: trustedCentral, enabled: true,
        trustedOnly: true, trustedIDs: []))
}

@Test func gattEveryoneStillRequiresAvailableReceiverAndAnEndpointIdentity() {
    #expect(ReceiveAccessPolicy.allows(centralID: unknownCentral, enabled: true,
        trustedOnly: false, trustedIDs: []))
    #expect(!ReceiveAccessPolicy.allows(centralID: unknownCentral, enabled: false,
        trustedOnly: false, trustedIDs: []))
    #expect(!ReceiveAccessPolicy.allows(centralID: "Same account name", enabled: true,
        trustedOnly: false, trustedIDs: []))
}

@Test func removingTrustDoesNotInterruptPreviouslyAcceptedTransfer() {
    #expect(ReceiveAccessPolicy.allows(centralID: trustedCentral, enabled: true,
        trustedOnly: true, trustedIDs: [], activeReceiveID: trustedCentral.lowercased()))
    #expect(!ReceiveAccessPolicy.allows(centralID: unknownCentral, enabled: true,
        trustedOnly: true, trustedIDs: [], activeReceiveID: trustedCentral))
    // Once the session ends the exemption disappears, so a new request is rejected.
    #expect(!ReceiveAccessPolicy.allows(centralID: trustedCentral, enabled: true,
        trustedOnly: true, trustedIDs: []))
}

@Test func rotatingAddressCanNegotiateForStableIdentityValidation() {
    let senderID = "sender:" + String(repeating: "a", count: 64)
    #expect(ReceiveAccessPolicy.persistentID(senderID))
    #expect(!ReceiveAccessPolicy.persistentID("sender:" + String(repeating: "g", count: 64)))
    #expect(ReceiveAccessPolicy.allows(centralID: unknownCentral, enabled: true, trustedOnly: true, trustedIDs: [senderID]))
    #expect(!ReceiveAccessPolicy.allows(centralID: unknownCentral, enabled: false, trustedOnly: true, trustedIDs: [senderID]))
}

@Test func huaweiKeysCanBeRememberedWithoutAuthorizingAllianceBluetooth() {
    let identity = "huawei-key:" + String(repeating: "a", count: 64)
    #expect(ReceiveAccessPolicy.persistentID(identity))
    #expect(!ReceiveAccessPolicy.persistentID("huawei-key:" + String(repeating: "g", count: 64)))
    #expect(!ReceiveAccessPolicy.persistentID("huawei-key:" + String(repeating: "a", count: 63)))
    #expect(!ReceiveAccessPolicy.persistentID("huawei:discovery-only"))
    #expect(!ReceiveAccessPolicy.allows(centralID: unknownCentral, enabled: true,
        trustedOnly: true, trustedIDs: [identity]))
}
