// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 anDrop contributors
import AppKit
import SwiftUI

private enum Stage { case request, receiving, complete, declined }
private enum Language: String, CaseIterable { case chinese = "中文", english = "English" }
private enum DeviceKind: String, CaseIterable {
    case tablet = "タブレット", phone = "スマホ"
    var symbol: String { self == .tablet ? "ipad" : "iphone" }
    var name: String { self == .tablet ? "OPPO Pad" : "OPPO Phone" }
}

@MainActor private enum ManufacturerArtwork {
    static let oppo = Bundle.main.resourceURL.flatMap {
        NSImage(contentsOf: $0.appendingPathComponent("BrandLogos/oppo.svg"))
    }
}

@MainActor
private final class PreviewState: ObservableObject {
    @Published var stage: Stage
    @Published var language: Language = .chinese
    @Published var deviceKind: DeviceKind = .tablet
    @Published var progress = 0.0
    @Published var feedback = ""
    private var simulation: Task<Void, Never>?
    private var autoDismiss: Task<Void, Never>?
    private weak var panel: NSPanel?
    var onManualDismiss: (() -> Void)?

    init(stage: Stage) { self.stage = stage }
    func text(_ en: String, _ zh: String) -> String { language == .english ? en : zh }
    func reset(_ stage: Stage) {
        simulation?.cancel()
        simulation = nil
        autoDismiss?.cancel()
        autoDismiss = nil
        progress = 0
        self.stage = stage
    }
    func attach(_ panel: NSPanel) { self.panel = panel }
    func show() {
        panel?.alphaValue = 1
        panel?.orderFrontRegardless()
        if stage == .complete { scheduleAutoDismiss() }
    }
    func dismiss(manual: Bool = true) {
        autoDismiss?.cancel()
        autoDismiss = nil
        simulation?.cancel()
        simulation = nil
        panel?.orderOut(nil)
        feedback = "通知を閉じました。「もう一度表示」で戻せます。"
        if manual { onManualDismiss?() }
    }
    private func scheduleAutoDismiss() {
        autoDismiss?.cancel()
        autoDismiss = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(15)) } catch { return }
            guard let self, self.stage == .complete else { return }
            self.dismiss(manual: false)
            self.feedback = "完了通知は15秒後に自動で消えました。"
        }
    }
    func accept() {
        reset(.receiving)
        feedback = "受信をシミュレーション中…"
        simulation = Task { [weak self] in
            for step in 1...30 {
                do { try await Task.sleep(for: .milliseconds(70)) } catch { return }
                guard let self else { return }
                self.progress = Double(step) / 30
            }
            guard let self else { return }
            self.stage = .complete
            self.feedback = "受信完了の表示に切り替わりました。"
            self.scheduleAutoDismiss()
        }
    }
}

private struct NotificationCard: View {
    @ObservedObject var state: PreviewState
    @Environment(\.colorSchemeContrast) private var contrast
    private var title: String {
        switch state.stage {
        case .request: state.text("anDrop", "anDrop")
        case .receiving: state.text("Receiving…", "正在接收…")
        case .complete: state.text("Transfer complete", "传输完成")
        case .declined: state.text("Transfer declined", "已拒绝接收")
        }
    }
    private var detail: String {
        switch state.stage {
        case .request: state.text("\(state.deviceKind.name) wants to share “05_L3_Read.pdf”", "\(state.deviceKind.name) 想要共享“05_L3_Read.pdf”")
        case .receiving: state.text("“05_L3_Read.pdf” · \(Int(state.progress * 100))%", "“05_L3_Read.pdf” · \(Int(state.progress * 100))%")
        case .complete: state.text("Received “05_L3_Read.pdf” from \(state.deviceKind.name)", "收到来自 \(state.deviceKind.name) 的“05_L3_Read.pdf”")
        case .declined: state.text("“05_L3_Read.pdf” from \(state.deviceKind.name)", "来自 \(state.deviceKind.name) 的“05_L3_Read.pdf”")
        }
    }
    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(Color(red: 4/255, green: 106/255, blue: 56/255))
                    if let logo = ManufacturerArtwork.oppo {
                        Image(nsImage: logo)
                            .renderingMode(.template).resizable().scaledToFit()
                            .foregroundStyle(.white)
                            .frame(width: 31, height: 15)
                    } else {
                        Text("OPPO").font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                    }
                }.frame(width: 40, height: 40)
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: state.deviceKind.symbol)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 18, height: 18)
                        .background(.regularMaterial, in: Circle())
                        .overlay(Circle().strokeBorder(.white.opacity(0.45), lineWidth: 0.5))
                        .offset(x: 3, y: 3)
                    }
                    .accessibilityLabel("OPPO \(state.deviceKind.rawValue)")
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 14, weight: .semibold))
                    Text(detail).font(.system(size: 13, weight: .medium))
                        .lineLimit(1).truncationMode(.middle).help(detail)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(height: 40)
            HStack(spacing: 8) {
                switch state.stage {
                case .request:
                    action(state.text("Decline", "拒绝")) {
                        state.reset(.declined)
                        state.feedback = "拒否の表示に切り替わりました。"
                    }
                    action(state.text("Accept", "接受")) { state.accept() }
                case .receiving:
                    ProgressView(value: state.progress).tint(.primary)
                        .padding(.horizontal, 5).frame(maxWidth: .infinity)
                        .accessibilityLabel(state.text("Receiving", "正在接收"))
                    action(state.text("Cancel", "取消")) {
                        state.reset(.declined)
                        state.feedback = "受信のシミュレーションをキャンセルしました。"
                    }
                case .complete:
                    action(state.text("Show in Finder", "在访达中显示")) {
                        state.feedback = "「Finderで表示」が押されました（プレビュー）。"
                    }
                    action(state.text("Open", "打开")) {
                        state.feedback = "「開く」が押されました（プレビュー）。"
                    }
                case .declined:
                    action(state.text("Try again", "重新演示")) { state.reset(.request) }
                }
            }.frame(height: 24)
        }
        .padding(12)
        .frame(width: 356, height: 96)
    }
    private func action(_ title: String, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            Text(title).font(.system(size: 13, weight: .semibold))
                .frame(maxWidth: .infinity).frame(height: 24)
                .contentShape(RoundedRectangle(cornerRadius: 11))
        }.buttonStyle(NotificationButtonStyle(highContrast: contrast == .increased))
    }
}

private struct NotificationButtonStyle: ButtonStyle {
    let highContrast: Bool
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.primary)
            .background(Color.primary.opacity(configuration.isPressed ? 0.2 : highContrast ? 0.16 : 0.08),
                        in: RoundedRectangle(cornerRadius: 11))
            .opacity(enabled ? 1 : 0.5)
    }
}

@MainActor
private final class PreviewPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
private final class CornerCloseView: NSView {
    private let closeButton = NSButton(frame: NSRect(x: 8, y: 12, width: 20, height: 20))
    private let state: PreviewState
    private var hoverTimer: Timer?

    init(state: PreviewState) {
        self.state = state
        super.init(frame: NSRect(x: 0, y: 0, width: 40, height: 40))
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: nil)
        closeButton.imagePosition = .imageOnly
        closeButton.imageScaling = .scaleProportionallyDown
        closeButton.contentTintColor = .labelColor
        closeButton.isBordered = false
        closeButton.wantsLayer = true
        closeButton.layer?.cornerRadius = 10
        closeButton.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.88).cgColor
        closeButton.alphaValue = CommandLine.arguments.contains("--show-close") ? 1 : 0
        closeButton.target = self
        closeButton.action = #selector(close)
        closeButton.setAccessibilityLabel(state.text("Dismiss notification", "关闭通知"))
        addSubview(closeButton)
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        hoverTimer?.invalidate()
        hoverTimer = nil
        guard window != nil else { return }
        let timer = Timer(timeInterval: 0.05, target: self,
                          selector: #selector(refreshHover), userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        hoverTimer = timer
        refreshHover()
    }

    @objc private func refreshHover() {
        guard let window else {
            closeButton.alphaValue = 0
            return
        }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        closeButton.alphaValue = NSRect(x: -14, y: 0, width: 64, height: 54).contains(point) ? 1 : 0
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .enabledDuringMouseDrag, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { closeButton.alphaValue = 1 }
    override func mouseExited(with event: NSEvent) { closeButton.alphaValue = 0 }
    override func mouseMoved(with event: NSEvent) { refreshHover() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    @objc private func close() { state.dismiss() }
}

@MainActor
private final class SwipeHostingView: NSHostingView<AnyView> {
    var dismiss: (() -> Void)?
    private var startFrame: NSRect?
    private var rightDistance: CGFloat = 0
    private var finishing = false

    private func positionCard(_ distance: CGFloat, panel: NSPanel, start: NSRect) {
        panel.setFrameOrigin(NSPoint(x: start.minX + distance, y: start.minY))
        panel.alphaValue = 1 - 0.7 * min(distance / start.width, 1)
    }

    private func finishSwipe(cancelled: Bool) {
        guard let panel = window as? NSPanel, let start = startFrame, !finishing else { return }
        let shouldDismiss = !cancelled && rightDistance >= start.width * 0.35
        finishing = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            let end = shouldDismiss ? start.width + 24 : 0
            panel.animator().setFrameOrigin(NSPoint(x: start.minX + end, y: start.minY))
            panel.animator().alphaValue = shouldDismiss ? 0 : 1
        } completionHandler: { [weak self, weak panel] in
            MainActor.assumeIsolated {
                guard let self, let panel else { return }
                if shouldDismiss { self.dismiss?() }
                panel.setFrameOrigin(start.origin)
                panel.alphaValue = 1
                self.startFrame = nil
                self.rightDistance = 0
                self.finishing = false
            }
        }
    }

    override func scrollWheel(with event: NSEvent) {
        guard !finishing, let panel = window as? NSPanel else { return }
        let physicalRight = event.scrollingDeltaX * (event.isDirectionInvertedFromDevice ? 1 : -1)
        let vertical = event.scrollingDeltaY
        if event.phase == .cancelled {
            finishSwipe(cancelled: true)
            return
        }
        if event.phase == .ended {
            finishSwipe(cancelled: false)
            return
        }
        guard event.hasPreciseScrollingDeltas,
              (startFrame != nil || abs(physicalRight) > abs(vertical) * 1.2) else {
            super.scrollWheel(with: event)
            return
        }
        if startFrame == nil { startFrame = panel.frame }
        guard let start = startFrame else { return }
        rightDistance = min(max(0, rightDistance + physicalRight), start.width + 24)
        positionCard(rightDistance, panel: panel, start: start)
    }
}

@MainActor
private func makePanel(state: PreviewState, title: String) -> NSPanel {
    let bounds = NSRect(x: 0, y: 0, width: 356, height: 96)
    let host = SwipeHostingView(rootView: AnyView(NotificationCard(state: state)))
    host.dismiss = { [weak state] in state?.dismiss() }
    host.frame = bounds
    host.autoresizingMask = [.width, .height]
    // A single clipped material surface keeps all four corners identical while
    // the borderless panel is focused, overlapped or composited over another app.
    let surface = NSVisualEffectView(frame: bounds)
    surface.material = .popover
    surface.blendingMode = .behindWindow
    surface.state = .active
    surface.wantsLayer = true
    surface.layer?.cornerRadius = 23
    surface.layer?.masksToBounds = true
    surface.layer?.borderWidth = 0.5
    surface.layer?.borderColor = NSColor.white.withAlphaComponent(0.24).cgColor
    surface.addSubview(host)
    let closeCorner = CornerCloseView(state: state)
    closeCorner.frame.origin = NSPoint(x: 0, y: bounds.height - closeCorner.frame.height)
    surface.addSubview(closeCorner)
    let panel = PreviewPanel(contentRect: bounds, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    panel.title = title
    panel.isReleasedWhenClosed = false
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = false
    panel.hidesOnDeactivate = false
    panel.level = .floating
    panel.isMovableByWindowBackground = false
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    panel.contentView = surface
    state.attach(panel)
    return panel
}

private struct PreviewControls: View {
    @ObservedObject var request: PreviewState
    @ObservedObject var complete: PreviewState
    let replay: () -> Void
    let focusRequest: () -> Void
    let focusComplete: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("anDrop 通知プレビュー").font(.system(size: 20, weight: .semibold))
            Text("右上に2種類の通知を表示しています。\n上は受信確認、下は受信完了です。")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Picker("通知の言語", selection: $request.language) {
                ForEach(Language.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented)
                .onChange(of: request.language) { _, value in complete.language = value }
            Picker("端末の種類", selection: $request.deviceKind) {
                ForEach(DeviceKind.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented)
                .onChange(of: request.deviceKind) { _, value in complete.deviceKind = value }
            Text("右に2本指でスワイプ、またはカード左上角にカーソルを置いて×で閉じられます。完了通知は15秒後に消えます。")
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            Text("すべて架空のデータです。実際の送受信は行いません。")
                .font(.system(size: 12, weight: .medium))
            Text(request.feedback.isEmpty ? "通知のボタンを押して操作を試せます。" : request.feedback).font(.system(size: 12)).foregroundStyle(.secondary)
                .frame(height: 30, alignment: .topLeading)
            if !complete.feedback.isEmpty {
                Text(complete.feedback).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            HStack {
                Button("受信確認を見る", action: focusRequest)
                Button("完了通知を見る", action: focusComplete)
            }
            HStack {
                Button("もう一度表示", action: replay)
                Spacer()
                Button("終了") { NSApplication.shared.terminate(nil) }.keyboardShortcut("q")
            }
        }.padding(24).frame(width: 400)
    }
}

@MainActor
private final class PreviewDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let request = PreviewState(stage: .request)
    private let complete = PreviewState(stage: .complete)
    private var panels: [NSPanel] = []
    private var controls: NSWindow?
    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("--english") { request.language = .english; complete.language = .english }
        panels = [makePanel(state: request, title: "anDrop — Receive preview"),
                  makePanel(state: complete, title: "anDrop — Complete preview")]
        let controls = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 440),
                                styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        controls.title = "anDrop — 通知プレビュー"
        controls.isReleasedWhenClosed = false
        controls.delegate = self
        controls.contentView = NSHostingView(rootView: PreviewControls(
            request: request, complete: complete,
            replay: { [weak self] in self?.replay() },
            focusRequest: { [weak self] in self?.showPanel(at: 0) },
            focusComplete: { [weak self] in self?.showPanel(at: 1) }
        ))
        controls.center()
        self.controls = controls
        request.onManualDismiss = { [weak controls] in controls?.makeKeyAndOrderFront(nil) }
        complete.onManualDismiss = { [weak controls] in controls?.makeKeyAndOrderFront(nil) }
        let menu = NSMenu()
        let item = NSMenuItem()
        let submenu = NSMenu()
        submenu.addItem(withTitle: "Quit Notification Preview", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.submenu = submenu
        menu.addItem(item)
        NSApplication.shared.mainMenu = menu
        NSApplication.shared.activate(ignoringOtherApps: true)
        controls.makeKeyAndOrderFront(nil)
        replay()
    }
    private func showPanel(at index: Int) {
        guard panels.indices.contains(index) else { return }
        (index == 0 ? request : complete).show()
        panels[index].makeKeyAndOrderFront(nil)
    }
    private func replay() {
        request.reset(.request)
        complete.reset(.complete)
        request.feedback = ""
        complete.feedback = request.feedback
        guard let screen = controls?.screen ?? NSScreen.main else { return }
        for (index, panel) in panels.enumerated() {
            let visible = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: visible.maxX - 372, y: visible.maxY - 112 - CGFloat(index) * 108))
            (index == 0 ? request : complete).show()
        }
    }
    func windowWillClose(_ notification: Notification) { NSApplication.shared.terminate(nil) }
}

@main
private enum NotificationPreview {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let delegate = PreviewDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
