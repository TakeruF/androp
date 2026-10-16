// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 anDrop contributors
import AppKit
import AppIntents

nonisolated struct ReceiveSettingsIntent: AppIntent {
    static let title: LocalizedStringResource = "Receive"
    @MainActor func perform() async throws -> some IntentResult {
        guard NSWorkspace.shared.open(URL(string: "androp://control/receive")!) else { throw ControlError.cannotOpen }
        return .result()
    }
}
nonisolated enum ControlError: Error { case cannotOpen }
