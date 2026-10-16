// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 anDrop contributors

import Foundation

/// Filters GATT access, not discovery: a Bluetooth advertisement is still public.
nonisolated enum ReceiveAccessPolicy {
    static func allows(centralID: String, enabled: Bool, trustedOnly: Bool,
                       trustedIDs: [String], activeReceiveID: String? = nil) -> Bool {
        guard let central = UUID(uuidString: centralID) else { return false }
        // A previously accepted transfer may finish after removing trust.
        if let activeReceiveID, UUID(uuidString: activeReceiveID) == central { return true }
        guard enabled else { return false }
        return !trustedOnly || trustedIDs.contains { UUID(uuidString: $0) == central }
    }
}
