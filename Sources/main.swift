// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 anDrop contributors

import AppKit
import SwiftUI
import CoreBluetooth
import UserNotifications
import ServiceManagement
import CoreWLAN

var applicationVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0" }

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
    var deviceIdentifier: String?
    var transportIdentifier: String?
    var deviceKind: String?
    var deviceBrand: String?
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
        case "verifying": L("Verifying sender", "正在核对发送设备")
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

struct RememberedDevice: Codable, Identifiable {
    var id: String
    var name: String
    var kind: String?
    var brand: String?
    var peer: Peer { Peer(id: id, name: name, brand: brand ?? "", kind: Peer.Kind(rawValue: kind ?? "") ?? .unknown) }
}

@MainActor
final class RecipientPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class AppModel: NSObject, ObservableObject, NSApplicationDelegate, @preconcurrency CBPeripheralManagerDelegate, @preconcurrency UNUserNotificationCenterDelegate, NSSharingServiceDelegate, NSMenuDelegate, NSWindowDelegate {
    private lazy var huaweiLAN = HuaweiLANDiscovery(receive: { [weak self] host, port, local, data in
        self?.command(["command": "huawei_datagram", "host": host, "port": port, "local": local, "data": data.base64EncodedString()])
    }, report: { [weak self] phase, number in
        // Structured transport diagnostics only. No user-visible error is set,
        // so an unrelated transfer in progress is never interrupted.
        var entry: [String: Any] = ["event": "diagnostic", "detail": "huawei_transport_failed", "phase": phase]
        if let number { entry["error_type"] = "OSError"; entry["errno"] = number }
        self?.diagnostics.record(entry)
    })
    let updates = AppUpdates()
    private let diagnostics = DiagnosticsStore(folder: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("anDrop/Diagnostics"))
    @Published var showingDiagnostics = false
    @Published private(set) var diagnosticText = ""
    @Published private(set) var diagnosticFile: URL?
    @Published var diagnosticMessage = ""
    private var reportMailService: NSSharingService?

    @Published private(set) var forgottenDeviceIdentifiers = Set(UserDefaults.standard.stringArray(forKey: "forgottenDeviceIdentifiers") ?? [])
    @Published private(set) var trustedOnly = UserDefaults.standard.bool(forKey: "trustedOnly")
    @Published private(set) var autoAcceptTrusted = UserDefaults.standard.object(forKey: "autoAcceptTrusted") as? Bool ?? true
    @Published private(set) var trustedDevices: [RememberedDevice] = {
        guard let data = UserDefaults.standard.data(forKey: "trustedDevices") else { return [] }
        return (try? JSONDecoder().decode([RememberedDevice].self, from: data)) ?? []
    }()
    @Published private(set) var rememberedDevices: [RememberedDevice] = {
        guard let data = UserDefaults.standard.data(forKey: "rememberedDevices") else { return [] }
        return (try? JSONDecoder().decode([RememberedDevice].self, from: data)) ?? []
    }()
    @Published private(set) var customSharingName = UserDefaults.standard.string(forKey: "customSharingName") ?? ""
    @Published var language = UserDefaults.standard.string(forKey: "language") ?? "zh"
    @Published var peers: [Peer] = []
    @Published private(set) var peerAliases = UserDefaults.standard.dictionary(forKey: "peerAliases") as? [String: String] ?? [:]
    @Published private(set) var hiddenDevices: HiddenDevices = {
        guard let data = UserDefaults.standard.data(forKey: "hiddenRecipients") else { return HiddenDevices() }
        return (try? JSONDecoder().decode(HiddenDevices.self, from: data)) ?? HiddenDevices()
    }()
    @Published var transfers: [Transfer] = []
    @Published var outgoing: [OutgoingPresentation] = []
    @Published private(set) var pendingRetryIDs: Set<String> = []
    private var retryTimeouts: [String: Task<Void, Never>] = [:]
    var outgoingCanRetry: Bool { outgoingTransfers.contains { canRetry($0) } }
    @Published var renamingPeer: Peer?
    var outgoingTransfers: [Transfer] { outgoing.compactMap { item in transfers.first { $0.id == item.id } } }
    var outgoingActive: Bool { outgoingTransfers.contains(where: \.active) }
    var outgoingComplete: Bool { !outgoing.isEmpty && outgoingTransfers.count == outgoing.count && outgoingTransfers.allSatisfy { $0.state == "complete" } }
    func canRetry(_ transfer: Transfer) -> Bool { ["failed", "declined"].contains(transfer.state) }
    func outgoingTransfer(for peer: Peer) -> Transfer? { outgoing.first { $0.peer.id == peer.id }.flatMap { item in transfers.first { $0.id == item.id } } }
    var recipientFiles: [URL] { outgoing.first?.files ?? selectedFiles }
    // Keep discoverable recipients clickable and retain every started transfer.
    var visiblePeers: [Peer] {
        let candidates = candidatePeers
        let visibleIDs = Set(candidates.map(\.id))
        return candidates + outgoing.map(\.peer).filter { !visibleIDs.contains($0.id) }
    }
    @Published var selectedFiles: [URL] = []
    func canSend(to peer: Peer) -> Bool {
        receiving && engineReady && !recipientFiles.isEmpty
            && !transfers.contains { $0.direction == "receive" && $0.active }
            && !outgoing.contains { $0.peer.id == peer.id }
            && candidatePeers.contains { $0.id == peer.id }
    }
    @Published var tab = 0
    @Published var bluetooth = L("Preparing Bluetooth", "正在准备蓝牙")
    @Published var error = ""
    @Published var petalRunning = false
    @Published var petalRepairing = false
    private var petalRecommendationPending = false
    private var petalRecommendationAlert: NSAlert?
    private var petalIsRunning: Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == "com.EMUIInterconnect.app" }
    }
    private var compactName = false
    let receiving = true
    @Published private(set) var radiosAvailable = true
    var receiveSwitchIsOn: Bool { receiving && radiosAvailable }
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
    private var notificationCleanupTimer: Timer?
    private var serviceReady = false
    private var terminating = false
    private var restartCount = 0
    private var discoveryID = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(6))
    private var advertisedName = ""
    private var configuredName = ""
    var deviceName: String { Host.current().localizedName ?? ProcessInfo.processInfo.hostName }
    var sharingName: String { customSharingName.isEmpty ? deviceName : customSharingName }
    var displayName: String {
        if compactName { return "A" }
        // Keep the protocol prefix and name inside a legacy BLE advertisement.
        var name = ""
        for character in sharingName {
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
        removeLegacyHistoryOnce()
        setupMenus()
        setupNotifications()
        clearExpiredTransferNotifications()
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep], reason: L("Receive files from nearby devices", "接收附近设备的文件"))
        startAtLogin = SMAppService.mainApp.status == .enabled
        startEngine()
        peripheral = CBPeripheralManager(delegate: self, queue: nil)
        refreshEnvironment()
        updates.start(hasActiveTransfers: { [weak self] in self?.busy ?? false })
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshEnvironment() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(woke), name: NSWorkspace.didWakeNotification, object: nil)
        if Bundle.main.object(forInfoDictionaryKey: "anDropShowSettingsOnLaunch") as? Bool == true { showSettings() }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showSettings(); return false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply { updates.installing && busy ? .terminateCancel : .terminateNow }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) {
        dismissPetalRecommendation()
        stopCompletedRecipientDismissal()
        cancelOutgoingRetry()
        notificationCleanupTimer?.invalidate()
        terminating = true; huaweiLAN.stop(); peripheral?.stopAdvertising(); input?.closeFile(); process?.terminate(); saveHistory()
    }
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            if url.isFileURL { addFiles([url]) }
            else if url.scheme == "androp", url.host == "control" {
                // Legacy control URLs now open the ordinary settings window.
                showSettings()
                return
            }
            else if url.scheme == "androp", let parts = URLComponents(url: url, resolvingAgainstBaseURL: false), parts.host == "share" {
                guard parts.queryItems?.allSatisfy({ $0.name == "file" }) == true else {
                    error = L("URL and text sharing are not supported. Choose files to send.", "不支持 URL 或文本共享，请选择文件发送。"); showWindow(); return
                }
                let paths = parts.queryItems?.filter { $0.name == "file" }.compactMap(\.value) ?? []
                addFiles(paths.filter { $0.hasPrefix("/") }.map { URL(fileURLWithPath: $0) })
            }
        }
        if !selectedFiles.isEmpty { showRecipients() }
    }
    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        addFiles(filenames.map { URL(fileURLWithPath: $0) }); showRecipients(); sender.reply(toOpenOrPrint: .success)
    }
    @objc func woke() { clearExpiredTransferNotifications(); clearPeers(); refreshEnvironment(); advertise() }
    private func setupMenus() {
        let menu = NSMenu(); let appItem = NSMenuItem(); menu.addItem(appItem)
        let appMenu = NSMenu(); appItem.submenu = appMenu
        appMenu.addItem(withTitle: L("About anDrop", "关于 anDrop"), action: #selector(about), keyEquivalent: "")
        appMenu.addItem(withTitle: L("Transfers", "传输"), action: #selector(showWindow), keyEquivalent: "")
        if updates.isAvailable { appMenu.addItem(withTitle: L("Check for Updates…", "检查更新…"), action: #selector(checkForUpdates), keyEquivalent: "") }
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L("Quit anDrop", "退出 anDrop"), action: #selector(quit), keyEquivalent: "q")
        for entry in appMenu.items where entry.action != nil { entry.target = self }
        let editItem = NSMenuItem(); menu.addItem(editItem); let editMenu = NSMenu(title: L("Edit", "编辑")); editItem.submenu = editMenu
        editMenu.addItem(withTitle: L("Copy", "拷贝"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: L("Paste", "粘贴"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        NSApp.mainMenu = menu
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item?.button?.image = NSImage(systemSymbolName: "paperplane", accessibilityDescription: "anDrop")
        item?.button?.image?.isTemplate = true
        item?.button?.toolTip = L("anDrop — Share with Android", "anDrop — 与安卓设备共享文件")
        let statusMenu = NSMenu(); statusMenu.autoenablesItems = false; statusMenu.delegate = self; item?.menu = statusMenu
        rebuildMenu()
    }
    @objc func checkForUpdates() { updates.checkForUpdates() }
    @objc func about() {
        let alert = NSAlert()
        alert.messageText = "anDrop \(applicationVersion)"
        alert.informativeText = L("File sharing for the Mutual Transfer Alliance (互传联盟) ecosystem.\nNo prior connection. Use the same Wi-Fi.\n\n© 2026 anDrop contributors\nGPL-3.0-only · No warranty.\nRedistribution is permitted under the license.", "面向互传联盟生态的文件共享。\n无需预先连接，请使用同一 Wi-Fi。\n\n© 2026 anDrop contributors\nGPL-3.0-only · 不提供担保。\n可按许可证条款再分发。")
        alert.addButton(withTitle: L("Close", "关闭"))
        alert.addButton(withTitle: L("Licenses…", "许可证…"))
        if alert.runModal() == .alertSecondButtonReturn, let resources = Bundle.main.resourceURL {
            NSWorkspace.shared.activateFileViewerSelecting([resources.appendingPathComponent("LICENSE"), resources.appendingPathComponent("NOTICE.md"), resources.appendingPathComponent("ThirdPartyNotices")])
        }
    }
    @objc func quit() { NSApp.terminate(nil) }
    @objc func selectTrustedOnly() { changeTrustedOnly(true) }
    @objc func selectEveryone() { changeTrustedOnly(false) }
    func changeTrustedOnly(_ value: Bool) {
        trustedOnly = value; UserDefaults.standard.set(value, forKey: "trustedOnly"); configureEngine(); rebuildMenu()
    }
    func changeAutoAcceptTrusted(_ value: Bool) {
        autoAcceptTrusted = value; UserDefaults.standard.set(value, forKey: "autoAcceptTrusted"); configureEngine()
    }
    var knownDevices: [RememberedDevice] {
        var seen = Set<String>()
        let history = transfers.compactMap { transfer -> RememberedDevice? in
            guard transfer.direction == "receive", transfer.state == "complete", let id = transfer.deviceIdentifier, ReceiveAccessPolicy.persistentID(id) else { return nil }
            return RememberedDevice(id: id, name: transfer.peer, kind: transfer.deviceKind, brand: transfer.deviceBrand)
        }
        return (rememberedDevices + history).filter { ReceiveAccessPolicy.persistentID($0.id) && !forgottenDeviceIdentifiers.contains($0.id) && seen.insert($0.id).inserted }.map { device in
            var result = device
            let detailed = history.first { $0.id == device.id && $0.kind != nil }
            result.kind = result.kind ?? detailed?.kind
            result.brand = result.brand ?? detailed?.brand
            return result
        }
    }
    func setTrusted(_ device: RememberedDevice, trusted: Bool) {
        if trusted {
            guard knownDevices.contains(where: { $0.id == device.id }) else { return }
            if !trustedDevices.contains(where: { $0.id == device.id }) { trustedDevices.append(device) }
        } else { trustedDevices.removeAll { $0.id == device.id } }
        if let data = try? JSONEncoder().encode(trustedDevices) { UserDefaults.standard.set(data, forKey: "trustedDevices") }
        configureEngine()
    }
    func forgetDevice(_ device: RememberedDevice) {
        setTrusted(device, trusted: false)
        rememberedDevices.removeAll { $0.id == device.id }
        forgottenDeviceIdentifiers.insert(device.id)
        UserDefaults.standard.set(Array(forgottenDeviceIdentifiers), forKey: "forgottenDeviceIdentifiers")
        if let data = try? JSONEncoder().encode(rememberedDevices) { UserDefaults.standard.set(data, forKey: "rememberedDevices") }
    }
    @objc func pickAndSend() { chooseFiles(); if !selectedFiles.isEmpty { showRecipients() } }
    @objc func showSendProgress() { showRecipients() }
    @objc func cancelMenu(_ sender: NSMenuItem) { if let id = sender.representedObject as? String, let t = transfers.first(where: { $0.id == id }) { cancel(t) } }
    @objc func diagnosticsMenu(_ sender: NSMenuItem) { showDiagnostics(for: sender.representedObject as? String) }
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
        add(L("Trusted Devices Only", "仅限受信任的设备"), #selector(selectTrustedOnly)); menu.items.last?.state = trustedOnly ? .on : .off
        add(L("Everyone", "所有人"), #selector(selectEveryone)); menu.items.last?.state = trustedOnly ? .off : .on
        add(receiving ? L("Discoverable as: \(displayName)", "显示名称：\(displayName)") : L("Sharing is off", "文件共享已关闭"))
        if petalRunning { add(L("Petal coexistence · Experimental", "与鸿蒙星河互联同时运行 · 实验性支持")); add(L("Repair Discovery with Petal…", "修复与鸿蒙星河互联的发现冲突…"), #selector(repairPetal)); menu.items.last?.isEnabled = !busy && !petalRepairing }
        menu.addItem(.separator()); add(L("Send Files…", "发送文件…"), #selector(pickAndSend)); menu.items.last?.isEnabled = receiving && !busy
        for t in transfers.filter(\.active) {
            menu.addItem(.separator())
            let progress = t.state == "transferring" ? t.progress.percent.map { " \($0)%" } ?? "" : ""
            add("\(t.peer) — \(t.label)\(progress)")
            if t.direction == "send", outgoing.contains(where: { $0.id == t.id }) { add(L("Show Progress…", "查看进度…"), #selector(showSendProgress)) }
            if t.state == "request" { add(L("Accept \(fileCountLabel(t.count))", "接收 \(t.count) 个文件"), #selector(acceptMenu(_:)), id: t.id); add(L("Decline", "拒绝"), #selector(declineMenu(_:)), id: t.id) }
            else { add(L("Cancel This Transfer", "取消此次传输"), #selector(cancelMenu(_:)), id: t.id) }
        }
        let recent = transfers.filter { !$0.active }.prefix(8)
        if !recent.isEmpty {
            menu.addItem(.separator())
            let row = NSMenuItem(title: L("Recent Transfers", "最近传输"), action: nil, keyEquivalent: ""); let submenu = NSMenu(); row.submenu = submenu
            for t in recent {
                let label = "\(t.historyName) — \(t.label)"
                let entry = NSMenuItem(title: label, action: t.state == "failed" ? #selector(diagnosticsMenu(_:)) : (t.paths.isEmpty ? nil : #selector(revealMenu(_:))), keyEquivalent: ""); entry.target = self; entry.representedObject = t.id
                entry.image = NSImage(systemSymbolName: t.historySymbol, accessibilityDescription: t.direction == "send" ? L("Sent", "已发送") : L("Received", "已接收"))
                entry.image?.size = NSSize(width: 18, height: 18)
                submenu.addItem(entry)
            }
            menu.addItem(row)
        }
        if !error.isEmpty { menu.addItem(.separator()); add(String(error.prefix(100))) }
        menu.addItem(.separator()); add(L("Settings…", "设置…"), #selector(showSettings))
        if updates.isAvailable {
            add(L("Check for Updates…", "检查更新…"), #selector(checkForUpdates))
            menu.items.last?.isEnabled = !busy && (updates.canCheck || updates.readyVersion != nil)
        }
        add(L("Quit anDrop", "退出 anDrop"), #selector(quit))
    }
    @objc func repairPetal() {
        guard !petalRepairing, !busy, let petal = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "com.EMUIInterconnect.app" }), let url = petal.bundleURL else { return }
        petalRepairing = true; compactName = true; peripheral?.stopAdvertising(); advertisedName = ""
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        guard petal.terminate() else { petalRepairing = false; advertise(); error = L("Please quit and reopen Petal to restore discovery.", "请退出并重新打开鸿蒙星河互联，以恢复设备发现。"); return }
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
                catch { self.error = L("Please reopen Petal Interconnect.", "请重新打开鸿蒙星河互联。") }
            } else { error = L("Petal is still open. Finish any transfer, then try again.", "鸿蒙星河互联仍在运行。请完成传输后重试。") }
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
    private func refreshRadioAvailability() {
        let available = peripheral?.state == .poweredOn && (CWWiFiClient.shared().interface()?.powerOn() ?? false)
        if radiosAvailable != available {
            radiosAvailable = available
            configureEngine(); advertise()
            if !available { clearPeers() }
        }
    }
    @objc func showSettings() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: min(640, (NSScreen.main?.visibleFrame.height ?? 740) - 100)), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = L("anDrop Settings", "anDrop 设置"); w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: SettingsView(model: self)); w.center(); window = w
        }
        window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    func closeRecipients() { recipientPanel?.close() }
    func cancelOrCloseRecipients() {
        let wasRetrying = !pendingRetryIDs.isEmpty
        cancelOutgoingRetry()
        let active = outgoingTransfers.filter(\.active)
        for transfer in active { cancel(transfer) }
        if active.isEmpty && !wasRetrying { closeRecipients() }
    }
    func showRecipients() {
        if recipientPanel?.isVisible != true { clearPeers() }
        command(["command": "scan", "value": true])
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
    func peerIsAmbiguous(_ peer: Peer) -> Bool { peer.isAmbiguous(among: candidatePeers, aliases: peerAliases, chinese: appLanguage() == "zh") }
    // Hidden devices are filtered out of sending only; receiving is unaffected.
    var candidatePeers: [Peer] { hiddenDevices.visible(sortedPeers) }
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
    func hidePeer(_ peer: Peer) {
        guard !busy else { return }
        hiddenDevices.hide(peer)
        saveHiddenDevices()
        if renamingPeer?.id == peer.id { renamingPeer = nil }
    }
    func showHiddenDevice(_ device: HiddenDevice) {
        guard !busy else { return }
        hiddenDevices.show(device)
        saveHiddenDevices()
    }
    private func saveHiddenDevices() {
        if let data = try? JSONEncoder().encode(hiddenDevices) { UserDefaults.standard.set(data, forKey: "hiddenRecipients") }
    }
    private func stopCompletedRecipientDismissal() {
        for monitor in completedClickMonitors { NSEvent.removeMonitor(monitor) }
        completedClickMonitors.removeAll()
    }
    private func closeCompletedRecipients() {
        guard recipientPanel?.isVisible == true, outgoingComplete else { return }
        closeRecipients()
    }
    private func updateCompletedRecipientDismissal() {
        stopCompletedRecipientDismissal()
        guard recipientPanel?.isVisible == true, outgoingComplete else { return }
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
        if let closed = notification.object as? NSWindow, closed === petalRecommendationAlert?.window {
            dismissPetalRecommendation()
        }
        if let closed = notification.object as? NSWindow, closed === recipientPanel {
            stopCompletedRecipientDismissal(); cancelOutgoingRetry(); renamingPeer = nil
            clearPeers(); command(["command": "scan", "value": false])
            if !outgoingActive { outgoing = []; selectedFiles = [] }
        }
    }
    private func clearPeers() {
        peers = []; lastPeerUpdate = nil
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
                for transfer in self.transfers.filter(\.active) {
                    self.diagnostics.record(["event": "diagnostic", "transfer_id": transfer.id, "detail": "engine_stopped", "errno": Int(code)])
                    self.updateTransfer(["id": transfer.id, "state": "failed", "detail": L("The connection restarted. Please try again.", "连接已重新启动，请重试。")])
                }
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
    func configureEngine() { configuredName = sharingName; command(["command": "configure", "destination": destination, "name": configuredName, "language": appLanguage(), "trusted_only": trustedOnly, "auto_accept_trusted": autoAcceptTrusted, "trusted_ids": trustedDevices.map(\.id), "huawei_enabled": receiving]); command(["command": "enabled", "value": receiveSwitchIsOn]) }
    private func consume(_ data: Data) {
        outputBuffer.append(data)
        if outputBuffer.count > 4_194_304 { outputBuffer.removeAll(); error = L("The sharing service returned an invalid response.", "共享服务返回了无效响应。"); return }
        while let end = outputBuffer.firstIndex(of: 10) {
            let line = outputBuffer[..<end]; outputBuffer.removeSubrange(...end)
            guard let value = try? JSONSerialization.jsonObject(with: line) as? [String: Any], let event = value["event"] as? String else { continue }
            diagnostics.record(value)
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
                if recipientPanel?.isVisible == true { command(["command": "scan", "value": true]) }
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
                attemptOutgoingRetry()
            case "transfer": updateTransfer(value)
            case "huawei_discovery":
                if value["enabled"] as? Bool == true { huaweiLAN.start() } else { huaweiLAN.stop() }
            case "huawei_datagram":
                if let host = value["host"] as? String, let data = value["data"] as? String { huaweiLAN.send(host: host, encoded: data) }
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
        if let identifier = obj["device_identifier"] as? String {
            if ReceiveAccessPolicy.persistentID(identifier) { transfers[index].deviceIdentifier = identifier }
            else if let uuid = UUID(uuidString: identifier) { transfers[index].deviceIdentifier = uuid.uuidString }
        }
        if let identifier = obj["transport_identifier"] as? String, let uuid = UUID(uuidString: identifier) { transfers[index].transportIdentifier = uuid.uuidString }
        if let v = obj["device_kind"] as? String { transfers[index].deviceKind = v }
        if let v = obj["device_brand"] as? String { transfers[index].deviceBrand = v }
        let t = transfers[index]
        // UI-generated failures (including engine restarts) follow the same log path.
        diagnostics.record(["event": "transfer", "id": t.id, "direction": t.direction, "state": t.state])
        let filenames: [String]
        if t.direction == "send", let item = outgoing.first(where: { $0.id == t.id }) { filenames = item.files.map(\.lastPathComponent) }
        else if !t.paths.isEmpty { filenames = t.paths.map { URL(fileURLWithPath: $0).lastPathComponent } }
        else { filenames = [t.name].filter { ![L("Files", "文件"), "Files", "文件"].contains($0) } }
        let apps = diagnostics.needsAppSnapshot(id: t.id, state: t.state) ? NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy != .prohibited }
            .map { DiagnosticsStore.RunningApp(name: $0.localizedName ?? "Unknown", bundleID: $0.bundleIdentifier) }
            .sorted { ($0.bundleID ?? $0.name) < ($1.bundleID ?? $1.name) } : []
        diagnostics.recordContext(id: t.id, direction: t.direction, state: t.state, filenames: filenames, count: t.count,
            allTypesKnown: !filenames.isEmpty && (t.count == 1 || filenames.count == t.count), brand: t.deviceBrand, kind: t.deviceKind, apps: apps)
        if t.direction == "receive", t.state == "complete", let identifier = t.deviceIdentifier, ReceiveAccessPolicy.persistentID(identifier) {
            forgottenDeviceIdentifiers.remove(identifier)
            UserDefaults.standard.set(Array(forgottenDeviceIdentifiers), forKey: "forgottenDeviceIdentifiers")
            rememberedDevices.removeAll { $0.id == identifier }
            rememberedDevices.insert(RememberedDevice(id: identifier, name: t.peer, kind: t.deviceKind, brand: t.deviceBrand), at: 0)
            rememberedDevices = Array(rememberedDevices.prefix(50))
            if let trusted = trustedDevices.firstIndex(where: { $0.id == identifier }) {
                trustedDevices[trusted].kind = t.deviceKind ?? trustedDevices[trusted].kind
                trustedDevices[trusted].brand = t.deviceBrand ?? trustedDevices[trusted].brand
                if let data = try? JSONEncoder().encode(trustedDevices) { UserDefaults.standard.set(data, forKey: "trustedDevices") }
            }
            if let data = try? JSONEncoder().encode(rememberedDevices) { UserDefaults.standard.set(data, forKey: "rememberedDevices") }
        }
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
            } else if t.state == "failed" {
                sendNotification(t, category: "failed", title: t.label, body: t.detail)
                recommendQuittingPetal()
            } else if t.state == "transferring" {
                sendNotification(t, category: "manage", title: t.label, body: L("\(t.peer) · View progress in the menu bar", "\(t.peer) · 在菜单栏查看进度"))
            } else if !t.active { UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [id]) }
        }
        updateCompletedRecipientDismissal()
        if outgoing.contains(where: { $0.id == t.id }), outgoingCanRetry, recipientPanel?.isVisible == true {
            command(["command": "scan", "value": true])
        }
        if !t.active { saveHistory() }
        updates.transferStateDidChange()
        rebuildMenu()
    }
    private func recommendQuittingPetal() {
        guard !petalRecommendationPending, petalIsRunning else { return }
        petalRecommendationPending = true
        // Finish processing this event before presenting the alert. One
        // pending alert also covers failures from other concurrent recipients.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard !self.terminating, self.petalIsRunning else {
                self.petalRecommendationPending = false
                return
            }
            let alert = NSAlert()
            alert.messageText = L("Try quitting Petal Interconnect", "建议退出鸿蒙星河互联")
            alert.informativeText = L(
                "Petal Interconnect is running and may interfere with discovery or file transfers. anDrop can send and receive Huawei Share files on its own. Finish any transfers in Petal, quit it, then try again in anDrop.",
                "检测到鸿蒙星河互联正在运行，可能影响设备发现或文件传输。anDrop 已可独立通过华为分享收发文件。建议先完成鸿蒙星河互联中的传输，退出该应用后，再在 anDrop 中重试。")
            let button = alert.addButton(withTitle: L("OK", "知道了"))
            button.target = self
            button.action = #selector(self.dismissPetalRecommendation)
            self.petalRecommendationAlert = alert
            alert.window.delegate = self
            alert.layout()
            alert.window.center()
            // A standalone, nonmodal alert keeps other transfers and approval
            // windows usable while the recommendation is visible.
            NSApp.activate(ignoringOtherApps: true)
            alert.window.makeKeyAndOrderFront(nil)
        }
    }
    @objc private func dismissPetalRecommendation() {
        petalRecommendationAlert?.window.orderOut(nil)
        petalRecommendationAlert = nil
        petalRecommendationPending = false
    }
    func removeLegacyHistoryOnce() {
        guard !UserDefaults.standard.bool(forKey: "endpointHistoryMigrationComplete") else { return }
        transfers.removeAll { $0.deviceIdentifier == nil }
        saveHistory()
        UserDefaults.standard.set(true, forKey: "endpointHistoryMigrationComplete")
    }
    private func saveHistory() {
        let history = Array(transfers.filter { !$0.active }.prefix(100))
        if let data = try? JSONEncoder().encode(history) { UserDefaults.standard.set(data, forKey: "history") }
    }
    func clearHistory() { transfers.removeAll { !$0.active }; saveHistory() }
    func addFiles(_ urls: [URL]) {
        cancelOutgoingRetry()
        if !outgoingActive { outgoing = [] }
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
    func send(to requestedPeer: Peer) {
        expirePeerUpdates()
        guard canSend(to: requestedPeer),
              let peer = candidatePeers.first(where: { $0.id == requestedPeer.id }) else { return }
        let files = recipientFiles
        // The first click owns the batch. Later clicks send that same batch,
        // even if Finder has queued different files in the meantime.
        if outgoing.isEmpty { selectedFiles = [] }
        beginSend(to: peer, files: files)
        updateCompletedRecipientDismissal()
    }
    private func beginSend(to peer: Peer, files: [URL], replacing previousID: String? = nil) {
        var label = [peerTitle(peer), peer.deviceLabel(chinese: appLanguage() == "zh")].filter { !$0.isEmpty }.joined(separator: " · ")
        if peerIsAmbiguous(peer) { label += " · " + peer.distinguishingCode(among: peers) }
        let id = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let item = OutgoingPresentation(id: id, peer: peer, files: files)
        if let previousID, let index = outgoing.firstIndex(where: { $0.id == previousID }) { outgoing[index] = item }
        else { outgoing.append(item) }
        transfers.insert(Transfer(id: id, direction: "send", peer: label, state: "preparing", name: files[0].lastPathComponent, count: files.count, deviceKind: peer.kind.rawValue, deviceBrand: peer.brand), at: 0)
        error = ""
        if !command(["command": "send", "request_id": id, "peer": peer.id, "peer_label": label, "paths": files.map(\.path)]) {
            updateTransfer(["id": id, "state": "failed", "detail": L("Could not connect to the sharing service.", "无法连接到共享服务。")])
        }
    }
    private func cancelOutgoingRetry(_ id: String? = nil) {
        let ids = id.map { [$0] } ?? Array(pendingRetryIDs)
        for id in ids {
            retryTimeouts.removeValue(forKey: id)?.cancel()
            pendingRetryIDs.remove(id)
        }
    }
    func retryOutgoing(_ id: String) {
        guard let item = outgoing.first(where: { $0.id == id }),
              let transfer = transfers.first(where: { $0.id == id }), canRetry(transfer),
              !transfers.contains(where: { $0.direction == "receive" && $0.active }),
              receiving, engineReady, !pendingRetryIDs.contains(id) else { return }
        pendingRetryIDs.insert(id)
        clearPeers()
        command(["command": "scan", "value": true])
        retryTimeouts[id] = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(15)) } catch { return }
            guard let self, pendingRetryIDs.contains(item.id) else { return }
            cancelOutgoingRetry(item.id)
            updateTransfer(["id": item.id, "detail": L("Could not find this device. Enable sharing on it, then click to retry.", "未找到此设备。请在对方设备上开启共享，然后点击重试。")])
        }
        attemptOutgoingRetry()
    }
    private func attemptOutgoingRetry() {
        guard receiving, engineReady else { return }
        expirePeerUpdates()
        for item in outgoing where pendingRetryIDs.contains(item.id) {
            guard let transfer = transfers.first(where: { $0.id == item.id }), canRetry(transfer),
                  let peer = candidatePeers.first(where: { $0.id == item.peer.id }) else { continue }
            cancelOutgoingRetry(item.id)
            beginSend(to: peer, files: item.files, replacing: item.id)
        }
        updateCompletedRecipientDismissal()
    }
    func decide(_ transfer: Transfer, accept: Bool) {
        command(["command": "decision", "id": transfer.id, "accept": accept]); UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [transfer.id])
    }
    func cancel(_ transfer: Transfer) { command(["command": "cancel", "id": transfer.id]) }
    func reveal(_ transfer: Transfer) { NSWorkspace.shared.activateFileViewerSelecting(transfer.paths.map { URL(fileURLWithPath: $0) }) }
    @discardableResult
    func changeSharingName(_ value: String) -> Bool {
        let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !busy, name.utf8.count <= 15, !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return false }
        customSharingName = name
        UserDefaults.standard.set(name, forKey: "customSharingName")
        configureEngine(); advertise(); rebuildMenu()
        return true
    }
    func changeLanguage(_ value: String) {
        language = value; UserDefaults.standard.set(value, forKey: "language"); configureBundleLanguage(); configureEngine(); setupNotifications(); rebuildMenu()
        if let appMenu = NSApp.mainMenu?.items.first?.submenu {
            appMenu.items[0].title = L("About anDrop", "关于 anDrop")
            appMenu.items[1].title = L("Transfers", "传输")
            appMenu.items.first(where: { $0.action == #selector(checkForUpdates) })?.title = L("Check for Updates…", "检查更新…")
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
        refreshRadioAvailability()
        expirePeerUpdates()
        if configuredName != sharingName && !busy { configureEngine(); advertise() }
        let petal = petalIsRunning
        if petal != petalRunning {
            petalRunning = petal
            if !petalRepairing { compactName = petal }
            advertise()
        }
        // Launch Services can restore .regular after the pre-run policy was set.
        // Reconcile even when Petal's running state has not changed.
        let policy: NSApplication.ActivationPolicy = petal || petalRepairing ? .regular : .accessory
        if NSApp.activationPolicy() != policy { NSApp.setActivationPolicy(policy) }
        flushNotifications(); rebuildMenu()
    }
    private func advertise() {
        guard receiveSwitchIsOn else { peripheral?.stopAdvertising(); advertisedName = ""; return }
        guard serviceReady, engineReady else { return }
        let name = discoveryID + "B" + displayName
        guard name != advertisedName || peripheral?.isAdvertising != true else { return }
        peripheral?.stopAdvertising(); advertisedName = name
        peripheral?.startAdvertising([CBAdvertisementDataLocalNameKey: name, CBAdvertisementDataServiceUUIDsKey: [CBUUID(string: "8881")]])
    }
    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        defer { refreshRadioAvailability() }
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
    private func mayAccessReceiveControl(_ centralID: String) -> Bool {
        let active = transfers.first { $0.direction == "receive" && ["verifying", "request", "connecting", "transferring", "confirming"].contains($0.state) }
        return ReceiveAccessPolicy.allows(centralID: centralID, enabled: receiveSwitchIsOn,
            trustedOnly: trustedOnly, trustedIDs: trustedDevices.map(\.id),
            activeReceiveID: active?.transportIdentifier ?? active?.deviceIdentifier)
    }
    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
        guard mayAccessReceiveControl(request.central.identifier.uuidString) else {
            peripheral.respond(to: request, withResult: .insufficientAuthorization); return
        }
        let data = request.characteristic.uuid == CBUUID(string: "9898") ? readValue : Data()
        guard request.offset <= data.count else { peripheral.respond(to: request, withResult: .invalidOffset); return }
        request.value = data.subdata(in: request.offset..<data.count); peripheral.respond(to: request, withResult: .success)
    }
    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        // Reject the whole ATT batch before retaining fragments or sending commands.
        if requests.contains(where: { !mayAccessReceiveControl($0.central.identifier.uuidString) }) {
            if let first = requests.first { peripheral.respond(to: first, withResult: .insufficientAuthorization) }
            return
        }
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
        // CoreBluetooth has no API to reject subscription itself; send no application data.
        guard mayAccessReceiveControl(central.identifier.uuidString) else { return }
        centrals[central.identifier.uuidString] = central; command(["command": "subscribe", "central": central.identifier.uuidString, "uuid": characteristic.uuid.uuidString])
    }
    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didUnsubscribeFrom characteristic: CBCharacteristic) {
        centrals[central.identifier.uuidString] = nil
    }
    func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) { flushNotifications() }
    private func flushNotifications() {
        guard let char = chars["9895"], let peripheral else { return }
        while let first = notifyQueue.first {
            let target: [CBCentral]
            if let id = first.1 {
                guard mayAccessReceiveControl(id), let central = centrals[id] else { notifyQueue.removeFirst(); continue }
                target = [central]
            } else {
                // Never pass nil, which broadcasts to every subscribed central.
                target = Array(centrals.values).filter { mayAccessReceiveControl($0.identifier.uuidString) }
                if target.isEmpty { notifyQueue.removeFirst(); continue }
            }
            guard peripheral.updateValue(first.0, for: char, onSubscribedCentrals: target) else { return }; notifyQueue.removeFirst()
        }
    }
    func showDiagnostics(for transferID: String? = nil) {
        diagnosticMessage = ""
        let id = transferID ?? transfers.first(where: { $0.state == "failed" })?.id
        do {
            let report = try diagnostics.makeReport(transfer: id, appVersion: applicationVersion + " (" + (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") + ")")
            diagnosticFile = report.url; diagnosticText = report.text
        } catch {
            diagnosticFile = nil; diagnosticText = ""
            diagnosticMessage = L("Could not save the diagnostic report. Check available disk space and folder access.", "无法保存诊断报告，请检查可用磁盘空间及文件夹访问权限。")
        }
        showSettings(); showingDiagnostics = true
    }
    func revealDiagnosticLog() {
        if let diagnosticFile { NSWorkspace.shared.activateFileViewerSelecting([diagnosticFile]) }
    }
    func reportBug() {
        guard let file = diagnosticFile else { return }
        let body = L("What happened and how to reproduce it:\n\nExpected behavior:\n\nOther device model:\nOther device OS and version (if known; e.g. Android 16 / ColorOS 16):\nWas a VPN or a device-connectivity app running? If so, which one?\n\nThe attached anDrop diagnostic report includes file types, device metadata and running Mac apps. Please review it before sending.", "遇到的问题及复现步骤：\n预期结果：\n接收端设备型号：\n接收端系统及版本（如知道请填写，例如Android 17 / ColorOS 17）：\n当时是否开启了 VPN 或手机互联类应用（例如OPPO 互联）？如有，请填写名称：\n附件为 anDrop 诊断报告，包含文件类型、设备信息及 Mac 上运行的应用列表。发送前请先检查内容，确认不含敏感信息。")
        guard let service = NSSharingService(named: .composeEmail), service.canPerform(withItems: [body, file]) else {
            diagnosticMessage = L("Could not open an email draft. Use Show in Finder and attach the log to an email to support@takeruf.com.", "无法打开邮件草稿。请点击“在访达中显示”，将日志作为附件发送至 support@takeruf.com。")
            return
        }
        service.recipients = ["support@takeruf.com"]
        service.subject = "anDrop " + applicationVersion + L(" — Bug report", " — 问题反馈")
        service.delegate = self; reportMailService = service
        diagnosticMessage = L("Review the draft and attachment in Mail, then send it when ready.", "请在邮件中检查草稿和附件，确认后再发送。")
        service.perform(withItems: [body, file])
    }
    func sharingService(_ sharingService: NSSharingService, didFailToShareItems items: [Any], error: any Error) {
        diagnosticMessage = L("The email draft could not be opened. Use Show in Finder and send the log to support@takeruf.com manually.", "未能打开邮件草稿。请在访达中找到日志，手动发送至 support@takeruf.com。")
        reportMailService = nil
    }
    private func setupNotifications() {
        let center = UNUserNotificationCenter.current(); center.delegate = self
        center.setNotificationCategories([
            UNNotificationCategory(identifier: "receive", actions: [UNNotificationAction(identifier: "accept", title: L("Accept", "接收")), UNNotificationAction(identifier: "decline", title: L("Decline", "拒绝"))], intentIdentifiers: []),
            UNNotificationCategory(identifier: "failed", actions: [UNNotificationAction(identifier: "logs", title: L("Show Logs", "查看日志"), options: [.foreground])], intentIdentifiers: []),
            // Finder owns the foreground for this action. Activating anDrop as
            // well can trigger applicationShouldHandleReopen and show Settings.
            UNNotificationCategory(identifier: "complete", actions: [UNNotificationAction(identifier: "reveal", title: L("Show in Finder", "在访达中显示"))], intentIdentifiers: []),
            UNNotificationCategory(identifier: "manage", actions: [UNNotificationAction(identifier: "manage", title: L("Show Transfers", "查看传输"), options: [.foreground]), UNNotificationAction(identifier: "cancel", title: L("Cancel", "取消"))], intentIdentifiers: [])
        ])
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] allowed, _ in Task { @MainActor [weak self] in self?.notificationsAllowed = allowed } }
    }
    private func sendNotification(_ transfer: Transfer, category: String, title: String, body: String) {
        let content = UNMutableNotificationContent(); content.title = title; content.body = body; content.categoryIdentifier = category; content.threadIdentifier = transfer.id
        content.userInfo = ["direction": transfer.direction]
        if transfer.state != "transferring" { content.sound = .default }
        let request = UNNotificationRequest(identifier: transfer.id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { [weak self] error in
            guard error == nil else { return }
            Task { @MainActor [weak self] in
                guard let deadline = Self.transferNotificationExpiration(category: category, deliveredAt: Date()) else { return }
                self?.scheduleNotificationCleanup(at: deadline)
            }
        }
    }
    private static func transferNotificationExpiration(category: String, deliveredAt: Date) -> Date? {
        // Both directions expire, including notifications from older versions
        // without userInfo. Requests and active transfers still need their actions.
        guard category == "complete" || category == "failed" else { return nil }
        return deliveredAt.addingTimeInterval(3 * 60)
    }
    private func scheduleNotificationCleanup(at deadline: Date) {
        if let timer = notificationCleanupTimer, timer.isValid, timer.fireDate <= deadline { return }
        notificationCleanupTimer?.invalidate()
        let timer = Timer(fire: deadline, interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.notificationCleanupTimer = nil
                self?.clearExpiredTransferNotifications()
            }
        }
        notificationCleanupTimer = timer
        // Menu tracking must not postpone removal until the menu closes.
        RunLoop.main.add(timer, forMode: .common)
    }
    private func clearExpiredTransferNotifications() {
        UNUserNotificationCenter.current().getDeliveredNotifications { [weak self] notifications in
            // Copy values before crossing to the main actor; UNNotification
            // itself is not Sendable under Swift 6 strict concurrency.
            let delivered = notifications.map {
                (id: $0.request.identifier, category: $0.request.content.categoryIdentifier, date: $0.date)
            }
            Task { @MainActor [weak self] in
                let now = Date()
                var expired: [String] = []
                var nextDeadline: Date?
                for notification in delivered {
                    guard let deadline = Self.transferNotificationExpiration(
                        category: notification.category,
                        deliveredAt: notification.date
                    ) else { continue }
                    if deadline <= now { expired.append(notification.id) }
                    else { nextDeadline = min(nextDeadline ?? deadline, deadline) }
                }
                if !expired.isEmpty { UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: expired) }
                if let nextDeadline { self?.scheduleNotificationCleanup(at: nextDeadline) }
            }
        }
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) { completionHandler([.banner, .sound]) }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping @Sendable () -> Void) {
        let id = response.notification.request.identifier
        let action = response.actionIdentifier
        let category = response.notification.request.content.categoryIdentifier
        Task { @MainActor in
        guard action != UNNotificationDismissActionIdentifier else { completionHandler(); return }
        if id == AppUpdates.notificationID { self.updates.notificationClicked(); completionHandler(); return }
        if action == "logs" || (action != UNNotificationDismissActionIdentifier &&
            (category == "failed" || self.transfers.first(where: { $0.id == id })?.state == "failed")) {
            showDiagnostics(for: id)
        } else if let t = self.transfers.first(where: { $0.id == id }) {
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
                    // Otherwise a fully hidden list looks like a discovery failure.
                    Text(model.peers.isEmpty
                         ? L("Turn on 互传 or Huawei Share and allow nearby discovery. Use the same Wi-Fi.", "请开启互传或华为分享并允许附近设备发现，同时连接同一 Wi-Fi。")
                         : L("Every nearby device is hidden. Restore them in Settings.", "附近设备均已隐藏，可在设置中恢复显示。"))
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
                if !model.outgoing.isEmpty {
                    Text(!model.pendingRetryIDs.isEmpty ? L("Looking for devices to retry…", "正在查找设备以重试…") : model.outgoingActive
                         ? L("Click another device to send the same files.", "点击其他设备即可继续发送相同文件。")
                         : L("Sent to \(model.outgoingTransfers.filter { $0.state == "complete" }.count) of \(model.outgoing.count) devices.", "已发送到 \(model.outgoingTransfers.filter { $0.state == "complete" }.count)/\(model.outgoing.count) 台设备。"))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(3)
                    Spacer(minLength: 0)
                } else {
                    Text(model.candidatePeers.contains(where: model.peerIsAmbiguous)
                         ? L("Same name? Right-click a device icon to rename or hide it.", "设备重名？右键点击设备图标即可重命名或隐藏。")
                         : L("Click a device to send. You can send to others too.", "点击设备即可发送，也可继续点击其他设备。"))
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                Button(model.outgoingActive || !model.pendingRetryIDs.isEmpty ? L("Cancel All", "全部取消") : model.outgoing.isEmpty ? L("Cancel", "取消") : L("Done", "完成")) {
                    model.cancelOrCloseRecipients()
                }.keyboardShortcut(.cancelAction).controlSize(.large)

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
            Text(L("Up to 40 characters. Leave blank to use device details. Saved only on this Mac.", "最多 40 个字符。留空时使用设备信息。此名称仅保存在本机。"))
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
    private var transfer: Transfer? { model.outgoingTransfer(for: peer) }
    private var retrying: Bool { transfer.map { model.pendingRetryIDs.contains($0.id) } ?? false }
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
    private func send() { model.send(to: peer) }
    @ViewBuilder private var commands: some View {
        Button(L("Rename Device…", "重命名设备…")) { model.renamePeer(peer) }.disabled(model.busy)
        Button(L("Hide from Candidates", "从候选设备中隐藏")) { model.hidePeer(peer) }.disabled(model.busy)
    }
    private func transferPresentation(_ transfer: Transfer) -> some View {
        VStack(spacing: 6) {
            avatar.accessibilityHidden(true)
            name.accessibilityLabel(accessibleName)
            Text(retrying ? L("Looking for device…", "正在查找设备…") : transfer.progress.label(chinese: appLanguage() == "zh"))
                .font(.system(size: 11)).monospacedDigit()
                .foregroundStyle(!retrying && model.canRetry(transfer) ? Color.red : Color.blue)
                .lineLimit(2).multilineTextAlignment(.center)
            if model.canRetry(transfer), !retrying {
                Text(L("Click to retry", "点击重试")).font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
    }
    var body: some View {
        VStack(spacing: 6) {
            if let transfer {
                if model.canRetry(transfer) {
                    Button { model.retryOutgoing(transfer.id) } label: { transferPresentation(transfer) }
                        .buttonStyle(.plain)
                        .disabled(!model.receiving || !model.engineReady || retrying)
                        .accessibilityLabel(L("Retry sending to \(accessibleName)", "重试发送到 \(accessibleName)"))
                } else {
                    transferPresentation(transfer)
                }
                if transfer.active {
                    Button(L("Cancel", "取消")) { model.cancel(transfer) }.font(.caption).buttonStyle(.plain)
                }
                if !transfer.detail.isEmpty, model.canRetry(transfer) {
                    Text(transfer.detail).font(.system(size: 10)).foregroundStyle(.secondary)
                        .lineLimit(3).multilineTextAlignment(.center).help(transfer.detail)
                }
            } else {
                // One click starts this recipient without hiding or disabling others.
                Button(action: send) { avatar }
                    .buttonStyle(.plain).disabled(!model.canSend(to: peer))
                    .accessibilityLabel(accessibleName)
                    .contextMenu { commands }
                Button(action: send) { name }
                    .buttonStyle(.plain).disabled(!model.canSend(to: peer))
                    .accessibilityLabel(accessibleName)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if model.peerIsAmbiguous(peer) {
                Text(peer.distinguishingCode(among: model.peers)).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity).padding(.vertical, 4)
        .help([model.peerTitle(peer), model.peerSubtitle(peer)].filter { !$0.isEmpty }.joined(separator: " · "))
        .contextMenu { if transfer == nil { commands } }
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
        Circle().fill(BrandLogos.background(for: peer.brand).map { Color(nsColor: $0) } ?? (BrandLogos.image(for: peer.brand) == nil ? Color(nsColor: .quaternaryLabelColor) : .white))
            .overlay {
                if peer.brand == "Apple" {
                    Image(systemName: "apple.logo").font(.system(size: 30)).foregroundStyle(.primary)
                } else if let logo = BrandLogos.image(for: peer.brand) {
                    if peer.brand == "Xiaomi" {
                        Image(nsImage: logo).resizable().scaledToFill()
                            .frame(width: 62, height: 62).clipShape(Circle())
                    } else {
                        let isHuawei = peer.brand == "Huawei" || peer.brand == "HUAWEI"
                        Image(nsImage: logo).renderingMode(BrandLogos.usesWhiteLogo(for: peer.brand) ? .template : .original).resizable().scaledToFit()
                            .foregroundStyle(.white).frame(width: isHuawei ? 44 : 50, height: isHuawei ? 38 : 44)
                    }
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
    @State private var editingSharingName = false
    @State private var managingTrustedDevices = false
    @State private var managingHiddenDevices = false
    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 20) {
            HStack { Text("anDrop").font(.title2.bold()); Spacer() }
            if let incoming = model.transfers.first(where: { $0.state == "request" }) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L("\(fileCountLabel(incoming.count)) from \(incoming.peer)", "来自 \(incoming.peer) 的 \(incoming.count) 个文件")).font(.headline)
                    HStack { Button(L("Accept", "接收")) { model.decide(incoming, accept: true) }; Button(L("Decline", "拒绝")) { model.decide(incoming, accept: false) } }
                }
            }
            VStack(alignment: .leading, spacing: 8) { Text(L("Save received files to", "接收文件保存位置")).font(.headline); HStack { Text(model.destination).font(.callout).lineLimit(1).truncationMode(.middle); Spacer(); Button(L("Change…", "更改…"), action: model.chooseDestination).disabled(model.busy) }; Text(L("Existing files are never overwritten.", "同名文件不会被覆盖。")).font(.caption).foregroundStyle(.secondary) }
            VStack(alignment: .leading, spacing: 8) {
                Picker(L("Allow Requests From", "接收范围"), selection: Binding(get: { model.trustedOnly }, set: model.changeTrustedOnly)) {
                    Text(L("Trusted Devices Only", "仅限受信任的设备")).tag(true)
                    Text(L("Everyone", "所有人")).tag(false)
                }
                Toggle(L("Automatically accept from trusted devices", "自动接收受信任设备的文件"), isOn: Binding(get: { model.autoAcceptTrusted }, set: model.changeAutoAcceptTrusted))
                Text(L("On by default in both receive modes. Turn off to approve each transfer from trusted devices. Other devices always need approval in Everyone mode.", "默认开启，适用于两种接收范围。关闭后，受信任设备的每次传输也需确认。在“所有人”模式下，其他设备始终需要确认。"))
                    .font(.caption).foregroundStyle(.secondary)
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 8) {
                        if model.trustedDevices.isEmpty {
                            Text(L("No trusted devices", "尚未添加受信任的设备"))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        ForEach(model.trustedDevices) { device in
                            HStack(spacing: 8) {
                                RecipientAvatar(peer: device.peer)
                                    .scaleEffect(0.5).frame(width: 36, height: 36)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(model.peerTitle(device.peer))
                                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                                        .help(model.peerTitle(device.peer))
                                    if device.peer.isAmbiguous(among: model.trustedDevices.map(\.peer), aliases: model.peerAliases, chinese: appLanguage() == "zh") {
                                        Text(device.peer.distinguishingCode(among: model.trustedDevices.map(\.peer)))
                                            .font(.caption.monospaced()).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer(minLength: 0)
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    Button(L("Trusted Devices…", "受信任的设备…")) { managingTrustedDevices = true }
                }
                Text(L("Other devices can still see this Mac. In Trusted Devices Only mode, their transfer requests are rejected.", "未受信任的设备仍可发现此 Mac；选择“仅限受信任的设备”后，其传输请求会被拒绝。"))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text(L("To trust a Huawei device, receive a file in Everyone mode, then add it in Trusted Devices.", "添加华为设备前，请在“所有人”模式下接收一次文件，再到“受信任的设备”中添加。"))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(L("Hidden Devices", "已隐藏的设备")).font(.headline)
                    Spacer()
                    Button(L("Hidden Devices…", "已隐藏的设备…")) { managingHiddenDevices = true }
                }
                Text(model.hiddenDevices.devices.isEmpty
                     ? L("No hidden devices", "尚未隐藏任何设备")
                     : L("\(model.hiddenDevices.devices.count) hidden", "已隐藏 \(model.hiddenDevices.devices.count) 台"))
                    .font(.caption).foregroundStyle(.secondary)
                Text(L("Hidden devices are left out of the recipient list on this Mac. Receiving is not affected.", "隐藏的设备不会出现在本机的发送候选列表中，不影响接收。"))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Picker(L("Language", "语言"), selection: Binding(get: { model.language }, set: model.changeLanguage)) {
                Text(L("System Default", "跟随系统")).tag("system")
                Text("English").tag("en")
                Text("简体中文").tag("zh")
            }
            Divider()
            Toggle(L("Open at Login", "登录时启动"), isOn: Binding(get: { model.startAtLogin }, set: model.changeLogin))
            HStack { Text(model.notificationsAllowed ? L("Notifications: On", "通知：已开启") : L("Notifications: Off", "通知：已关闭")); Spacer(); Button(L("Notification Settings…", "通知设置…")) { if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") { NSWorkspace.shared.open(url) } } }
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(model.petalRunning ? L("With Petal · Nearby name “A”", "鸿蒙星河互联运行中 · 附近设备名称“A”") : L("Discoverable as “\(model.displayName)”", "在附近设备中显示为“\(model.displayName)”"))
                    Button { editingSharingName = true } label: { Image(systemName: "pencil") }
                        .buttonStyle(.borderless)
                        .help(L("Change sharing name", "更改共享名称"))
                        .accessibilityLabel(L("Change sharing name", "更改共享名称"))
                        .disabled(model.busy)
                    Spacer(minLength: 0)
                }
                Text(L("Nearby device names: up to 15 UTF-8 bytes (15 ASCII characters or typically 5 Chinese characters). Transfer confirmations use the full sharing name. Leave the custom name blank to use the Mac name.", "附近设备名称上限：15 个 UTF-8 字节（15 个 ASCII 字符（英文、数字等），或通常 5 个汉字）。传输确认使用完整共享名称。自定义名称留空时使用系统电脑名称。"))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if model.petalRunning {
                    Text(L("anDrop handles Huawei Share file transfers on its own. We recommend quitting Petal Interconnect before sharing. Coexistence is experimental and may cause discovery or transfer failures. Finish any Petal transfers before quitting it.", "anDrop 已可独立通过华为分享收发文件，建议共享前退出鸿蒙星河互联。共存仍属实验性支持，可能导致设备发现或传输失败。退出前请先完成鸿蒙星河互联中的传输。"))
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            if model.petalRunning {
                Text(L("The Dock icon is shown only while Petal is running to preserve Bluetooth discovery. It hides again after Petal quits.", "仅在鸿蒙星河互联运行期间保留 Dock 图标，以维持蓝牙设备发现；退出鸿蒙星河互联后会自动隐藏。"))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if model.petalRunning { Button(model.petalRepairing ? L("Restarting Petal…", "正在重启鸿蒙星河互联…") : L("Repair Discovery with Petal", "修复与鸿蒙星河互联的发现冲突"), action: model.repairPetal).disabled(model.busy || model.petalRepairing) }
            UpdateSettingsView(updates: model.updates, chinese: appLanguage() == "zh", busy: model.busy)
            Button(L("Diagnostics & Bug Report…", "诊断与问题反馈…")) { model.showDiagnostics() }
            HStack { Button(L("Clear Transfer History", "清除传输记录"), action: model.clearHistory); Spacer(); Text(applicationVersion).font(.caption).foregroundStyle(.secondary) }
            Text(L("Mutual Transfer Alliance · Huawei Share · Same Wi-Fi required.", "互传联盟 · 华为分享 · 需连接同一 Wi-Fi。")).font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 16) {
                Link(L("License (GPL-3.0)", "许可证（GPL-3.0）"), destination: URL(string: "https://github.com/TakeruF/androp/blob/main/LICENSE")!)
                Link(L("GitHub Repository", "GitHub 仓库"), destination: URL(string: "https://github.com/TakeruF/androp")!)
            }.font(.caption)
        }.padding(24)
        }.frame(width: 460, height: min(640, (NSScreen.main?.visibleFrame.height ?? 740) - 100))
            .sheet(isPresented: $editingSharingName) {
                SharingNameView(model: model)
            }
            .sheet(isPresented: $managingTrustedDevices) { TrustedDevicesView(model: model) }
            .sheet(isPresented: $managingHiddenDevices) { HiddenDevicesView(model: model) }
            .sheet(isPresented: $model.showingDiagnostics) { DiagnosticsView(model: model) }
    }
}

struct DiagnosticsView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("Diagnostics & Bug Report", "诊断与问题反馈")).font(.headline)
            Text(L("Review this log before emailing support@takeruf.com. It contains transfer stages, errors, file types, device information and running Mac apps. File names, file contents, device names, network addresses and credentials are excluded.", "请检查日志内容后再发送至 support@takeruf.com。日志包含传输阶段、错误、文件类型、设备信息及 Mac 上运行的应用；不包含文件名、文件内容、设备名称、网络地址或密钥。"))
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text(L("Older failures may have no detailed log. Reproduce the issue to collect one.", "旧版或较早的失败记录可能没有详细日志，重现问题后可生成新日志。"))
                .font(.caption).foregroundStyle(.secondary)
            ScrollView([.vertical, .horizontal]) {
                Text(model.diagnosticText).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }.frame(height: 220).background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            if let file = model.diagnosticFile {
                Text((file.path as NSString).abbreviatingWithTildeInPath).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            if !model.diagnosticMessage.isEmpty { Text(model.diagnosticMessage).font(.callout).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Button(L("Show in Finder", "在访达中显示"), action: model.revealDiagnosticLog).disabled(model.diagnosticFile == nil)
                Spacer()
                Button(L("Report a Bug…", "向开发者报告问题…"), action: model.reportBug).disabled(model.diagnosticFile == nil)
                Button(L("Done", "完成")) { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }.padding(20).frame(width: 500)
    }
}

struct TrustedDevicesView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("Trusted Devices", "受信任的设备")).font(.headline)
            Text(L("Devices you have received files from can be added as trusted devices.", "有接收记录的设备可添加为受信任的设备。"))
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(model.trustedDevices) { device in deviceRow(device, trusted: true) }
                    ForEach(model.knownDevices.filter { device in !model.trustedDevices.contains { $0.id == device.id } }) { device in deviceRow(device, trusted: false) }
                    if model.trustedDevices.isEmpty && model.knownDevices.isEmpty { Text(L("No devices yet", "暂无设备")).foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 80) }
                }
            }.frame(height: 230)
            Text(L("Receive a file in Everyone mode first, including from Huawei devices. Huawei trust uses the transfer public key; other devices use a self-reported sender ID. This is not account pairing. If the key or ID changes, receive and add the device again.", "华为等新设备请先在“所有人”模式下接收一次文件。华为设备按传输公钥识别，其他设备按自行提供的发送者标识识别，均不等同于账号配对。公钥或标识变化后需重新接收并添加。"))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack { Spacer(); Button(L("Done", "完成")) { dismiss() }.keyboardShortcut(.defaultAction) }
        }.padding(20).frame(width: 420)
    }
    private func deviceRow(_ device: RememberedDevice, trusted: Bool) -> some View {
        HStack {
            RecipientAvatar(peer: device.peer)
                .scaleEffect(0.64).frame(width: 44, height: 44).padding(.trailing, 6)
            VStack(alignment: .leading) {
                Text(model.peerTitle(device.peer)).lineLimit(2)
                Text(ReceiveAccessPolicy.persistentID(device.id) ? String(device.id.suffix(8)) : L("Receive a file to update this entry", "需重新接收文件并添加")).font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            Spacer()
            Button(trusted ? L("Remove", "移除") : L("Add", "添加")) { model.setTrusted(device, trusted: !trusted) }
            if !trusted { Button { model.forgetDevice(device) } label: { Image(systemName: "trash") }.help(L("Forget Device", "忘记设备")) }
        }
    }
}

struct HiddenDevicesView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    private var devices: [HiddenDevice] { model.hiddenDevices.devices }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("Hidden Devices", "已隐藏的设备")).font(.headline)
            Text(L("Hidden devices are left out of the recipient list on this Mac. Restore one at any time, even while it is offline.", "隐藏的设备不会出现在本机的发送候选列表中。即使设备当前离线，也可随时恢复显示。"))
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(devices) { device in deviceRow(device) }
                    if devices.isEmpty {
                        Text(L("No hidden devices", "尚未隐藏任何设备")).foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 80)
                    }
                }
            }.frame(height: 230)
            HStack { Spacer(); Button(L("Done", "完成")) { dismiss() }.keyboardShortcut(.defaultAction) }
        }.padding(20).frame(width: 420)
    }
    private func deviceRow(_ device: HiddenDevice) -> some View {
        let chinese = appLanguage() == "zh"
        let title = device.title(aliases: model.peerAliases, chinese: chinese)
        let subtitle = device.subtitle(aliases: model.peerAliases, chinese: chinese)
        return HStack {
            RecipientAvatar(peer: device.displayPeer)
                .scaleEffect(0.64).frame(width: 44, height: 44).padding(.trailing, 6)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                if !subtitle.isEmpty {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                if device.isAmbiguous(among: devices, aliases: model.peerAliases, chinese: chinese) {
                    Text(device.distinguishingCode(among: devices)).font(.caption.monospaced()).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button(L("Show", "恢复显示")) { model.showHiddenDevice(device) }
                .disabled(model.busy)
                .accessibilityLabel(L("Show \(title) in the recipient list", "在候选设备中恢复显示 \(title)"))
        }
    }
}

struct SharingNameView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @FocusState private var nameFocused: Bool

    init(model: AppModel) {
        self.model = model
        _name = State(initialValue: model.customSharingName)
    }
    private var normalizedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var valid: Bool {
        normalizedName.utf8.count <= 15 && !normalizedName.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
    private func save() { if model.changeSharingName(name) { dismiss() } }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("Sharing Name", "共享名称")).font(.headline)
            Text(L("Visible to nearby devices. Leave blank to follow this Mac’s system name. This does not rename your Mac.", "附近设备可见。留空时跟随本机的系统名称，不会修改 Mac 的系统名称。"))
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextField(model.deviceName, text: $name).textFieldStyle(.roundedBorder).focused($nameFocused).onSubmit(save)
            Text(L("\(normalizedName.utf8.count)/15 UTF-8 bytes · 15 ASCII characters or typically 5 Chinese characters.", "\(normalizedName.utf8.count)/15 个 UTF-8 字节 · 15 个 ASCII 字符（英文、数字等）或通常 5 个汉字。"))
                .font(.caption).foregroundStyle(valid ? Color.secondary : Color.red).fixedSize(horizontal: false, vertical: true)
            if model.petalRunning {
                Text(L("While Petal runs, the nearby name remains “A”. Your sharing name is used in transfer confirmations and restored nearby when Petal quits.", "鸿蒙星河互联运行时，附近名称仍为“A”。传输确认使用此共享名称，退出鸿蒙星河互联后附近名称也会恢复。"))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button(L("Use Mac Name", "使用 Mac 名称")) { name = "" }
                Spacer()
                Button(L("Cancel", "取消")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L("Save", "保存"), action: save).keyboardShortcut(.defaultAction).disabled(!valid || model.busy)
            }
        }.padding(20).frame(width: 360).onAppear { nameFocused = true }
    }
}

configureBundleLanguage()
let app = NSApplication.shared
let model = AppModel()
app.setActivationPolicy(NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == "com.EMUIInterconnect.app" } ? .regular : .accessory)
app.delegate = model
app.run()
