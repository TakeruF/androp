// SPDX-License-Identifier: GPL-3.0-only
import Foundation
@preconcurrency import BackgroundTasks
import anDropProtocol
import CryptoKit

enum BackgroundTransfer {
    static let prefix = "com.takeruf.androp.ios.transfer"
    static let groupIdentifier = "group.com.takeruf.androp.ios"
    static func store() throws -> BackgroundSendJobStore {
        guard let root = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupIdentifier) else { throw BackgroundSendJobError.unavailable }
        return BackgroundSendJobStore(directory: root.appending(path: "TransferHandoff", directoryHint: .isDirectory))
    }
    static func storeDiagnostics() -> [String: String] {
        guard let store = try? store() else { return ["available": "false"] }
        return ["available": "true", "container_tag": SHA256.hash(data: Data(store.directory.path.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined(), "has_job": String((try? store.load()) != nil)]
    }
    @available(iOS 26.0, *) static func submit(id: UUID, title: String, subtitle: String) async throws {
        let identifier = prefix + "." + id.uuidString
        #if !SHARE_EXTENSION
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { task in
            MainActor.assumeIsolated {
                guard let task = task as? BGContinuedProcessingTask else { task.setTaskCompleted(success: false); return }
                SharingModel.shared.handleBackgroundTransfer(task)
            }
        }
        guard registered else { throw BackgroundSendJobError.unavailable }
        #endif
        let request = BGContinuedProcessingTaskRequest(identifier: identifier, title: title, subtitle: subtitle)
        request.strategy = .fail
        if #available(iOS 27.0, *) { try await BGTaskScheduler.shared.submitTaskRequest(request) }
        else { try BGTaskScheduler.shared.submit(request) }
    }
}

@MainActor protocol TransferExecution: AnyObject {
    func update(_ progress: TransferProgress)
    func finish(success: Bool)
}

/// iOS provides the Live Activity, including Dynamic Island / Lock Screen
/// presentation and its cancel action. No remote notifications are involved.
@available(iOS 26.0, *) @MainActor final class ContinuedTransferExecution: TransferExecution {
    private let task: BGContinuedProcessingTask
    private var finished = false
    private var lastUpdate = Date.distantPast
    private var lastStage = ""
    init(task: BGContinuedProcessingTask, expired: @escaping @MainActor () -> Void) {
        self.task = task
        task.progress.totalUnitCount = 1000
        task.progress.completedUnitCount = 0
        task.expirationHandler = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, !finished else { return }
                expired()
            }
        }
    }
    func update(_ progress: TransferProgress) {
        guard !finished else { return }
        let now = Date()
        guard progress.stage != lastStage || progress.terminal || now.timeIntervalSince(lastUpdate) >= 0.25 else { return }
        lastUpdate = now; lastStage = progress.stage
        task.progress.completedUnitCount = max(task.progress.completedUnitCount, progress.completedUnits)
        task.updateTitle(task.title, subtitle: progress.subtitle)
    }
    func finish(success: Bool) {
        guard !finished else { return }
        finished = true
        if success { task.progress.completedUnitCount = 1000 }
        task.expirationHandler = nil
        task.setTaskCompleted(success: success)
    }
}
