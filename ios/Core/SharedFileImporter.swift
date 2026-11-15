// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import UniformTypeIdentifiers

public enum SharedImportError: Error, LocalizedError, Sendable, Equatable {
    case unsupported, oversized, tooManyFiles, invalidName, unreadable, storageUnavailable
    public var errorDescription: String? {
        switch self {
        case .unsupported: "ファイル・写真・動画を選んで共有してください。URLや選択したテキストの直接共有には対応していません。"
        case .oversized: "共有するファイルの合計サイズが\(Limits.byteLimitMiB)MiBを超えています。枚数を減らしてください。"
        case .tooManyFiles: "1回に共有できるのは\(Limits.files)ファイルまでです。枚数を減らしてください。"
        case .invalidName: "共有ファイルの名前を読み取れませんでした。ファイルアプリに保存してから共有してください。"
        case .unreadable: "共有ファイルを読み込めませんでした。もう一度共有するか、anDropのファイル選択を使ってください。"
        case .storageUnavailable: "共有ファイルの一時保存先を準備できませんでした。共有画面を閉じて、もう一度共有してください。"
        }
    }
}

public struct SharedImportDiagnostic: Sendable, Equatable {
    public enum Phase: String, Sendable { case storage, originalURL, originalCopy, fileRepresentation, fileCopy, legacyItem, itemCopy, dataRepresentation, dataWrite }
    public enum Outcome: String, Sendable { case success, unavailable, failed }
    public let fields: [String: String]
    public init(phase: Phase, outcome: Outcome, type: String? = nil, error: (any Error)? = nil) {
        var fields = ["phase": phase.rawValue, "outcome": outcome.rawValue]
        if let type {
            let known: Set<String> = [UTType.fileURL.identifier, UTType.jpeg.identifier, UTType.png.identifier, UTType.heic.identifier, UTType.image.identifier, UTType.pdf.identifier, UTType.movie.identifier, UTType.mpeg4Movie.identifier, UTType.quickTimeMovie.identifier, UTType.audio.identifier, UTType.plainText.identifier, UTType.data.identifier]
            fields["type"] = known.contains(type) ? type : "other"
        }
        if let error {
            let value = error as NSError
            let known = [NSCocoaErrorDomain, NSPOSIXErrorDomain, NSItemProvider.errorDomain]
            fields["error_domain"] = known.contains(value.domain) ? value.domain : "other"
            fields["error_code"] = String(value.code)
        }
        self.fields = fields
    }
}

public typealias SharedImportReporter = @Sendable (SharedImportDiagnostic) -> Void

public struct SharedImportBatch: Sendable {
    public let files: [URL]
    public let totalBytes: Int
}

/// Each request owns a private directory. Provider URLs are copied before their
/// callbacks return, including original file-URL representations when available.
@MainActor public final class SharedFileImporter {
    public let directory: URL
    private var cancelled = false
    public init(baseDirectory: URL = FileManager.default.temporaryDirectory) {
        directory = baseDirectory.appending(path: "anDropShare-" + UUID().uuidString, directoryHint: .isDirectory)
    }
    public func cleanup() { cancelled = true; try? FileManager.default.removeItem(at: directory) }
    public func load(_ providers: [NSItemProvider], report: @escaping SharedImportReporter = { _ in }) async throws -> SharedImportBatch {
        guard !cancelled else { throw CancellationError() }
        guard !providers.isEmpty else { throw SharedImportError.unsupported }
        guard providers.count <= Limits.files else { throw SharedImportError.tooManyFiles }
        try Task.checkCancellation()
        do {
            // The extension's temporary root need not exist on its first launch.
            // Only this initial setup may create parents; callbacks must not.
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            report(.init(phase: .storage, outcome: .success))
        } catch {
            report(.init(phase: .storage, outcome: .failed, error: error))
            cleanup(); throw SharedImportError.storageUnavailable
        }
        do {
            var urls: [URL] = []; var total = 0; var names = Set<String>()
            for provider in providers {
                try Task.checkCancellation()
                guard !cancelled else { throw CancellationError() }
                var url = try await Self.load(provider, directory: directory, maximum: Limits.bytes - total, report: report)
                try Task.checkCancellation()
                guard !cancelled else { throw CancellationError() }
                let original = url.lastPathComponent
                let path = original as NSString
                var name = original; var index = 0
                while !names.insert(name.lowercased()).inserted {
                    index += 1
                    name = path.deletingPathExtension + " (\(index))" + (path.pathExtension.isEmpty ? "" : "." + path.pathExtension)
                }
                guard name.utf8.count <= 240 else { throw SharedImportError.invalidName }
                if name != original {
                    let target = url.deletingLastPathComponent().appending(path: name)
                    try FileManager.default.moveItem(at: url, to: target); url = target
                }
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                total += size; urls.append(url)
            }
            return SharedImportBatch(files: urls, totalBytes: total)
        } catch {
            let wasCancelled = cancelled || Task.isCancelled
            cleanup()
            if wasCancelled { throw CancellationError() }
            throw error
        }
    }
    nonisolated(nonsending) private static func load(_ provider: NSItemProvider, directory: URL, maximum: Int, report: @escaping SharedImportReporter) async throws -> URL {
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            let original: Result<URL, SharedImportError>? = await withCheckedContinuation { continuation in
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
                    let url: URL?
                    if let value = item as? URL { url = value }
                    else if let data = item as? Data { url = URL(dataRepresentation: data, relativeTo: nil) }
                    else { url = nil }
                    guard let url else {
                        report(.init(phase: .originalURL, outcome: .unavailable, type: UTType.fileURL.identifier, error: error))
                        continuation.resume(returning: nil); return
                    }
                    continuation.resume(returning: attempt(.originalCopy, type: UTType.fileURL.identifier, report: report) { try copy(url, to: directory, name: nil, maximum: maximum) })
                }
            }
            if let original { return try original.get() }
        }
        let suggested = provider.suggestedName
        let types = Array(provider.registeredTypeIdentifiers.filter {
            guard let type = UTType($0), type.conforms(to: .data), !type.conforms(to: .url),
                  !type.conforms(to: .directory) else { return false }
            return !type.conforms(to: .text) || suggested != nil
        }.prefix(8))
        guard !types.isEmpty else { throw SharedImportError.unsupported }
        for type in types {
            let file: Result<URL, SharedImportError>? = await withCheckedContinuation { continuation in
                provider.loadFileRepresentation(forTypeIdentifier: type) { url, error in
                    guard let url else {
                        report(.init(phase: .fileRepresentation, outcome: .unavailable, type: type, error: error))
                        continuation.resume(returning: nil); return
                    }
                    continuation.resume(returning: attempt(.fileCopy, type: type, report: report) { try copy(url, to: directory, name: exportName(suggested, fallback: url.lastPathComponent, type: type), maximum: maximum) })
                }
            }
            if let file { return try file.get() }
        }
        // Photos and file providers may vend a URL or encoded bytes through the
        // older item API even when modern file/data representations fail.
        for type in types {
            let file: Result<URL, SharedImportError>? = await withCheckedContinuation { continuation in
                provider.loadItem(forTypeIdentifier: type, options: nil) { item, error in
                    if let url = item as? URL {
                        continuation.resume(returning: attempt(.itemCopy, type: type, report: report) { try copy(url, to: directory, name: nil, maximum: maximum) })
                    } else if let data = item as? Data {
                        continuation.resume(returning: attempt(.dataWrite, type: type, report: report) { try write(data, to: directory, name: exportName(suggested, fallback: "Shared File", type: type), maximum: maximum) })
                    } else {
                        report(.init(phase: .legacyItem, outcome: .unavailable, type: type, error: error))
                        continuation.resume(returning: nil)
                    }
                }
            }
            if let file { return try file.get() }
        }
        for type in types {
            let file: Result<URL, SharedImportError>? = await withCheckedContinuation { continuation in
                provider.loadDataRepresentation(forTypeIdentifier: type) { data, error in
                    guard let data else {
                        report(.init(phase: .dataRepresentation, outcome: .unavailable, type: type, error: error))
                        continuation.resume(returning: nil); return
                    }
                    continuation.resume(returning: attempt(.dataWrite, type: type, report: report) { try write(data, to: directory, name: exportName(suggested, fallback: "Shared File", type: type), maximum: maximum) })
                }
            }
            if let file { return try file.get() }
        }
        throw SharedImportError.unreadable
    }
    nonisolated private static func write(_ data: Data, to directory: URL, name: String, maximum: Int) throws -> URL {
        guard data.count <= maximum else { throw SharedImportError.oversized }
        let folder = try makeFolder(in: directory)
        let url = folder.appending(path: try name.validatedShareName())
        try data.write(to: url, options: .withoutOverwriting)
        return url
    }
    nonisolated private static func attempt(_ phase: SharedImportDiagnostic.Phase, type: String, report: SharedImportReporter, operation: () throws -> URL) -> Result<URL, SharedImportError>? {
        do {
            let file = try operation()
            report(.init(phase: phase, outcome: .success, type: type))
            return .success(file)
        } catch {
            report(.init(phase: phase, outcome: .failed, type: type, error: error))
            return terminal(error)
        }
    }
    nonisolated private static func terminal(_ error: any Error) -> Result<URL, SharedImportError>? {
        guard let error = error as? SharedImportError, error != .unreadable else { return nil }
        return .failure(error)
    }
    nonisolated private static func exportName(_ suggested: String?, fallback: String, type: String) -> String {
        let name = suggested.flatMap { $0.isEmpty ? nil : ($0 as NSString).lastPathComponent } ?? fallback
        let suffix = (name as NSString).pathExtension
        guard let exportedType = UTType(type) else { return name }
        if !suffix.isEmpty {
            if let namedType = UTType(filenameExtension: suffix), namedType.conforms(to: exportedType) { return name }
            // A host may export PNG while suggesting the original JPEG name.
            if let suffix = exportedType.preferredFilenameExtension { return (name as NSString).deletingPathExtension + "." + suffix }
            return name
        }
        guard let suffix = exportedType.preferredFilenameExtension else { return name }
        return name + "." + suffix
    }
    nonisolated private static func makeFolder(in directory: URL) throws -> URL {
        let folder = directory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        // Do not recreate a request directory after cancellation has removed it.
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return folder
    }
    nonisolated private static func copy(_ source: URL, to directory: URL, name: String?, maximum: Int) throws -> URL {
        guard source.isFileURL else { throw SharedImportError.unsupported }
        let access = source.startAccessingSecurityScopedResource()
        defer { if access { source.stopAccessingSecurityScopedResource() } }
        let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw SharedImportError.unsupported }
        guard let size = values.fileSize, size <= maximum else { throw SharedImportError.oversized }
        let folder = try makeFolder(in: directory)
        let target = folder.appending(path: try (name ?? source.lastPathComponent).validatedShareName())
        try FileManager.default.copyItem(at: source, to: target)
        let copied = try target.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard copied.isRegularFile == true, copied.isSymbolicLink != true, copied.fileSize == size else { throw SharedImportError.unreadable }
        return target
    }
}

private extension String {
    func validatedShareName() throws -> String {
        guard let safe = try? FileArchive.safeName(self), safe == self else { throw SharedImportError.invalidName }
        return self
    }
}
