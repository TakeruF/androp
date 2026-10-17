// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 anDrop contributors

import Foundation

/// Gates control negotiation. The engine verifies the sender ID before offering
/// a receive prompt or downloading files. Bluetooth discovery is still public.
nonisolated enum ReceiveAccessPolicy {
    static func persistentID(_ value: String) -> Bool {
        let prefix: String
        if value.hasPrefix("sender:") { prefix = "sender:" }
        else if value.hasPrefix("huawei-key:") { prefix = "huawei-key:" }
        else { return false }
        return value.count == prefix.count + 64 && value.dropFirst(prefix.count).allSatisfy { "0123456789abcdef".contains($0) }
    }
    static func allows(centralID: String, enabled: Bool, trustedOnly: Bool,
                       trustedIDs: [String], activeReceiveID: String? = nil) -> Bool {
        guard let central = UUID(uuidString: centralID) else { return false }
        // A previously accepted transfer may finish after removing trust.
        if let activeReceiveID, UUID(uuidString: activeReceiveID) == central { return true }
        guard enabled else { return false }
        // New Bluetooth addresses may negotiate only far enough to present their
        // protocol sender ID. The engine authorizes that ID before any download.
        return !trustedOnly || trustedIDs.contains { ($0.hasPrefix("sender:") && persistentID($0)) || UUID(uuidString: $0) == central }
    }
}
