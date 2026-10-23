// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 anDrop contributors
import Foundation
import UniformTypeIdentifiers
import OSLog

/// Copy provider-owned resources while their callback's access is still valid.
nonisolated enum SharedFileStaging {
    private static let logger = Logger(subsystem: "com.takeruf.anDrop.Share", category: "FileImport")
    private static let maximumDataBytes = 512 * 1024 * 1024

    /// Some macOS share providers implement the older item loader but cannot
    /// vend loadFileRepresentation, even for their advertised JPEG type.
    nonisolated(nonsending) static func loadFile(from provider: NSItemProvider, cacheDirectory: URL? = nil) async throws -> URL {
        let types = Array(provider.registeredTypeIdentifiers.filter {
            guard let type = UTType($0) else { return false }
            return type.conforms(to: .image) || type.conforms(to: .movie)
        }.prefix(4))
        let hasFileURL = provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
        guard hasFileURL || !types.isEmpty else { throw CocoaError(.fileReadUnsupportedScheme) }
        // Prefer an exported file, copying before the callback returns.
        for type in types {
            let result: URL? = await withCheckedContinuation { continuation in
                provider.loadFileRepresentation(forTypeIdentifier: type) { url, error in
                    guard let url else { record(error, stage: "load_file"); continuation.resume(returning: nil); return }
                    do { continuation.resume(returning: try copyFile(url, cacheDirectory: cacheDirectory)) }
                    catch { record(error, stage: "copy_file"); continuation.resume(returning: nil) }
                }
            }
            if let result { return result }
        }
        // Photos' legacy file-URL representation can work when its modern
        // file representation fails. Never hand that original URL to the host.
        if hasFileURL, let result = await loadItem(from: provider, type: UTType.fileURL.identifier, cacheDirectory: cacheDirectory) {
            return result
        }
        let suggestedName = provider.suggestedName
        for type in types {
            if let result = await loadItem(from: provider, type: type, cacheDirectory: cacheDirectory) { return result }
            let result: URL? = await withCheckedContinuation { continuation in
                provider.loadDataRepresentation(forTypeIdentifier: type) { data, error in
                    guard let data else { record(error, stage: "load_data"); continuation.resume(returning: nil); return }
                    do { continuation.resume(returning: try write(data, type: type, name: suggestedName, cacheDirectory: cacheDirectory)) }
                    catch { record(error, stage: "save_data"); continuation.resume(returning: nil) }
                }
            }
            if let result { return result }
        }
        throw CocoaError(.fileReadUnknown)
    }

    nonisolated(nonsending) private static func loadItem(from provider: NSItemProvider, type: String, cacheDirectory: URL?) async -> URL? {
        let suggestedName = provider.suggestedName
        return await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: type, options: nil) { value, error in
                do {
                    if let url = value as? URL {
                        continuation.resume(returning: try copyFile(url, cacheDirectory: cacheDirectory)); return
                    }
                    if let data = value as? Data {
                        if type == UTType.fileURL.identifier {
                            guard let url = URL(dataRepresentation: data, relativeTo: nil), url.isFileURL else { throw CocoaError(.fileReadCorruptFile) }
                            continuation.resume(returning: try copyFile(url, cacheDirectory: cacheDirectory))
                        } else {
                            continuation.resume(returning: try write(data, type: type, name: suggestedName, cacheDirectory: cacheDirectory))
                        }
                        return
                    }
                    record(error, stage: "load_item")
                } catch { record(error, stage: "copy_item") }
                continuation.resume(returning: nil)
            }
        }
    }

    private static func write(_ data: Data, type: String, name: String?, cacheDirectory: URL?) throws -> URL {
        guard !data.isEmpty, data.count <= maximumDataBytes,
              let fileType = UTType(type), let ext = fileType.preferredFilenameExtension else { throw CocoaError(.fileReadCorruptFile) }
        let folder = try makeFolder(cacheDirectory: cacheDirectory)
        // The provider's suggested name is display metadata, never a path.
        let base = (name.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent } ?? "Shared Photo")
        let safe = base.isEmpty || base == "." || base == ".." || base.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
            ? "Shared Photo" : String(base.prefix(180))
        let target = folder.appendingPathComponent(safe).appendingPathExtension(ext)
        do {
            try data.write(to: target, options: .withoutOverwriting)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
            return target
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }

    private static func record(_ error: (any Error)?, stage: String) {
        let error = error as NSError?
        let allowed = [NSCocoaErrorDomain, NSItemProvider.errorDomain, NSPOSIXErrorDomain]
        let domain = error.map { allowed.contains($0.domain) ? $0.domain : "other" } ?? "none"
        let code = error.map { (-65535...65535).contains($0.code) ? $0.code : 0 } ?? 0
        logger.error("share_file_import stage=\(stage, privacy: .public) domain=\(domain, privacy: .public) code=\(code, privacy: .public)")
    }

    static func copyFile(_ source: URL, cacheDirectory: URL? = nil) throws -> URL {
        try copy(source, bundle: false, cacheDirectory: cacheDirectory)
    }

    static func copyLivePhoto(_ source: URL, cacheDirectory: URL? = nil) throws -> URL {
        try copy(source, bundle: true, cacheDirectory: cacheDirectory)
    }

    private static func validate(_ source: URL, bundle: Bool) throws {
        guard source.isFileURL else { throw CocoaError(.fileReadUnsupportedScheme) }
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        let values = try source.resourceValues(forKeys: keys)
        guard values.isSymbolicLink != true else { throw CocoaError(.fileReadCorruptFile) }
        if !bundle {
            guard values.isRegularFile == true else { throw CocoaError(.fileReadCorruptFile) }
            return
        }
        guard values.isDirectory == true else { throw CocoaError(.fileReadCorruptFile) }
        let children = try FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: Array(keys))
        guard (2...16).contains(children.count) else { throw CocoaError(.fileReadCorruptFile) }
        var size = 0
        for child in children {
            let value = try child.resourceValues(forKeys: keys)
            guard value.isRegularFile == true, value.isSymbolicLink != true else { throw CocoaError(.fileReadCorruptFile) }
            size += value.fileSize ?? 0
            guard size <= 512 * 1024 * 1024 else { throw CocoaError(.fileReadTooLarge) }
        }
    }

    private static func copy(_ source: URL, bundle: Bool, cacheDirectory: URL?) throws -> URL {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        try validate(source, bundle: bundle)
        let manager = FileManager.default
        let folder = try makeFolder(cacheDirectory: cacheDirectory)
        let target = bundle ? folder.appendingPathComponent("Live Photo.pvt", isDirectory: true)
            : folder.appendingPathComponent(source.lastPathComponent)
        do {
            try manager.copyItem(at: source, to: target)
            try validate(target, bundle: bundle)
            try manager.setAttributes([.posixPermissions: bundle ? 0o700 : 0o600], ofItemAtPath: target.path)
            if bundle {
                for child in try manager.contentsOfDirectory(at: target, includingPropertiesForKeys: nil) {
                    try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: child.path)
                }
            }
            return target
        } catch {
            try? manager.removeItem(at: folder)
            throw error
        }
    }

    private static func makeFolder(cacheDirectory: URL?) throws -> URL {
        let manager = FileManager.default
        let root: URL
        if let cacheDirectory { root = cacheDirectory }
        else {
            root = try manager.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                .appendingPathComponent("anDrop/SharedFiles", isDirectory: true)
        }
        let folder = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return folder
    }
}
