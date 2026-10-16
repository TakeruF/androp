// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 anDrop contributors
import AppIntents
import SwiftUI
import WidgetKit

nonisolated struct ReceiveControlProvider: ControlValueProvider {
    var previewValue: ReceiveControlState { .preview }
    func currentValue() async throws -> ReceiveControlState {
        await MainActor.run { ReceiveControlStore.read() }
    }
}

struct ReceiveControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        // Keep the original kind so an already-added tile updates in place.
        StaticControlConfiguration(kind: ReceiveControlStore.kind, provider: ReceiveControlProvider()) { state in
            ControlWidgetToggle(isOn: state.isOn, action: ReceiveSettingsIntent()) {
                Text("anDrop")
            } valueLabel: { _ in
                Label { Text(state.status) } icon: {
                    Image(systemName: "paperplane.circle.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(state.isOn ? Color.accentColor : Color.secondary, state.isOn ? Color.white : Color.secondary.opacity(0.25))
                }
                    .controlWidgetStatus(state.status)
                    .controlWidgetActionHint("Receiving Options")
            }.tint(Color.accentColor)
        }.displayName("anDrop").description("Manage anDrop receiving and trusted devices.")
    }
}
@main struct AnDropControls: WidgetBundle {
    var body: some Widget { ReceiveControl() }
}
