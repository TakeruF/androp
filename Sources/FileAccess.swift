// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 anDrop contributors
import Foundation

/// Implicit bookmarks transfer grants between running processes. Explicit
/// app-scoped bookmarks restore this app's own grants on a later launch.
nonisolated enum FileBookmarks {
    static func encode(_ url: URL) throws -> String {
        guard url.isFileURL else { throw CocoaError(.fileReadUnsupportedScheme) }
        return try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil).base64EncodedString()
    }

    static func resolve(_ encoded: String) throws -> URL {
        guard encoded.utf8.count <= 131_072, let data = Data(base64Encoded: encoded) else { throw CocoaError(.fileReadCorruptFile) }
        var stale = false
        let url = try URL(resolvingBookmarkData: data, options: [.withoutUI, .withoutMounting], relativeTo: nil, bookmarkDataIsStale: &stale)
        guard url.isFileURL else { url.stopAccessingSecurityScopedResource(); throw CocoaError(.fileReadUnsupportedScheme) }
        return url // Resolving an implicit bookmark starts access automatically.
    }
}

@MainActor
final class FileAccess {
    private var files: [URL: URL] = [:]
    private var destinationScope: URL?

    static func needsDestinationGrant(_ url: URL) -> Bool {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        return url.resolvingSymlinksInPath().path != downloads.resolvingSymlinksInPath().path
    }

    func retain(_ url: URL) {
        guard files[url] == nil else { return }
        if url.startAccessingSecurityScopedResource() { files[url] = url }
    }

    func resolveShared(_ encoded: [String]) throws -> [URL] {
        guard !encoded.isEmpty, encoded.count <= 1000 else { throw CocoaError(.fileReadCorruptFile) }
        var resolved: [URL] = []
        do { for bookmark in encoded { resolved.append(try FileBookmarks.resolve(bookmark)) } }
        catch {
            for url in resolved { url.stopAccessingSecurityScopedResource() }
            throw error
        }
        for url in resolved {
            if files[url] != nil { url.stopAccessingSecurityScopedResource() }
            else { files[url] = url }
        }
        return resolved
    }

    func releaseFiles(except retained: [URL]) {
        let keep = Set(retained)
        for url in Array(files.keys) where !keep.contains(url) {
            files.removeValue(forKey: url)?.stopAccessingSecurityScopedResource()
        }
    }

    func selectDestination(_ url: URL, defaults: UserDefaults = .standard) throws {
        let scoped = url.startAccessingSecurityScopedResource()
        do {
            let data = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
            defaults.set(data, forKey: "destinationBookmark")
            defaults.set(url.path, forKey: "destination")
            destinationScope?.stopAccessingSecurityScopedResource()
            destinationScope = scoped ? url : nil
        } catch {
            if scoped { url.stopAccessingSecurityScopedResource() }
            throw error
        }
    }

    func restoreDestination(defaults: UserDefaults = .standard) throws -> URL {
        if let data = defaults.data(forKey: "destinationBookmark") {
            var stale = false
            let url = try URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI, .withoutMounting], relativeTo: nil, bookmarkDataIsStale: &stale)
            guard url.startAccessingSecurityScopedResource() else { throw CocoaError(.fileReadNoPermission) }
            do {
                if stale { defaults.set(try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil), forKey: "destinationBookmark") }
                destinationScope?.stopAccessingSecurityScopedResource()
                destinationScope = url
                defaults.set(url.path, forKey: "destination")
                return url
            } catch { url.stopAccessingSecurityScopedResource(); throw error }
        }
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        if let path = defaults.string(forKey: "destination"), Self.needsDestinationGrant(URL(fileURLWithPath: path)) {
            // Pre-sandbox custom-folder path strings do not grant access.
            throw CocoaError(.fileReadNoPermission)
        }
        return downloads
    }

    func close() {
        releaseFiles(except: [])
        destinationScope?.stopAccessingSecurityScopedResource()
        destinationScope = nil
    }
}
