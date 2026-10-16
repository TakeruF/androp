// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 anDrop contributors
import AppKit
import SwiftUI
import Combine
#if canImport(Sparkle) && !APP_STORE
import Sparkle
#endif

@MainActor
final class AppUpdates: NSObject, ObservableObject {
    #if APP_STORE
    let isAvailable = false
    #else
    let isAvailable = true
    #endif
    @Published private(set) var automaticallyChecks = UserDefaults.standard.object(forKey: "SUEnableAutomaticChecks") as? Bool ?? true
    @Published private(set) var automaticallyDownloads = UserDefaults.standard.object(forKey: "SUAutomaticallyUpdate") as? Bool ?? true
    @Published private(set) var canCheck = false
    @Published private(set) var readyVersion: String?
    private var hasActiveTransfers: () -> Bool = { false }
    private var readyInstall: (() -> Void)?
    private var postponedInstall: (() -> Void)?
    private var didPresentReadyAlert = false
    private(set) var installing = false
    #if canImport(Sparkle) && !APP_STORE
    private var controller: SPUStandardUpdaterController?
    #endif

    func start(hasActiveTransfers: @escaping () -> Bool) {
        self.hasActiveTransfers = hasActiveTransfers
        #if canImport(Sparkle) && !APP_STORE
        guard controller == nil else { return }
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
        self.controller = controller
        controller.updater.publisher(for: \.canCheckForUpdates).receive(on: RunLoop.main).assign(to: &$canCheck)
        controller.updater.publisher(for: \.automaticallyChecksForUpdates).receive(on: RunLoop.main).assign(to: &$automaticallyChecks)
        controller.updater.publisher(for: \.automaticallyDownloadsUpdates).receive(on: RunLoop.main).assign(to: &$automaticallyDownloads)
        controller.startUpdater()
        // Honor the user's persisted setting; do not reset defaults on launch.
        if controller.updater.automaticallyChecksForUpdates {
            controller.updater.checkForUpdatesInBackground()
        }
        #endif
    }

    func setAutomaticallyChecks(_ value: Bool) {
        #if canImport(Sparkle) && !APP_STORE
        controller?.updater.automaticallyChecksForUpdates = value
        #endif
        automaticallyChecks = value
    }
    func setAutomaticallyDownloads(_ value: Bool) {
        #if canImport(Sparkle) && !APP_STORE
        controller?.updater.automaticallyDownloadsUpdates = value
        #endif
        automaticallyDownloads = value
    }
    func checkForUpdates() {
        guard !hasActiveTransfers() else { return }
        if readyInstall != nil { presentReadyUpdate(force: true); return }
        #if canImport(Sparkle) && !APP_STORE
        controller?.checkForUpdates(nil)
        #endif
    }
    func transferStateDidChange() {
        guard !hasActiveTransfers() else { return }
        if let postponedInstall {
            self.postponedInstall = nil
            installing = true
            postponedInstall()
        } else if readyInstall != nil && !didPresentReadyAlert {
            presentReadyUpdate()
        }
    }
    private func presentReadyUpdate(force: Bool = false) {
        guard !hasActiveTransfers(), let readyInstall, let readyVersion, force || !didPresentReadyAlert else { return }
        didPresentReadyAlert = true
        let alert = NSAlert()
        alert.messageText = L("anDrop \(readyVersion) is ready to install", "anDrop \(readyVersion) 已下载完成")
        alert.informativeText = L("The update has been verified. Restart anDrop to install it, or keep using the app and install when you quit.", "更新已通过验证。你可以立即重启 anDrop 安装，也可以稍后退出应用时安装。")
        alert.addButton(withTitle: L("Restart and Update", "重启并更新"))
        alert.addButton(withTitle: L("Later", "稍后"))
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            if hasActiveTransfers() { postponedInstall = readyInstall }
            else { installing = true; readyInstall() }
        }
    }
}

#if canImport(Sparkle) && !APP_STORE
extension AppUpdates: SPUUpdaterDelegate {
    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        if hasActiveTransfers() {
            throw NSError(domain: "org.androp.update", code: 1, userInfo: [NSLocalizedDescriptionKey: L("Finish the current transfer before checking for updates.", "请先完成当前传输，再检查更新。")])
        }
    }
    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem, untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        guard hasActiveTransfers() else { installing = true; return false }
        postponedInstall = installHandler
        return true
    }
    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem, immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        readyVersion = item.displayVersionString
        readyInstall = immediateInstallHandler
        didPresentReadyAlert = false
        Task { @MainActor [weak self] in self?.presentReadyUpdate() }
        return true
    }
    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        installing = false
        readyInstall = nil
        postponedInstall = nil
        readyVersion = nil
    }
}
#endif

struct UpdateSettingsView: View {
    @ObservedObject var updates: AppUpdates
    let chinese: Bool
    let busy: Bool
    private func text(_ english: String, _ simplifiedChinese: String) -> String { chinese ? simplifiedChinese : english }
    var body: some View {
        if updates.isAvailable {
            VStack(alignment: .leading, spacing: 8) {
                Text(text("Updates", "更新")).font(.headline)
                Toggle(text("Check for updates automatically", "自动检查更新"), isOn: Binding(get: { updates.automaticallyChecks }, set: updates.setAutomaticallyChecks))
                Toggle(text("Download updates automatically", "自动下载更新"), isOn: Binding(get: { updates.automaticallyDownloads }, set: updates.setAutomaticallyDownloads))
                    .disabled(!updates.automaticallyChecks)
                HStack {
                    Button(updates.readyVersion == nil ? text("Check for Updates…", "检查更新…") : text("Install Downloaded Update…", "安装已下载的更新…"), action: updates.checkForUpdates)
                        .disabled(busy || (!updates.canCheck && updates.readyVersion == nil))
                    if let version = updates.readyVersion { Text(text("Version \(version) ready", "版本 \(version) 已就绪")).font(.caption).foregroundStyle(.secondary) }
                }
                Text(busy ? text("Updates wait until transfers finish.", "传输完成后才能更新。") : text("Downloads are verified before installation. anDrop will prompt you when an automatic download is ready.", "更新会先通过验证，自动下载完成后再提示你安装。"))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
