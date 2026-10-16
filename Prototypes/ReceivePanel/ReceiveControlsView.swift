// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 anDrop contributors
import AppKit
import SwiftUI

// One system glass surface; avoid stacking translucent effects behind each row.
@MainActor
func makeReceiveControlsContent<V: View>(_ view: V) -> NSView {
    let host = NSHostingView(rootView: view)
    let bounds = NSRect(origin: .zero, size: host.fittingSize)
    host.frame = bounds
    host.autoresizingMask = [.width, .height]
    if #available(macOS 26.0, *) {
        let glass = NSGlassEffectView(frame: bounds)
        glass.style = .regular
        glass.cornerRadius = 16
        glass.contentView = host
        return glass
    }
    let material = NSVisualEffectView(frame: bounds)
    material.material = .popover
    material.blendingMode = .behindWindow
    material.state = .active
    material.wantsLayer = true
    material.layer?.cornerRadius = 16
    material.layer?.masksToBounds = true
    material.addSubview(host)
    return material
}

struct ReceiveControlsView: View {
    @Binding var isOn: Bool
    @Binding var trustedOnly: Bool
    var radiosAvailable = true
    var chinese = false
    var dismiss: () -> Void = {}
    private func text(_ english: String, _ simplifiedChinese: String) -> String {
        chinese ? simplifiedChinese : english
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("anDrop").font(.system(size: 14, weight: .bold))
                Spacer()
                Toggle(text("Receive", "接收"), isOn: $isOn)
                    .labelsHidden().toggleStyle(.switch).controlSize(.regular)
                    .accessibilityLabel(text("Receive", "接收"))
                    .disabled(!radiosAvailable)
                    .help(radiosAvailable ? text("Turn off to quit anDrop", "关闭后退出 anDrop") : text("Turn on Bluetooth and Wi-Fi in Control Center", "请在控制中心开启蓝牙和 Wi-Fi"))
            }.padding(.horizontal, 14).frame(height: 42)
            Divider().padding(.horizontal, 14)
            VStack(spacing: 0) {
                ReceiveScopeRow(title: text("Trusted Devices Only", "仅限信任设备"), symbol: "person.crop.circle", selected: trustedOnly, enabled: isOn, chinese: chinese) { trustedOnly = true }
                    .help(text("Other devices can still see this Mac, but their transfer requests are rejected.", "未受信任的设备仍可发现此 Mac，但其传输请求会被拒绝。"))
                ReceiveScopeRow(title: text("Everyone", "所有人"), symbol: "person.2.fill", selected: !trustedOnly, enabled: isOn, chinese: chinese) { trustedOnly = false }
            }.padding(.horizontal, 7).padding(.top, 5).padding(.bottom, 6)
        }.frame(width: 308).onExitCommand(perform: dismiss)
    }
}

struct ReceiveScopeRow: View {
    let title: String
    let symbol: String
    let selected: Bool
    let enabled: Bool
    var chinese = false
    let action: () -> Void
    private func text(_ english: String, _ simplifiedChinese: String) -> String {
        chinese ? simplifiedChinese : english
    }
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var hovering = false
    private var selectionOpacity: Double { contrast == .increased ? 0.24 : 0.12 }
    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol).resizable().scaledToFit()
                    .fontWeight(.medium).symbolRenderingMode(.monochrome)
                    .frame(width: symbol == "person.2.fill" ? 18 : 16, height: 16)
                    .foregroundStyle(selected && enabled ? Color.accentColor : Color.primary)
                    .frame(width: 26, height: 26)
                    .background(selected && enabled ? Color.white : Color.primary.opacity(0.12), in: Circle())
                Text(title).font(.system(size: 14, weight: .medium)).lineLimit(1)
                Spacer(minLength: 0)
            }.padding(.horizontal, 7).frame(height: 32).contentShape(Rectangle())
                .background(Color.primary.opacity(enabled ? (selected ? selectionOpacity : hovering ? 0.06 : 0) : 0), in: RoundedRectangle(cornerRadius: 9))
        }.buttonStyle(.plain).disabled(!enabled).onHover { hovering = $0 }
            .accessibilityValue(selected ? text("Selected", "已选择") : text("Not selected", "未选择"))
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
