// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 anDrop contributors
import AppIntents
import SwiftUI
import WidgetKit

struct ReceiveControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        // Keep the original primary kind so an already-added tile updates in place.
        StaticControlConfiguration(kind: "org.androp.send") {
            ControlWidgetButton(action: ReceiveSettingsIntent()) { Label("Receive", systemImage: "paperplane") }
        }.displayName("Receive").description("Manage anDrop receiving and trusted devices.")
    }
}
@main struct AnDropControls: WidgetBundle {
    var body: some Widget { ReceiveControl() }
}
