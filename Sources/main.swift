// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 anDrop contributors

import AppKit
import SwiftUI
import CoreBluetooth
import UserNotifications
import ServiceManagement

struct Transfer: Identifiable, Codable {
    var id: String
    var direction = "receive"
    var peer = "Android"
    var state = "connecting"
    var name = L("Files", "文件")
    var count = 1
    var total: Int64 = 0
    var completed: Int64 = 0
    var detail = ""
    var paths: [String] = []
    var date = Date()
    var active: Bool { !["complete", "failed", "declined", "cancelled"].contains(state) }
    var progress: TransferProgress { TransferProgress(state: state, completed: completed, total: total) }
    var historyName: String {
        if count != 1 || name == "1 files" || name == "1 file" || name == "1 个文件" {
            return fileCountLabel(count)
        }
        return name
    }
    var historySymbol: String {
        if direction == "send" {
            return count > 1 ? "square.and.arrow.up.on.square" : "square.and.arrow.up"
        }
        return count > 1 ? "square.and.arrow.down.on.square" : "square.and.arrow.down"
    }
    var label: String {
        switch state {
        case "request": L("Incoming files", "接收确认")
        case "preparing": L("Preparing", "正在准备")
        case "waiting": L("Waiting for acceptance", "等待对方接收")
        case "connecting": L("Connecting", "正在连接")
        case "confirming": L("Finishing", "正在确认完成")
        case "transferring": direction == "send" ? L("Sending", "正在发送") : L("Receiving", "正在接收")
        case "complete": direction == "send" ? L("Sent", "已发送") : L("Received", "已接收")
        case "declined": L("Declined", "已拒绝")
        case "cancelled": L("Cancelled", "已取消")
        default: L("Transfer failed", "传输失败")
        }
    }
}

@MainActor
final class RecipientPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class AppModel: NSObject, ObservableObject, NSApplicationDelegate, @preconcurrency CBPeripheralManagerDelegate, @preconcurrency UNUserNotificationCenterDelegate, NSMenuDelegate, NSWindowDelegate {
    @Published var language = UserDefaults.standard.string(forKey: "language") ?? "system"
    @Published var peers: [Peer] = []
    @Published private(set) var peerAliases = UserDefaults.standard.dictionary(forKey: "peerAliases") as? [String: String] ?? [:]
    @Published var transfers: [Transfer] = []
    @Published var outgoing: OutgoingPresentation?
    @Published var renamingPeer: Peer?
    var outgoingTransfer: Transfer? { transfers.first { $0.id == outgoing?.id } }
    var recipientFiles: [URL] { outgoing?.files ?? selectedFiles }
    var visiblePeers: [Peer] { outgoing.map { [$0.peer] } ?? sortedPeers }
    @Published var selectedFiles: [URL] = []
    @Published var selectedPeer: String?
    @Published var tab = 0
    @Published var bluetooth = L("Preparing Bluetooth", "正在准备蓝牙")
    @Published var error = ""
    @Published var petalRunning = false
    @Published var petalRepairing = false
    private var compactName = false
    @Published var receiving = UserDefaults.standard.object(forKey: "enabled") as? Bool ?? true
    @Published var engineReady = false
    @Published var notificationsAllowed = false
    @Published var destination = UserDefaults.standard.string(forKey: "destination") ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0].path
    @Published var startAtLogin = false
    private var window: NSWindow?
    private var item: NSStatusItem?
    private var recipientPanel: RecipientPanel?
    private var completedClickMonitors: [Any] = []
    private var menuTracking = false
    private var activity: NSObjectProtocol?
    private var peripheral: CBPeripheralManager?
    private var chars: [String: CBMutableCharacteristic] = [:]
    private var centrals: [String: CBCentral] = [:]
    private var notifyQueue: [(Data, String?)] = []
    private var writes: [String: Data] = [:]
    private var readValue = Data()
    private var process: Process?
    private var input: FileHandle?
    private var outputBuffer = Data()
    private var lastPeerUpdate: ContinuousClock.Instant?
    private var timer: Timer?
    private var serviceReady = false
    private var terminating = false
    private var restartCount = 0
    private var discoveryID = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(6))
    private var advertisedName = ""
    private var configuredName = ""
    var deviceName: String { Host.current().localizedName ?? ProcessInfo.processInfo.hostName }
    var displayName: String {
        if compactName { return "A" }
        // Keep the protocol prefix and name inside a legacy BLE advertisement.
        var name = ""
        for character in deviceName {
            let next = name + String(character)
            if next.utf8.count > 15 { break }
            name = next
        }
        return name.isEmpty ? "Mac" : name
    }
    var busy: Bool { transfers.contains(where: \.active) }
    var byteFormat: ByteCountFormatter { let f = ByteCountFormatter(); f.countStyle = .file; return f }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let data = UserDefaults.standard.data(forKey: "history"), let history = try? JSONDecoder().decode([Transfer].self, from: data) { transfers = history }
        setupMenus()
        setupNotifications()
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep], reason: L("Receive files from nearby devices", "接收附近设备的文件"))
        startAtLogin = SMAppService.mainApp.status == .enabled
        startEngine()
        peripheral = CBPeripheralManager(delegate: self, queue: nil)
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshEnvironment() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(woke), name: NSWorkspace.didWakeNotification, object: nil)
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showSettings(); return false }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) {
        stopCompletedRecipientDismissal()
        terminating = true; peripheral?.stopAdvertising(); input?.closeFile(); process?.terminate(); saveHistory()
    }
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            if url.isFileURL { addFiles([url]) }
            else if url.scheme == "androp", let parts = URLComponents(url: url, resolvingAgainstBaseURL: false), parts.host == "share" {
                let paths = parts.queryItems?.filter { $0.name == "file" }.compactMap(\.value) ?? []
                addFiles(paths.filter { $0.hasPrefix("/") }.map { URL(fileURLWithPath: $0) })
            }
        }
        showRecipients()
    }
    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        addFiles(filenames.map { URL(fileURLWithPath: $0) }); showRecipients(); sender.reply(toOpenOrPrint: .success)
    }
    @objc func woke() { clearPeers(); refreshEnvironment(); advertise() }
    private func setupMenus() {
        let menu = NSMenu(); let appItem = NSMenuItem(); menu.addItem(appItem)
        let appMenu = NSMenu(); appItem.submenu = appMenu
        appMenu.addItem(withTitle: L("About anDrop", "关于 anDrop"), action: #selector(about), keyEquivalent: "")
        appMenu.addItem(withTitle: L("Transfers", "传输"), action: #selector(showWindow), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L("Quit anDrop", "退出 anDrop"), action: #selector(quit), keyEquivalent: "q")
        for entry in appMenu.items where entry.action != nil { entry.target = self }
        let editItem = NSMenuItem(); menu.addItem(editItem); let editMenu = NSMenu(title: L("Edit", "编辑")); editItem.submenu = editMenu
        editMenu.addItem(withTitle: L("Copy", "拷贝"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: L("Paste", "粘贴"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        NSApp.mainMenu = menu
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item?.button?.image = NSImage(systemSymbolName: "arrow.up.arrow.down.circle", accessibilityDescription: "anDrop")
        item?.button?.toolTip = L("anDrop — Share with Android", "anDrop — 与安卓设备共享文件")
        let statusMenu = NSMenu(); statusMenu.autoenablesItems = false; statusMenu.delegate = self; item?.menu = statusMenu
        rebuildMenu()
    }
    @objc func about() {
        let alert = NSAlert()
        alert.messageText = "anDrop 0.1.1"
        alert.informativeText = L("File sharing for the Mutual Transfer Alliance (互传联盟) ecosystem.\nNo prior connection. Use the same Wi-Fi.\n\n© 2026 anDrop contributors\nGPL-3.0-only · No warranty.\nRedistribution is permitted under the license.", "面向互传联盟生态的文件共享。\n无需预先连接，请使用同一 Wi-Fi。\n\n© 2026 anDrop contributors\nGPL-3.0-only · 不提供担保。\n可按许可证条款再分发。")
        alert.addButton(withTitle: L("Close", "关闭"))
        alert.addButton(withTitle: L("Licenses…", "许可证…"))
        if alert.runModal() == .alertSecondButtonReturn, let resources = Bundle.main.resourceURL {
            NSWorkspace.shared.activateFileViewerSelecting([resources.appendingPathComponent("LICENSE"), resources.appendingPathComponent("NOTICE.md"), resources.appendingPathComponent("ThirdPartyNotices")])
        }
    }
    @objc func quit() { NSApp.terminate(nil) }
    @objc func toggleEnabled() { changeReceiving(!receiving) }
    @objc func pickAndSend() { chooseFiles(); if !selectedFiles.isEmpty { showRecipients() } }
    @objc func showSendProgress() { showRecipients() }
    @objc func cancelMenu(_ sender: NSMenuItem) { if let id = sender.representedObject as? String, let t = transfers.first(where: { $0.id == id }) { cancel(t) } }
    @objc func revealMenu(_ sender: NSMenuItem) { if let id = sender.representedObject as? String, let t = transfers.first(where: { $0.id == id }) { reveal(t) } }
    @objc func acceptMenu(_ sender: NSMenuItem) { if let id = sender.representedObject as? String, let t = transfers.first(where: { $0.id == id }) { decide(t, accept: true) } }
    @objc func declineMenu(_ sender: NSMenuItem) { if let id = sender.representedObject as? String, let t = transfers.first(where: { $0.id == id }) { decide(t, accept: false) } }
    func menuWillOpen(_ menu: NSMenu) { rebuildMenu(); menuTracking = true }
    func menuDidClose(_ menu: NSMenu) { menuTracking = false }
    private func rebuildMenu() {
        guard !menuTracking, let menu = item?.menu else { return }
        menu.removeAllItems()
        func add(_ title: String, _ selector: Selector? = nil, id: String? = nil) {
            let row = NSMenuItem(title: title, action: selector, keyEquivalent: ""); row.target = self; row.representedObject = id; row.isEnabled = selector != nil; menu.addItem(row)
        }
        add(receiving ? L("anDrop On", "anDrop 已开启") : L("anDrop Off", "anDrop 已关闭"), #selector(toggleEnabled)); menu.items.last?.state = receiving ? .on : .off
        add(receiving ? L("Discoverable as: \(displayName)", "显示名称：\(displayName)") : L("Sharing is off", "文件共享已关闭"))
        if petalRunning { add(L("Petal coexistence · Experimental", "与 Petal 共存 · 实验性支持")); add(L("Repair Discovery with Petal…", "修复与 Petal 的设备发现…"), #selector(repairPetal)); menu.items.last?.isEnabled = !busy && !petalRepairing }
        menu.addItem(.separator()); add(L("Send Files…", "发送文件…"), #selector(pickAndSend)); menu.items.last?.isEnabled = receiving && !busy
        for t in transfers.filter(\.active) {
            menu.addItem(.separator())
            let progress = t.state == "transferring" ? t.progress.percent.map { " \($0)%" } ?? "" : ""
            add("\(t.peer) — \(t.label)\(progress)")
            if t.direction == "send", t.id == outgoing?.id { add(L("Show Progress…", "查看进度…"), #selector(showSendProgress)) }
            if t.state == "request" { add(L("Accept \(fileCountLabel(t.count))", "接收 \(t.count) 个文件"), #selector(acceptMenu(_:)), id: t.id); add(L("Decline", "拒绝"), #selector(declineMenu(_:)), id: t.id) }
            else { add(L("Cancel This Transfer", "取消此次传输"), #selector(cancelMenu(_:)), id: t.id) }
        }
        let recent = transfers.filter { !$0.active }.prefix(8)
        if !recent.isEmpty {
            menu.addItem(.separator())
            let row = NSMenuItem(title: L("Recent Transfers", "最近传输"), action: nil, keyEquivalent: ""); let submenu = NSMenu(); row.submenu = submenu
            for t in recent {
                let label = "\(t.historyName) — \(t.label)"
                let entry = NSMenuItem(title: label, action: t.paths.isEmpty ? nil : #selector(revealMenu(_:)), keyEquivalent: ""); entry.target = self; entry.representedObject = t.id
                entry.image = NSImage(systemSymbolName: t.historySymbol, accessibilityDescription: t.direction == "send" ? L("Sent", "已发送") : L("Received", "已接收"))
                entry.image?.size = NSSize(width: 18, height: 18)
                submenu.addItem(entry)
            }
            menu.addItem(row)
        }
        if !error.isEmpty { menu.addItem(.separator()); add(String(error.prefix(100))) }
        menu.addItem(.separator()); add(L("Settings…", "设置…"), #selector(showSettings)); add(L("Quit anDrop", "退出 anDrop"), #selector(quit))
    }
    @objc func repairPetal() {
        guard !petalRepairing, !busy, let petal = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "com.EMUIInterconnect.app" }), let url = petal.bundleURL else { return }
        petalRepairing = true; compactName = true; peripheral?.stopAdvertising(); advertisedName = ""
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        guard petal.terminate() else { petalRepairing = false; advertise(); error = L("Please quit and reopen Petal to restore discovery.", "请退出并重新打开 Petal，以恢复设备发现。"); return }
        Task { @MainActor in
            for _ in 0..<100 {
                if petal.isTerminated { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            if petal.isTerminated {
                try? await Task.sleep(for: .milliseconds(700))
                // Foreground priority is evaluated when the advertisement is registered.
                // The user may have switched apps while Petal was closing.
                NSApp.activate(ignoringOtherApps: true)
                try? await Task.sleep(for: .milliseconds(200))
                advertise()
                try? await Task.sleep(for: .seconds(1))
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = false
                do { _ = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration); error = "" }
                catch { self.error = L("Please reopen Petal Interconnect.", "请重新打开 Petal Interconnect。") }
            } else { error = L("Petal is still open. Finish any transfer, then try again.", "Petal 仍在运行。请完成传输后重试。") }
            try? await Task.sleep(for: .seconds(2))
            petalRepairing = false; advertise(); refreshEnvironment()
        }
    }
    @objc func showWindow() {
        DispatchQueue.main.async { [weak self] in
            guard let self, let menu = self.item?.menu else { return }
            menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        }
    }
    @objc func showSettings() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 510), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = L("anDrop Settings", "anDrop 设置"); w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: SettingsView(model: self)); w.center(); window = w
        }
        window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    func closeRecipients() { recipientPanel?.close() }
    func showRecipients() {
        if recipientPanel?.isVisible != true { clearPeers() }
        command(["command": "scan", "value": outgoing == nil])
        if recipientPanel == nil {
            let panel = RecipientPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 280), styleMask: [.borderless], backing: .buffered, defer: false)
            panel.title = L("Choose a Recipient", "选择接收设备"); panel.isReleasedWhenClosed = false; panel.hidesOnDeactivate = false; panel.delegate = self
            panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
            panel.isMovableByWindowBackground = true
            panel.isFloatingPanel = false; panel.level = .normal
            let hosting = NSHostingView(rootView: RecipientView(model: self))
            hosting.sizingOptions = []
            hosting.autoresizingMask = [.width, .height]
            panel.contentView = hosting; panel.center(); recipientPanel = panel
        }
        recipientPanel?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        updateCompletedRecipientDismissal()
    }
    func peerTitle(_ peer: Peer) -> String { peer.title(aliases: peerAliases, chinese: appLanguage() == "zh") }
    func peerSubtitle(_ peer: Peer) -> String { peer.subtitle(aliases: peerAliases, chinese: appLanguage() == "zh") }
    func peerIsAmbiguous(_ peer: Peer) -> Bool { peer.isAmbiguous(among: peers, aliases: peerAliases, chinese: appLanguage() == "zh") }
    var sortedPeers: [Peer] {
        peers.sorted { lhs, rhs in
            let left = peerSubtitle(lhs) + peerTitle(lhs), right = peerSubtitle(rhs) + peerTitle(rhs)
            return left == right ? lhs.id < rhs.id : left.localizedStandardCompare(right) == .orderedAscending
        }
    }
    var maximumRecipientGridHeight: CGFloat {
        let visibleHeight = recipientPanel?.screen?.visibleFrame.height ?? NSScreen.main?.visibleFrame.height ?? 720
        return min(300, max(96, visibleHeight - 220))
    }
    func resizeRecipientPanel(to size: CGSize) {
        guard let panel = recipientPanel, panel.isVisible, size.width > 0, size.height > 0 else { return }
        let screen = panel.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? panel.frame
        let width = min(ceil(size.width), screen.width - 24)
        let height = min(ceil(size.height), screen.height - 24)
        guard abs(panel.frame.width - width) > 0.5 || abs(panel.frame.height - height) > 0.5 else { return }
        var origin = NSPoint(x: panel.frame.minX, y: panel.frame.maxY - height)
        origin.x = min(max(origin.x, screen.minX + 12), screen.maxX - width - 12)
        origin.y = min(max(origin.y, screen.minY + 12), screen.maxY - height - 12)
        panel.setFrame(NSRect(origin: origin, size: NSSize(width: width, height: height)), display: true)
    }
    func renamePeer(_ peer: Peer) {
        guard !busy else { return }
        renamingPeer = peer
    }
    func savePeerName(_ text: String, for peer: Peer) -> Bool {
        guard let name = Peer.normalizedAlias(text) else { return false }
        if name.isEmpty { peerAliases.removeValue(forKey: peer.aliasKey) }
        else { peerAliases[peer.aliasKey] = name }
        UserDefaults.standard.set(peerAliases, forKey: "peerAliases")
        renamingPeer = nil
        return true
    }
    private func stopCompletedRecipientDismissal() {
        for monitor in completedClickMonitors { NSEvent.removeMonitor(monitor) }
        completedClickMonitors.removeAll()
    }
    private func closeCompletedRecipients() {
        guard recipientPanel?.isVisible == true, outgoingTransfer?.state == "complete" else { return }
        closeRecipients()
    }
    private func updateCompletedRecipientDismissal() {
        stopCompletedRecipientDismissal()
        guard recipientPanel?.isVisible == true, outgoingTransfer?.state == "complete" else { return }
        let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: clicks, handler: { [weak self] event in
            MainActor.assumeIsolated {
                if let self, event.window !== self.recipientPanel { self.closeCompletedRecipients() }
            }
            return event
        }) { completedClickMonitors.append(monitor) }
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: clicks, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.closeCompletedRecipients() }
        }) { completedClickMonitors.append(monitor) }
    }
    func windowDidResignKey(_ notification: Notification) {
        if let resigned = notification.object as? NSWindow, resigned === recipientPanel { closeCompletedRecipients() }
    }
    func windowWillClose(_ notification: Notification) {
        if let closed = notification.object as? NSWindow, closed === recipientPanel {
            stopCompletedRecipientDismissal(); renamingPeer = nil
            clearPeers(); command(["command": "scan", "value": false])
            if outgoingTransfer?.active != true { outgoing = nil; selectedFiles = [] }
        }
    }
    private func clearPeers() {
        peers = []; selectedPeer = nil; lastPeerUpdate = nil
    }
    private func expirePeerUpdates() {
        if let lastPeerUpdate, lastPeerUpdate.duration(to: .now) >= .seconds(6) { clearPeers() }
    }
    private func startEngine() {
        clearPeers(); outputBuffer.removeAll()
        guard let resource = Bundle.main.resourceURL else { return }
        let executable = resource.appendingPathComponent("Engine/anDropEngine")
        let p = Process(); p.executableURL = executable
        let stdin = Pipe(); let stdout = Pipe(); let stderr = Pipe()
        p.standardInput = stdin; p.standardOutput = stdout; p.standardError = stderr
        input = stdin.fileHandleForWriting
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            Task { @MainActor [weak self] in self?.consume(data) }
        }
        // Keep protocol data off system logs; unexpected errors are surfaced by termination state.
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
        }
        p.terminationHandler = { [weak self] proc in
            let code = proc.terminationStatus
            Task { @MainActor [weak self] in
                guard let self, !self.terminating else { return }
                self.engineReady = false; self.clearPeers()
                for i in self.transfers.indices where self.transfers[i].active { self.transfers[i].state = "failed"; self.transfers[i].detail = L("The connection restarted. Please try again.", "连接已重新启动，请重试。") }
                self.error = L("Sharing service stopped (\(code))", "共享服务已停止（\(code)）")
                self.saveHistory()
                if self.restartCount < 2 { self.restartCount += 1; self.startEngine() }
            }
        }
        do { try p.run(); process = p; configureEngine() }
        catch { self.error = L("Could not start sharing: \(error.localizedDescription)", "无法启动共享：\(error.localizedDescription)") }
    }
    @discardableResult
    func command(_ value: [String: Any]) -> Bool {
        guard let input, let bytes = try? JSONSerialization.data(withJSONObject: value) else { return false }
        do { try input.write(contentsOf: bytes + Data([10])); return true }
        catch { self.error = L("Could not connect to the sharing service.", "无法连接到共享服务。"); return false }
    }
    func configureEngine() { configuredName = deviceName; command(["command": "configure", "destination": destination, "name": configuredName, "language": appLanguage()]); command(["command": "enabled", "value": receiving]) }
    private func consume(_ data: Data) {
        outputBuffer.append(data)
        if outputBuffer.count > 4_194_304 { outputBuffer.removeAll(); error = L("The sharing service returned an invalid response.", "共享服务返回了无效响应。"); return }
        while let end = outputBuffer.firstIndex(of: 10) {
            let line = outputBuffer[..<end]; outputBuffer.removeSubrange(...end)
            guard let value = try? JSONSerialization.jsonObject(with: line) as? [String: Any], let event = value["event"] as? String else { continue }
            if ["ready", "peers", "scan_status", "error", "transfer", "diagnostic"].contains(event) {
                let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("anDrop")
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                var summary: [String: Any] = ["event": event, "time": Date().ISO8601Format(), "bluetooth": bluetooth, "advertising": peripheral?.isAdvertising ?? false, "advertisedName": advertisedName, "error": error]
                if event == "peers" { summary["count"] = (value["peers"] as? [Any])?.count ?? 0 }
                else if event == "transfer" { summary["id"] = value["id"]; summary["state"] = value["state"]; summary["detail"] = value["detail"]; summary["completed"] = value["completed"]; summary["total"] = value["total"] }
                else { summary["detail"] = value["detail"]; for key in ["phase", "attempt", "error_type", "errno"] { summary[key] = value[key] } }
                if let data = try? JSONSerialization.data(withJSONObject: summary) {
                    let url = folder.appendingPathComponent("status.json")
                    try? data.write(to: url, options: .atomic)
                    if event == "transfer" { try? data.write(to: folder.appendingPathComponent("last-transfer.json"), options: .atomic) }
                    if event == "diagnostic" { try? data.write(to: folder.appendingPathComponent("last-protocol.json"), options: .atomic) }
                    try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                }
            }
            switch event {
            case "ready":
                engineReady = true; error = ""; advertise()
                if recipientPanel?.isVisible == true, outgoing == nil { command(["command": "scan", "value": true]) }
            case "ble_read":
                if let obj = value["value"] { readValue = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data() }
            case "ble_notify":
                if let encoded = value["data"] as? String, let bytes = Data(base64Encoded: encoded) { notifyQueue.append((bytes, value["central"] as? String)); flushNotifications() }
            case "peers":
                guard recipientPanel?.isVisible == true, receiving, engineReady else { clearPeers(); continue }
                lastPeerUpdate = .now
                peers = (value["peers"] as? [[String: String]] ?? []).compactMap { obj in
                    guard let id = obj["id"], let name = obj["name"] else { return nil }; return Peer(id: id, name: name, brand: obj["brand"] ?? "", kind: Peer.Kind(rawValue: obj["kind"] ?? "") ?? .unknown)
                }
                if !peers.contains(where: { $0.id == selectedPeer }) { selectedPeer = nil }
                if selectedPeer == nil, peers.count == 1 { selectedPeer = peers[0].id }
            case "transfer": updateTransfer(value)
            case "scan_status":
                clearPeers(); error = value["detail"] as? String ?? L("Check Bluetooth.", "请检查蓝牙。"); rebuildMenu()
            case "error": error = value["detail"] as? String ?? L("Something went wrong.", "发生错误。"); rebuildMenu()
            default: break
            }
        }
    }
    private func updateTransfer(_ obj: [String: Any]) {
        guard let id = obj["id"] as? String else { return }
        let index: Int
        if let found = transfers.firstIndex(where: { $0.id == id }) { index = found }
        else { transfers.insert(Transfer(id: id), at: 0); index = 0 }
        let previous = transfers[index].state
        if let v = obj["direction"] as? String { transfers[index].direction = v }
        if let v = obj["peer"] as? String { transfers[index].peer = v }
        if let v = obj["state"] as? String { transfers[index].state = v }
        if let v = obj["name"] as? String { transfers[index].name = v }
        if let v = obj["count"] as? Int { transfers[index].count = v }
        if let v = obj["total"] as? Int64 { transfers[index].total = v }
        if let v = obj["completed"] as? Int64 { transfers[index].completed = v }
        if let v = obj["detail"] as? String { transfers[index].detail = v }
        if let files = obj["files"] as? [[String: Any]] { transfers[index].paths = files.compactMap { $0["path"] as? String } }
        let t = transfers[index]
        if t.state != previous || t.state == "request" {
            if t.state == "request" {
                sendNotification(t, category: "receive", title: L("Files from \(t.peer)", "来自 \(t.peer) 的文件"), body: L("Accept \(fileCountLabel(t.count))?", "接收 \(t.count) 个文件？"))
                if !notificationsAllowed {
                    let alert = NSAlert(); alert.messageText = L("\(fileCountLabel(t.count)) from \(t.peer)", "来自 \(t.peer) 的 \(t.count) 个文件"); alert.informativeText = L("Save these files to your selected folder?", "将这些文件保存到所选文件夹？"); alert.addButton(withTitle: L("Accept", "接收")); alert.addButton(withTitle: L("Decline", "拒绝"))
                    NSApp.activate(ignoringOtherApps: true); decide(t, accept: alert.runModal() == .alertFirstButtonReturn)
                }
            } else if t.state == "complete" {
                UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [id])
                sendNotification(t, category: "complete", title: t.label, body: L("\(t.peer) · \(fileCountLabel(t.count))", "\(t.peer) · \(t.count) 个文件"))
                if t.direction == "send" { selectedFiles = [] }
            } else if t.state == "failed" {
                sendNotification(t, category: "manage", title: t.label, body: t.detail)
            } else if t.state == "transferring" {
                sendNotification(t, category: "manage", title: t.label, body: L("\(t.peer) · View progress in the menu bar", "\(t.peer) · 在菜单栏查看进度"))
            } else if !t.active { UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [id]) }
        }
        updateCompletedRecipientDismissal()
        if !t.active { saveHistory() }
        if let window { window.setContentSize(NSSize(width: 460, height: transfers.contains { $0.state == "request" } ? 585 : 510)) }
        rebuildMenu()
    }
    private func saveHistory() {
        let history = Array(transfers.filter { !$0.active }.prefix(100))
        if let data = try? JSONEncoder().encode(history) { UserDefaults.standard.set(data, forKey: "history") }
    }
    func clearHistory() { transfers.removeAll { !$0.active }; saveHistory() }
    func addFiles(_ urls: [URL]) {
        if outgoingTransfer?.active != true { outgoing = nil }
        selectedFiles = Array(Set(selectedFiles + urls.filter(\.isFileURL))).sorted { $0.lastPathComponent < $1.lastPathComponent }; tab = 0
    }
    func chooseFiles() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = true; panel.message = L("Choose files to send", "选择要发送的文件"); panel.prompt = L("Select", "选择")
        if panel.runModal() == .OK { addFiles(panel.urls) }
    }
    func chooseDestination() {
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.prompt = L("Use This Folder", "使用此文件夹"); panel.directoryURL = URL(fileURLWithPath: destination)
        if panel.runModal() == .OK, let url = panel.url { destination = url.path; UserDefaults.standard.set(url.path, forKey: "destination"); configureEngine() }
    }
    func send() {
        expirePeerUpdates()
        guard let selectedPeer, let peer = peers.first(where: { $0.id == selectedPeer }), !selectedFiles.isEmpty, !busy, receiving, engineReady else { return }
        var label = [peerTitle(peer), peer.deviceLabel(chinese: appLanguage() == "zh")].filter { !$0.isEmpty }.joined(separator: " · ")
        if peerIsAmbiguous(peer) { label += " · " + peer.distinguishingCode(among: peers) }
        let id = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        outgoing = OutgoingPresentation(id: id, peer: peer, files: selectedFiles)
        transfers.insert(Transfer(id: id, direction: "send", peer: label, state: "preparing", name: selectedFiles[0].lastPathComponent, count: selectedFiles.count), at: 0)
        error = ""
        if !command(["command": "send", "request_id": id, "peer": selectedPeer, "peer_label": label, "paths": selectedFiles.map(\.path)]) {
            updateTransfer(["id": id, "state": "failed", "detail": L("Could not connect to the sharing service.", "无法连接到共享服务。")])
        }
        command(["command": "scan", "value": false]); clearPeers(); updateCompletedRecipientDismissal()
    }
    func decide(_ transfer: Transfer, accept: Bool) {
        command(["command": "decision", "id": transfer.id, "accept": accept]); UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [transfer.id])
    }
    func cancel(_ transfer: Transfer) { command(["command": "cancel", "id": transfer.id]) }
    func reveal(_ transfer: Transfer) { NSWorkspace.shared.activateFileViewerSelecting(transfer.paths.map { URL(fileURLWithPath: $0) }) }
    func changeReceiving(_ value: Bool) { receiving = value; if !value { clearPeers() }; UserDefaults.standard.set(value, forKey: "enabled"); command(["command":"enabled", "value": value]); advertise(); rebuildMenu() }
    func changeLanguage(_ value: String) {
        language = value; UserDefaults.standard.set(value, forKey: "language"); configureEngine(); setupNotifications(); rebuildMenu()
        if let appMenu = NSApp.mainMenu?.items.first?.submenu {
            appMenu.items[0].title = L("About anDrop", "关于 anDrop")
            appMenu.items[1].title = L("Transfers", "传输")
            appMenu.items.last?.title = L("Quit anDrop", "退出 anDrop")
        }
        if let edit = NSApp.mainMenu?.items.last { edit.title = L("Edit", "编辑"); edit.submenu?.title = edit.title; edit.submenu?.items.first?.title = L("Copy", "拷贝"); edit.submenu?.items.last?.title = L("Paste", "粘贴") }
        window?.title = L("anDrop Settings", "anDrop 设置"); recipientPanel?.title = L("Choose a Recipient", "选择接收设备")
    }
    func changeLogin(_ value: Bool) {
        do { if value { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }; startAtLogin = value }
        catch { self.error = L("Could not change login settings: \(error.localizedDescription)", "无法更改登录设置：\(error.localizedDescription)") }
    }
    private func refreshEnvironment() {
        expirePeerUpdates()
        if configuredName != deviceName && !busy { configureEngine(); advertise() }
        let petal = NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == "com.EMUIInterconnect.app" }
        if petal != petalRunning {
            petalRunning = petal
            if !petalRepairing { compactName = petal; NSApp.setActivationPolicy(petal ? .regular : .accessory) }
            advertise()
        }
        flushNotifications(); rebuildMenu()
    }
    private func advertise() {
        guard serviceReady, engineReady else { return }
        guard receiving else { peripheral?.stopAdvertising(); advertisedName = ""; return }
        let name = discoveryID + "B" + displayName
        guard name != advertisedName || peripheral?.isAdvertising != true else { return }
        peripheral?.stopAdvertising(); advertisedName = name
        peripheral?.startAdvertising([CBAdvertisementDataLocalNameKey: name, CBAdvertisementDataServiceUUIDsKey: [CBUUID(string: "8881")]])
    }
    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        guard peripheral.state == .poweredOn else {
            bluetooth = peripheral.state == .unauthorized ? L("Allow Bluetooth access in System Settings.", "请在系统设置中允许使用蓝牙。") : L("Turn on Bluetooth.", "请打开蓝牙。")
            clearPeers(); serviceReady = false; advertisedName = ""; return
        }
        bluetooth = L("Ready to share with nearby Android devices", "可以与附近的安卓设备共享文件"); peripheral.removeAllServices(); chars.removeAll()
        let service = CBMutableService(type: CBUUID(string: "9999"), primary: true)
        for (uuid, properties): (String, CBCharacteristicProperties) in [("9898", [.read]), ("9896", [.write, .writeWithoutResponse]), ("9895", [.notify]), ("9984", [.notify]), ("9998", [.read])] {
            chars[uuid] = CBMutableCharacteristic(type: CBUUID(string: uuid), properties: properties, value: nil, permissions: [.readable, .writeable])
        }
        service.characteristics = Array(chars.values); peripheral.add(service)
    }
    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: (any Error)?) {
        guard error == nil else { self.error = L("Could not start Bluetooth receiving.", "无法启动蓝牙接收。"); return }; serviceReady = true; refreshEnvironment(); advertise()
    }
    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: (any Error)?) {
        if let error { self.error = L("Could not make this Mac discoverable: \(error.localizedDescription)", "无法让附近设备发现此 Mac：\(error.localizedDescription)") }
    }
    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
        let data = request.characteristic.uuid == CBUUID(string: "9898") ? readValue : Data()
        guard request.offset <= data.count else { peripheral.respond(to: request, withResult: .invalidOffset); return }
        request.value = data.subdata(in: request.offset..<data.count); peripheral.respond(to: request, withResult: .success)
    }
    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        for request in requests {
            let central = request.central.identifier.uuidString; centrals[central] = request.central
            let key = central + request.characteristic.uuid.uuidString
            if request.offset == 0 { writes[key] = Data() }
            guard var value = writes[key], request.offset == value.count, value.count + (request.value?.count ?? 0) <= 65536 else { continue }
            value.append(request.value ?? Data()); writes[key] = value
            if (try? JSONSerialization.jsonObject(with: value)) != nil {
                command(["command": "write", "uuid": request.characteristic.uuid.uuidString, "central": central, "data": value.base64EncodedString()]); writes[key] = nil
            }
        }
        if let request = requests.first { peripheral.respond(to: request, withResult: .success) }
    }
    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didSubscribeTo characteristic: CBCharacteristic) {
        centrals[central.identifier.uuidString] = central; command(["command": "subscribe", "central": central.identifier.uuidString, "uuid": characteristic.uuid.uuidString])
    }
    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didUnsubscribeFrom characteristic: CBCharacteristic) {
        centrals[central.identifier.uuidString] = nil
    }
    func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) { flushNotifications() }
    private func flushNotifications() {
        guard let char = chars["9895"], let peripheral else { return }
        while let first = notifyQueue.first {
            let target: [CBCentral]?
            if let id = first.1 { guard let central = centrals[id] else { notifyQueue.removeFirst(); continue }; target = [central] }
            else { target = nil }
            guard peripheral.updateValue(first.0, for: char, onSubscribedCentrals: target) else { return }; notifyQueue.removeFirst()
        }
    }
    private func setupNotifications() {
        let center = UNUserNotificationCenter.current(); center.delegate = self
        center.setNotificationCategories([
            UNNotificationCategory(identifier: "receive", actions: [UNNotificationAction(identifier: "accept", title: L("Accept", "接收")), UNNotificationAction(identifier: "decline", title: L("Decline", "拒绝"))], intentIdentifiers: []),
            UNNotificationCategory(identifier: "complete", actions: [UNNotificationAction(identifier: "reveal", title: L("Show in Finder", "在访达中显示"), options: [.foreground])], intentIdentifiers: []),
            UNNotificationCategory(identifier: "manage", actions: [UNNotificationAction(identifier: "manage", title: L("Show Transfers", "查看传输"), options: [.foreground]), UNNotificationAction(identifier: "cancel", title: L("Cancel", "取消"))], intentIdentifiers: [])
        ])
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] allowed, _ in Task { @MainActor [weak self] in self?.notificationsAllowed = allowed } }
    }
    private func sendNotification(_ transfer: Transfer, category: String, title: String, body: String) {
        let content = UNMutableNotificationContent(); content.title = title; content.body = body; content.categoryIdentifier = category; content.threadIdentifier = transfer.id
        if transfer.state != "transferring" { content.sound = .default }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: transfer.id, content: content, trigger: nil))
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) { completionHandler([.banner, .sound]) }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping @Sendable () -> Void) {
        let id = response.notification.request.identifier
        let action = response.actionIdentifier
        Task { @MainActor in
        if let t = self.transfers.first(where: { $0.id == id }) {
            switch action {
            case "accept": decide(t, accept: true)
            case "decline": decide(t, accept: false)
            case "cancel": cancel(t)
            case "reveal": if !t.paths.isEmpty { reveal(t) } else { showWindow() }
            default: tab = 0; showWindow()
            }
        }
        completionHandler()
        }
    }
}

private struct RecipientGridHeightKey: PreferenceKey {
    nonisolated static let defaultValue: CGFloat = 0
    nonisolated static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private struct RecipientPopupSizeKey: PreferenceKey {
    nonisolated static let defaultValue = CGSize.zero
    nonisolated static func reduce(value: inout CGSize, nextValue: () -> CGSize) { let next = nextValue(); value = CGSize(width: max(value.width, next.width), height: max(value.height, next.height)) }
}

struct RecipientView: View {
    @ObservedObject var model: AppModel
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top), count: 4)
    @State private var gridHeight: CGFloat = 124

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable().frame(width: 42, height: 42)
                VStack(alignment: .leading, spacing: 3) {
                    Text("anDrop").font(.system(size: 19, weight: .semibold))
                    Text(model.recipientFiles.count == 1 ? model.recipientFiles[0].lastPathComponent : L("\(model.recipientFiles.count) files", "\(model.recipientFiles.count) 个文件"))
                        .font(.subheadline).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 12)
                if let file = model.recipientFiles.first {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: file.path))
                        .resizable().scaledToFit().frame(width: 32, height: 40)
                        .accessibilityHidden(true)
                }
            }.padding(.bottom, 12)
            Divider()
            if model.visiblePeers.isEmpty {
                VStack(spacing: 12) {
                    ProgressView().controlSize(.small)
                    Text(L("Looking for devices…", "正在查找设备…")).font(.subheadline)
                    Text(L("Turn on 互传 and allow nearby devices to find you. Use the same Wi-Fi.", "请开启互传并允许附近设备发现，连接同一 Wi-Fi。"))
                        .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 270)
                }.frame(maxWidth: .infinity).frame(height: 128)
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                        ForEach(model.visiblePeers) { peer in
                            RecipientTile(model: model, peer: peer)
                        }
                    }.padding(.top, 12).padding(.bottom, 8)
                        .background(GeometryReader { geometry in
                            Color.clear.preference(key: RecipientGridHeightKey.self, value: geometry.size.height)
                        })
                }
                .scrollIndicators(.visible)
                .scrollBounceBehavior(.basedOnSize)
                .frame(height: min(gridHeight, model.maximumRecipientGridHeight))
                .clipped()
                .onPreferenceChange(RecipientGridHeightKey.self) { height in
                    if height > 0, abs(gridHeight - height) > 0.5 { gridHeight = height }
                }
            }
            Divider()
            HStack(alignment: .center, spacing: 16) {
                if let transfer = model.outgoingTransfer {
                    Text(transfer.state == "failed" ? transfer.detail : transfer.active
                         ? L("You can close this window. Sending continues.", "关闭窗口后仍会继续发送。")
                         : transfer.progress.label(chinese: appLanguage() == "zh"))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(3)
                    Spacer(minLength: 0)
                    if transfer.active {
                        Button(L("Cancel Transfer", "取消传输")) { model.cancel(transfer) }
                    }
                    Button(transfer.active ? L("Close", "关闭") : L("Done", "完成")) { model.closeRecipients() }
                        .keyboardShortcut(.cancelAction).controlSize(.large)
                } else {
                    Text(model.peers.contains(where: model.peerIsAmbiguous)
                         ? L("Same name? Make one device visible, then name it with the pencil.", "设备重名？请先只让一台可被发现，再点铅笔命名。")
                         : L("Choose a device to send.", "选择要发送到的设备。"))
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button(L("Cancel", "取消")) { model.closeRecipients() }
                        .keyboardShortcut(.cancelAction).controlSize(.large)
                }
            }.padding(.top, 12)
        }.padding(20).frame(width: 460)
            .fixedSize(horizontal: false, vertical: true)
            .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 18))
            .background(GeometryReader { geometry in
                Color.clear.preference(key: RecipientPopupSizeKey.self, value: geometry.size)
            })
            .onPreferenceChange(RecipientPopupSizeKey.self) { size in
                Task { @MainActor in model.resizeRecipientPanel(to: size) }
            }
            .sheet(item: $model.renamingPeer) { peer in RenamePeerView(model: model, peer: peer) }
    }
}

private struct RenamePeerView: View {
    @ObservedObject var model: AppModel
    let peer: Peer
    @State private var draft: String
    @State private var invalid = false
    @FocusState private var nameFocused: Bool

    init(model: AppModel, peer: Peer) {
        self.model = model; self.peer = peer
        _draft = State(initialValue: model.peerAliases[peer.aliasKey] ?? "")
    }
    private func save() {
        invalid = !model.savePeerName(draft, for: peer)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("Name on This Mac", "在此 Mac 上的名称")).font(.headline)
            Text(L("Up to 40 characters. Leave blank to use device details. Saved only on this Mac.", "最多 40 个字符。留空则使用设备信息。仅保存在此 Mac。"))
                .font(.callout).foregroundStyle(.secondary)
            TextField(peer.deviceLabel(chinese: appLanguage() == "zh"), text: $draft)
                .textFieldStyle(.roundedBorder).focused($nameFocused)
                .accessibilityLabel(L("Device name", "设备名称"))
                .onSubmit(save)
            if invalid {
                Text(L("Use up to 40 characters on one line.", "请使用不超过 40 个字符的单行名称。"))
                    .font(.caption).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button(L("Cancel", "取消")) { model.renamingPeer = nil }.keyboardShortcut(.cancelAction)
                Button(L("Save", "保存"), action: save).keyboardShortcut(.defaultAction)
            }
        }.padding(20).frame(width: 340)
            .task { nameFocused = true }
    }
}

private struct RecipientTile: View {
    @ObservedObject var model: AppModel
    let peer: Peer
    @State private var hovered = false
    private var transfer: Transfer? { model.outgoing?.peer.id == peer.id ? model.outgoingTransfer : nil }
    private var accessibleName: String {
        [model.peerTitle(peer), peer.deviceLabel(chinese: appLanguage() == "zh"), model.peerIsAmbiguous(peer) ? peer.distinguishingCode(among: model.peers) : ""]
            .filter { !$0.isEmpty }.joined(separator: ", ")
    }
    private var avatar: some View {
        RecipientAvatar(peer: peer)
            .background { if let transfer { RecipientProgressRing(progress: transfer.progress) } }
            .padding(6)
    }
    private var name: some View {
        Text(model.peerTitle(peer)).font(.system(size: 12, weight: .medium))
            .multilineTextAlignment(.center).lineLimit(2)
    }
    private func send() { model.selectedPeer = peer.id; model.send() }
    var body: some View {
        VStack(spacing: 6) {
            if let transfer {
                avatar.accessibilityHidden(true)
                name.accessibilityLabel(accessibleName)
                Text(transfer.progress.label(chinese: appLanguage() == "zh"))
                    .font(.system(size: 11)).monospacedDigit()
                    .foregroundStyle(transfer.state == "failed" ? Color.red : Color.blue)
                    .lineLimit(2).multilineTextAlignment(.center)
                    .accessibilityLabel(transfer.progress.label(chinese: appLanguage() == "zh"))
            } else {
                Button(action: send) { avatar }
                    .buttonStyle(.plain).disabled(model.busy || !model.receiving)
                    .accessibilityLabel(accessibleName)
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    // Balance the edit control so the name itself stays centered.
                    Color.clear.frame(width: 16, height: 16)
                        .alignmentGuide(.firstTextBaseline) { _ in 0 }
                        .accessibilityHidden(true)
                    Button(action: send) { name }
                        .buttonStyle(.plain).disabled(model.busy || !model.receiving)
                        .layoutPriority(1)
                        .accessibilityLabel(accessibleName)
                    Button { model.renamePeer(peer) } label: {
                        Image(systemName: "pencil")
                            .font(.system(size: 10, weight: .medium))
                            .frame(width: 16, height: 16)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).foregroundStyle(.secondary).opacity(hovered ? 1 : 0.65)
                    .help(L("Name on This Mac", "在此 Mac 上的名称"))
                    .accessibilityLabel(L("Name \(model.peerTitle(peer)) on this Mac", "为 \(model.peerTitle(peer)) 设置本机名称"))
                    .disabled(model.busy)
                }.fixedSize(horizontal: false, vertical: true)
            }
            if model.peerIsAmbiguous(peer) {
                Text(peer.distinguishingCode(among: model.peers)).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity).padding(.vertical, 4)
        .help([model.peerTitle(peer), model.peerSubtitle(peer)].filter { !$0.isEmpty }.joined(separator: " · "))
        .contextMenu { if transfer == nil { Button(L("Name on This Mac…", "设置本机名称…")) { model.renamePeer(peer) } } }
        .onHover { hovered = $0 }
    }
}

private struct RecipientProgressRing: View {
    let progress: TransferProgress
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if progress.showsRing {
            ZStack {
                Circle().stroke(Color.blue.opacity(0.15), lineWidth: 3)
                if progress.isIndeterminate {
                    TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { context in
                        Circle().trim(from: 0, to: 0.22)
                            .stroke(Color.blue, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                            .rotationEffect(.degrees(reduceMotion ? -90 : context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.4) / 1.4 * 360 - 90))
                    }
                } else {
                    Circle().trim(from: 0, to: progress.fraction ?? 0)
                        .stroke(Color.blue, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(reduceMotion ? nil : .linear(duration: 0.2), value: progress.fraction)
                }
            }.frame(width: 72, height: 72).allowsHitTesting(false).accessibilityHidden(true)
        }
    }
}

private struct RecipientAvatar: View {
    let peer: Peer
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Circle().fill(BrandLogos.image(for: peer.brand) == nil ? Color(nsColor: .quaternaryLabelColor) : .white)
            .overlay {
                if let logo = BrandLogos.image(for: peer.brand) {
                    Image(nsImage: logo).resizable().scaledToFit()
                        .frame(width: peer.brand == "Xiaomi" ? 44 : 50, height: 44)
                } else {
                    Image(systemName: "rectangle.on.rectangle").font(.system(size: 25)).foregroundStyle(.secondary)
                }
            }
            .frame(width: 62, height: 62)
            .overlay(Circle().strokeBorder(Color(nsColor: .separatorColor).opacity(0.35), lineWidth: 0.5))
            .overlay(alignment: .bottomTrailing) {
                Image(systemName: peer.symbol)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary)
                    .frame(width: 25, height: 25)
                    .background(colorScheme == .dark ? Color(white: 0.24) : .white, in: Circle())
                    .overlay(Circle().strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
                    .offset(x: 3, y: 3)
            }
            .accessibilityHidden(true)
    }
}

struct SettingsView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack { Text("anDrop").font(.title2.bold()); Spacer(); Toggle(L("On", "开启"), isOn: Binding(get: { model.receiving }, set: model.changeReceiving)).toggleStyle(.switch).fixedSize() }
            if let incoming = model.transfers.first(where: { $0.state == "request" }) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L("\(fileCountLabel(incoming.count)) from \(incoming.peer)", "来自 \(incoming.peer) 的 \(incoming.count) 个文件")).font(.headline)
                    HStack { Button(L("Accept", "接收")) { model.decide(incoming, accept: true) }; Button(L("Decline", "拒绝")) { model.decide(incoming, accept: false) } }
                }
            }
            VStack(alignment: .leading, spacing: 8) { Text(L("Save received files to", "接收文件保存位置")).font(.headline); HStack { Text(model.destination).font(.callout).lineLimit(1).truncationMode(.middle); Spacer(); Button(L("Change…", "更改…"), action: model.chooseDestination) }; Text(L("Each transfer needs your approval. Existing files are never overwritten.", "每次接收都需确认。同名文件不会被覆盖。")).font(.caption).foregroundStyle(.secondary) }
            Picker(L("Language", "语言"), selection: Binding(get: { model.language }, set: model.changeLanguage)) {
                Text(L("System Default", "跟随系统")).tag("system")
                Text("English").tag("en")
                Text("简体中文").tag("zh")
            }
            Divider()
            Toggle(L("Open at Login", "登录时启动"), isOn: Binding(get: { model.startAtLogin }, set: model.changeLogin))
            HStack { Text(model.notificationsAllowed ? L("Notifications: On", "通知：已开启") : L("Notifications: Off", "通知：已关闭")); Spacer(); Button(L("Notification Settings…", "通知设置…")) { if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") { NSWorkspace.shared.open(url) } } }
            VStack(alignment: .leading, spacing: 6) {
                Text(model.petalRunning ? L("With Petal · Nearby name “A”", "与 Petal 共存 · 附近设备名称“A”") : L("Discoverable as “\(model.displayName)”", "在设备上显示为“\(model.displayName)”"))
                Text(L("Nearby device names: up to 15 UTF-8 bytes (15 ASCII characters or typically 5 Chinese characters). Transfer confirmations use the full Mac name.", "附近设备名称上限：15 个 UTF-8 字节（15 个半角英数字符，或通常 5 个汉字）。传输确认使用完整电脑名称。"))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if model.petalRunning {
                    Text(L("Experimental: discovery may fail with Petal. Repair restarts Petal, but may not resolve every conflict. If it persists, quit Petal while receiving.", "实验性支持：与 Petal 同时运行时可能无法被发现。修复会重启 Petal，但不保证解决每次冲突。若仍无法发现，可在接收时退出 Petal。"))
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            if model.petalRunning { Button(model.petalRepairing ? L("Restarting Petal…", "正在重启 Petal…") : L("Repair Discovery with Petal", "修复与 Petal 的设备发现"), action: model.repairPetal).disabled(model.busy || model.petalRepairing) }
            HStack { Button(L("Clear Transfer History", "清除传输记录"), action: model.clearHistory); Spacer(); Text("0.1.1").font(.caption).foregroundStyle(.secondary) }
            Text(L("Mutual Transfer Alliance (互传联盟) · Same Wi-Fi required.", "互传联盟 · 需连接同一 Wi-Fi。")).font(.caption).foregroundStyle(.secondary)
        }.padding(24).frame(width: 460)
    }
}

let app = NSApplication.shared
let model = AppModel()
app.setActivationPolicy(NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == "com.EMUIInterconnect.app" } ? .regular : .accessory)
app.delegate = model
app.run()
