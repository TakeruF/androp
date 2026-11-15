// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Testing
import UniformTypeIdentifiers
@testable import anDropProtocol

private final class CallbackProvider: NSItemProvider, @unchecked Sendable {
    let source: URL?
    let data: Data?
    let type: String
    let delayed: Bool
    let legacySource: URL?
    init(source: URL?, data: Data? = nil, type: String = UTType.pdf.identifier, name: String? = nil, delayed: Bool = false, legacySource: URL? = nil) {
        self.source = source; self.data = data; self.type = type; self.delayed = delayed
        self.legacySource = legacySource
        super.init(); suggestedName = name
    }
    override var registeredTypeIdentifiers: [String] { [type] }
    override func loadFileRepresentation(forTypeIdentifier typeIdentifier: String, completionHandler: @escaping @Sendable (URL?, (any Error)?) -> Void) -> Progress {
        let source = source
        let deliver: @Sendable () -> Void = {
            completionHandler(source, source == nil ? CocoaError(.fileReadUnknown) : nil)
            if let source { try? FileManager.default.removeItem(at: source) }
        }
        if delayed { DispatchQueue.global().asyncAfter(deadline: .now() + 0.05, execute: deliver) } else { deliver() }
        return Progress(totalUnitCount: 1)
    }
    override func loadDataRepresentation(forTypeIdentifier typeIdentifier: String, completionHandler: @escaping @Sendable (Data?, (any Error)?) -> Void) -> Progress {
        completionHandler(data, data == nil ? CocoaError(.fileReadUnknown) : nil)
        return Progress(totalUnitCount: 1)
    }
    override func loadItem(forTypeIdentifier typeIdentifier: String, options: [AnyHashable: Any]? = nil, completionHandler: NSItemProvider.CompletionHandler? = nil) {
        completionHandler?(legacySource as NSURL?, legacySource == nil ? CocoaError(.fileReadUnknown) : nil)
        if let legacySource { try? FileManager.default.removeItem(at: legacySource) }
    }
}

private struct ShareFixture {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    init() throws { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
    func file(_ name: String, data: Data) throws -> URL {
        let url = root.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let file = url.appending(path: name); try data.write(to: file); return file
    }
    func provider(_ url: URL) -> NSItemProvider { NSItemProvider(item: url as NSURL, typeIdentifier: UTType.fileURL.identifier) }
}

@Test @MainActor func sharedOriginalURLsWinOverGenericPhotoExports() async throws {
    let fixture = try ShareFixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
    let importer = SharedFileImporter(baseDirectory: fixture.root); defer { importer.cleanup() }
    var providers: [NSItemProvider] = []; var originals: [URL] = []
    for index in 1...4 {
        let original = try fixture.file("original-\(index).jpg", data: Data("photo \(index)".utf8)); originals.append(original)
        let exported = try fixture.file("JPEG image.jpeg", data: Data("export".utf8))
        let provider = fixture.provider(original)
        provider.registerFileRepresentation(forTypeIdentifier: UTType.jpeg.identifier, fileOptions: [], visibility: .all) { completion in completion(exported, false, nil); return nil }
        providers.append(provider)
    }
    let result = try await importer.load(providers)
    #expect(result.files.map(\.lastPathComponent) == originals.map(\.lastPathComponent))
    for (original, copy) in zip(originals, result.files) { #expect(try Data(contentsOf: original) == Data(contentsOf: copy)) }
    #expect(try await FileArchive.prepare(result.files).count == 4)
}

@Test @MainActor func copiesTemporaryFileBeforeProviderCallbackEnds() async throws {
    let fixture = try ShareFixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
    let bytes = Data("temporary fixture".utf8); let source = try fixture.file("temporary.pdf", data: bytes)
    let importer = SharedFileImporter(baseDirectory: fixture.root); defer { importer.cleanup() }
    let result = try await importer.load([CallbackProvider(source: source)])
    #expect(!FileManager.default.fileExists(atPath: source.path))
    #expect(try Data(contentsOf: result.files[0]) == bytes)
}

@Test @MainActor func sharedImagesUseProviderSuggestedNamesForDataFallback() async throws {
    let fixture = try ShareFixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
    let importer = SharedFileImporter(baseDirectory: fixture.root); defer { importer.cleanup() }
    let result = try await importer.load([CallbackProvider(source: nil, data: Data([1,2,3]), type: UTType.png.identifier, name: "元の写真")])
    #expect(result.files[0].lastPathComponent == "元の写真.png")
    #expect(try Data(contentsOf: result.files[0]) == Data([1,2,3]))
    let second = SharedFileImporter(baseDirectory: fixture.root); defer { second.cleanup() }
    let exported = try await second.load([CallbackProvider(source: nil, data: Data([4,5,6]), type: UTType.png.identifier, name: "converted.jpg")])
    #expect(exported.files[0].lastPathComponent == "converted.png")
}

@Test @MainActor func duplicateShareNamesChangeOnlyPrivateCopies() async throws {
    let fixture = try ShareFixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
    let first = try fixture.file("photo.jpg", data: Data([1])); let second = try fixture.file("photo.jpg", data: Data([2]))
    let importer = SharedFileImporter(baseDirectory: fixture.root); defer { importer.cleanup() }
    let result = try await importer.load([fixture.provider(first), fixture.provider(second)])
    #expect(result.files.map(\.lastPathComponent) == ["photo.jpg", "photo (1).jpg"])
    #expect(try Data(contentsOf: first) == Data([1]) && Data(contentsOf: second) == Data([2]))
    #expect(try Data(contentsOf: result.files[0]) == Data([1]) && Data(contentsOf: result.files[1]) == Data([2]))
}

@Test @MainActor func oversizedSharesCleanUpWithoutChangingSources() async throws {
    let fixture = try ShareFixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
    let source = try fixture.file("oversized.bin", data: Data())
    let handle = try FileHandle(forWritingTo: source); try handle.truncate(atOffset: UInt64(Limits.bytes + 1)); try handle.close()
    let importer = SharedFileImporter(baseDirectory: fixture.root)
    await #expect(throws: SharedImportError.oversized) { try await importer.load([fixture.provider(source)]) }
    #expect(!FileManager.default.fileExists(atPath: importer.directory.path))
    #expect(FileManager.default.fileExists(atPath: source.path))
    let many = SharedFileImporter(baseDirectory: fixture.root)
    await #expect(throws: SharedImportError.tooManyFiles) { try await many.load(Array(repeating: fixture.provider(source), count: 17)) }
}

@Test @MainActor func directURLsTextAndLinksAreNotTurnedIntoFiles() async throws {
    let fixture = try ShareFixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
    for provider in [NSItemProvider(item: URL(string: "https://example.com/")! as NSURL, typeIdentifier: UTType.url.identifier), NSItemProvider(object: "fixture text" as NSString)] {
        let importer = SharedFileImporter(baseDirectory: fixture.root)
        await #expect(throws: SharedImportError.unsupported) { try await importer.load([provider]) }
        #expect(!FileManager.default.fileExists(atPath: importer.directory.path))
    }
    let source = try fixture.file("real.txt", data: Data([1]))
    let link = fixture.root.appending(path: "link.txt"); try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
    let importer = SharedFileImporter(baseDirectory: fixture.root)
    await #expect(throws: SharedImportError.unsupported) { try await importer.load([fixture.provider(link)]) }
}

@Test @MainActor func cancelledShareCannotRecreateItsTemporaryDirectory() async throws {
    let fixture = try ShareFixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
    let source = try fixture.file("delayed.pdf", data: Data([1,2,3]))
    let importer = SharedFileImporter(baseDirectory: fixture.root)
    let job = Task { try await importer.load([CallbackProvider(source: source, delayed: true)]) }
    try await Task.sleep(for: .milliseconds(10)); job.cancel(); importer.cleanup()
    await #expect(throws: CancellationError.self) { try await job.value }
    #expect(!FileManager.default.fileExists(atPath: importer.directory.path))
}

@Test @MainActor func emptySharedFilesArePreserved() async throws {
    let fixture = try ShareFixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
    let source = try fixture.file("empty.txt", data: Data())
    let importer = SharedFileImporter(baseDirectory: fixture.root); defer { importer.cleanup() }
    let result = try await importer.load([fixture.provider(source)])
    #expect(result.totalBytes == 0 && result.files.count == 1)
    #expect(try Data(contentsOf: result.files[0]).isEmpty)
}

@Test @MainActor func aggregateSharedSizeIsBounded() async throws {
    let fixture = try ShareFixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
    var providers: [NSItemProvider] = []
    for index in 0..<3 {
        let file = try fixture.file("file-\(index).bin", data: Data())
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: UInt64(index < 2 ? Limits.bytes / 2 : 1)); try handle.close()
        providers.append(fixture.provider(file))
    }
    let importer = SharedFileImporter(baseDirectory: fixture.root)
    await #expect(throws: SharedImportError.oversized) { try await importer.load(providers) }
    #expect(!FileManager.default.fileExists(atPath: importer.directory.path))
}

@Test @MainActor func shareCreatesMissingTemporaryRoot() async throws {
    let fixture = try ShareFixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
    let source = try fixture.file("original.pdf", data: Data([1,2,3]))
    let root = fixture.root.appending(path: "missing/tmp", directoryHint: .isDirectory)
    let importer = SharedFileImporter(baseDirectory: root); defer { importer.cleanup() }
    let result = try await importer.load([fixture.provider(source)])
    #expect(try Data(contentsOf: result.files[0]) == Data([1,2,3]))
}

@Test @MainActor func legacyMediaItemIsCopiedWhileCallbackIsValid() async throws {
    let fixture = try ShareFixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
    let source = try fixture.file("legacy-photo.jpg", data: Data([1,2,3]))
    let importer = SharedFileImporter(baseDirectory: fixture.root); defer { importer.cleanup() }
    let result = try await importer.load([CallbackProvider(source: nil, type: UTType.jpeg.identifier, legacySource: source)])
    #expect(result.files[0].lastPathComponent == "legacy-photo.jpg")
    #expect(try Data(contentsOf: result.files[0]) == Data([1,2,3]))
    #expect(!FileManager.default.fileExists(atPath: source.path))
}

@Test func shareImportDiagnosticsExcludeNamesPathsAndErrorDescriptions() {
    let secret = "private-photo-name-and-path"
    let error = NSError(domain: NSCocoaErrorDomain, code: 257, userInfo: [NSFilePathErrorKey: secret, NSLocalizedDescriptionKey: secret])
    let detail = SharedImportDiagnostic(phase: .fileCopy, outcome: .failed, type: UTType.jpeg.identifier, error: error)
    #expect(detail.fields == ["phase": "fileCopy", "outcome": "failed", "type": "public.jpeg", "error_domain": NSCocoaErrorDomain, "error_code": "257"])
    let custom = SharedImportDiagnostic(phase: .legacyItem, outcome: .unavailable, type: secret, error: NSError(domain: secret, code: 1))
    #expect(custom.fields["type"] == "other" && custom.fields["error_domain"] == "other")
    #expect(!custom.fields.values.contains(where: { $0.contains(secret) }))
}
