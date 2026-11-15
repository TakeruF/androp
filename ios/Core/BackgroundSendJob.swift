// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Darwin

public struct TransferRecipient: Codable, Sendable, Equatable {
    public let peripheralID: UUID
    public let discoveryID: String
    public let name: String
    public let huawei: HuaweiPeer?
    public init(peripheralID: UUID, discoveryID: String, name: String, huawei: HuaweiPeer? = nil) {
        self.peripheralID = peripheralID; self.discoveryID = discoveryID; self.name = name; self.huawei = huawei
    }
}

public struct BackgroundSendJob: Codable, Sendable, Identifiable {
    public let id: UUID
    public let created: Date
    public let recipient: TransferRecipient
    public let names: [String]
    public let bytes: Int
}

public enum BackgroundSendJobError: Error, LocalizedError, Sendable, Equatable {
    case busy, invalid, unavailable
    public var errorDescription: String? {
        switch self {
        case .busy: "別の転送を処理中です。完了してから共有してください。"
        case .invalid: "転送するファイルを確認できませんでした。もう一度共有してください。"
        case .unavailable: "バックグラウンド転送の保存先を使用できませんでした。"
        }
    }
}

/// A single owned slot prevents the app and Share extension from submitting
/// overlapping transfers. The manifest contains private metadata, never logs.
public struct BackgroundSendJobStore: Sendable {
    public let directory: URL
    private var active: URL { directory.appending(path: "active", directoryHint: .isDirectory) }
    private var payload: URL { active.appending(path: "payload", directoryHint: .isDirectory) }
    public init(directory: URL) { self.directory = directory }
    @concurrent public func enqueue(_ files: [URL], recipient: TransferRecipient) async throws -> BackgroundSendJob {
        guard (1...Limits.files).contains(files.count) else { throw BackgroundSendJobError.invalid }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let modified = try? active.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
           Date().timeIntervalSince(modified) > 600 { try FileManager.default.removeItem(at: active) }
        guard mkdir(active.path, 0o700) == 0 else {
            if errno == EEXIST { throw BackgroundSendJobError.busy }
            throw BackgroundSendJobError.unavailable
        }
        do {
            try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: false)
            var names: [String] = []; var total = 0
            for file in files {
                try Task.checkCancellation()
                let access = file.startAccessingSecurityScopedResource()
                defer { if access { file.stopAccessingSecurityScopedResource() } }
                let name = try FileArchive.safeName(file.lastPathComponent)
                let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true, let size = values.fileSize,
                      size <= Limits.bytes - total, !names.map({ $0.lowercased() }).contains(name.lowercased()) else { throw BackgroundSendJobError.invalid }
                try FileManager.default.copyItem(at: file, to: payload.appending(path: name))
                #if os(iOS)
                try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: payload.appending(path: name).path)
                #endif
                names.append(name); total += size
            }
            let job = BackgroundSendJob(id: UUID(), created: Date(), recipient: recipient, names: names, bytes: total)
            try JSONEncoder().encode(job).write(to: active.appending(path: "manifest.json"), options: .atomic)
            return job
        } catch {
            try? FileManager.default.removeItem(at: active)
            throw error
        }
    }
    private func manifest() throws -> BackgroundSendJob {
        try JSONDecoder().decode(BackgroundSendJob.self, from: Data(contentsOf: active.appending(path: "manifest.json")))
    }
    public func load() throws -> (BackgroundSendJob, [URL]) {
        let job = try manifest()
        guard (-60...600).contains(Date().timeIntervalSince(job.created)), (1...Limits.files).contains(job.names.count),
              job.recipient.discoveryID.count <= 100, job.recipient.name.count <= 100 else { throw BackgroundSendJobError.invalid }
        if let huawei = job.recipient.huawei {
            try huawei.validateMetadata()
            guard job.recipient.discoveryID == huawei.discoveryID else { throw BackgroundSendJobError.invalid }
        }
        var files: [URL] = []; var total = 0; var names = Set<String>()
        for name in job.names {
            guard (try? FileArchive.safeName(name)) == name, names.insert(name.lowercased()).inserted else { throw BackgroundSendJobError.invalid }
            let file = payload.appending(path: name)
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true, let size = values.fileSize,
                  size <= Limits.bytes - total else { throw BackgroundSendJobError.invalid }
            files.append(file); total += size
        }
        guard total == job.bytes else { throw BackgroundSendJobError.invalid }
        return (job, files)
    }
    public func remove(id: UUID) {
        guard (try? manifest().id) == id else { return }
        try? FileManager.default.removeItem(at: active)
    }
    public func markStarted(id: UUID) throws {
        guard try manifest().id == id else { throw BackgroundSendJobError.invalid }
        try Data().write(to: active.appending(path: "started"), options: .atomic)
    }
    public func selectRecipient(id: UUID, recipient: TransferRecipient) throws {
        let (job, _) = try load()
        guard job.id == id, recipient.discoveryID.count <= 100, recipient.name.count <= 100,
              !FileManager.default.fileExists(atPath: active.appending(path: "started").path) else { throw BackgroundSendJobError.invalid }
        let updated = BackgroundSendJob(id: job.id, created: job.created, recipient: recipient, names: job.names, bytes: job.bytes)
        try JSONEncoder().encode(updated).write(to: active.appending(path: "manifest.json"), options: .atomic)
        try Data().write(to: active.appending(path: "ready"), options: .atomic)
    }
    public func loadReady() throws -> (BackgroundSendJob, [URL]) {
        guard FileManager.default.fileExists(atPath: active.appending(path: "ready").path),
              !FileManager.default.fileExists(atPath: active.appending(path: "started").path) else { throw BackgroundSendJobError.invalid }
        return try load()
    }
    /// Only the containing app calls this once on a fresh process launch. A
    /// previously started job cannot survive termination of that app process.
    public func discardInterrupted() {
        guard FileManager.default.fileExists(atPath: active.appending(path: "started").path), let job = try? manifest() else { return }
        remove(id: job.id)
    }
}
