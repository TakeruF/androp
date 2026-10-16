// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 anDrop contributors
import AppKit
import SwiftUI

private struct MockReceivePanel: View {
    @State private var isOn = true
    @State private var trustedOnly = true
    let chinese: Bool
    var body: some View {
        ReceiveControlsView(isOn: $isOn, trustedOnly: $trustedOnly, chinese: chinese) {
            NSApplication.shared.terminate(nil)
        }
    }
}

@MainActor
private final class PreviewPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@main
private enum ReceivePanelPreview {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let content = makeReceiveControlsContent(MockReceivePanel(chinese: !CommandLine.arguments.contains("--english")))
        let panel = PreviewPanel(contentRect: content.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
        panel.title = "anDrop — UI preview"
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.contentView = content
        panel.center()
        app.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        withExtendedLifetime(panel) { app.run() }
    }
}
