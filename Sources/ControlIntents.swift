// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 anDrop contributors
import AppKit
import AppIntents
import WidgetKit

struct ReceiveSettingsIntent: SetValueIntent {
    static let title: LocalizedStringResource = "Receive"
    static let isDiscoverable = false
    @Parameter(title: "Receive") var value: Bool
    @MainActor func perform() async throws -> some IntentResult {
        // The tile discloses receiving options. Its authoritative value remains
        // the host's current state until the user operates the panel's switch.
        ControlCenter.shared.reloadControls(ofKind: ReceiveControlStore.kind)
        var hostURL = Bundle.main.bundleURL
        if hostURL.pathExtension == "appex" {
            for _ in 0..<3 { hostURL.deleteLastPathComponent() }
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        _ = try await NSWorkspace.shared.open([URL(string: "androp://control/receive")!], withApplicationAt: hostURL, configuration: configuration)
        ControlCenter.shared.reloadControls(ofKind: ReceiveControlStore.kind)
        return .result()
    }
}
