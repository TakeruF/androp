// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 anDrop contributors
import AppKit
import AppIntents

nonisolated struct ReceiveSettingsIntent: AppIntent {
    static let title: LocalizedStringResource = "Receive"
    @MainActor func perform() async throws -> some IntentResult {
        var hostURL = Bundle.main.bundleURL
        if hostURL.pathExtension == "appex" {
            for _ in 0..<3 { hostURL.deleteLastPathComponent() }
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        _ = try await NSWorkspace.shared.open([URL(string: "androp://control/receive")!], withApplicationAt: hostURL, configuration: configuration)
        return .result()
    }
}
