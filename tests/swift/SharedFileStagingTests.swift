import Foundation
import Testing
import UniformTypeIdentifiers
@testable import anDropIdentity

// Reproduce the observed Photos failure at the modern export boundary, while
// using Foundation's real legacy item/data loading for the alternatives.
nonisolated private final class NoExportPhotoProvider: NSItemProvider, @unchecked Sendable {
    override func loadFileRepresentation(forTypeIdentifier typeIdentifier: String,
                                        completionHandler: @escaping @Sendable (URL?, (any Error)?) -> Void) -> Progress {
        completionHandler(nil, NSError(domain: NSItemProvider.errorDomain, code: -1000))
        return Progress(totalUnitCount: 0)
    }
}

// Finder can export each JPEG as "JPEG image.jpeg", even while its file-URL
// representation points to the original, distinctly named file.
nonisolated private final class GenericExportPhotoProvider: NSItemProvider, @unchecked Sendable {
    private let exportedFile: URL

    init(exportedFile: URL) {
        self.exportedFile = exportedFile
        super.init()
        registerDataRepresentation(forTypeIdentifier: UTType.jpeg.identifier, visibility: .all) { completion in
            completion(nil, CocoaError(.fileReadUnknown)); return nil
        }
    }

    override func loadFileRepresentation(forTypeIdentifier typeIdentifier: String,
                                        completionHandler: @escaping @Sendable (URL?, (any Error)?) -> Void) -> Progress {
        completionHandler(exportedFile, nil)
        return Progress(totalUnitCount: 0)
    }
}

@Test func sharedFinderBatchKeepsOriginalNamesWhenImageExportUsesGenericName() async throws {
    let manager = FileManager.default
    let root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try manager.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? manager.removeItem(at: root) }
    let exported = root.appendingPathComponent("JPEG image.jpeg")
    let names = ["line_oa_chat_261113_082729.jpg", "line_oa_chat_261113_082733.jpg",
                 "line_oa_chat_261113_082735.jpg", "line_oa_chat_261113_082737.jpg"]
    var stagedFiles: [URL] = []
    for (index, name) in names.enumerated() {
        let source = root.appendingPathComponent(name)
        let bytes = Data([0xff, 0xd8, UInt8(index), 0xff, 0xd9])
        try bytes.write(to: source)
        try bytes.write(to: exported)
        let provider = GenericExportPhotoProvider(exportedFile: exported)
        if index.isMultiple(of: 2) {
            provider.registerItem(forTypeIdentifier: UTType.fileURL.identifier, loadHandler: { completion, _, _ in completion?(source as NSURL, nil) })
        } else {
            let encodedURL = source.dataRepresentation
            provider.registerDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier, visibility: .all) { completion in
                completion(encodedURL, nil); return nil
            }
        }
        let staged = try await SharedFileStaging.loadFile(from: provider, cacheDirectory: root.appendingPathComponent("cache"))
        try manager.removeItem(at: source)
        #expect(staged.lastPathComponent == name)
        #expect(try Data(contentsOf: staged) == bytes)
        stagedFiles.append(staged)
    }
    #expect(Set(stagedFiles.map { $0.lastPathComponent.lowercased() }).count == names.count)
}

@Test func sharedPhotoFallsBackToImageExportWhenOriginalURLIsUnavailable() async throws {
    let manager = FileManager.default
    let root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try manager.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? manager.removeItem(at: root) }
    let exported = root.appendingPathComponent("exported.jpeg")
    let bytes = Data([0xff, 0xd8, 0xff, 0xd9])
    try bytes.write(to: exported)
    let provider = GenericExportPhotoProvider(exportedFile: exported)
    let unavailable = root.appendingPathComponent("unavailable.jpg")
    provider.registerItem(forTypeIdentifier: UTType.fileURL.identifier, loadHandler: { completion, _, _ in completion?(unavailable as NSURL, nil) })
    let staged = try await SharedFileStaging.loadFile(from: provider, cacheDirectory: root.appendingPathComponent("cache"))
    try manager.removeItem(at: exported)
    #expect(staged.lastPathComponent == "exported.jpeg")
    #expect(try Data(contentsOf: staged) == bytes)
}

@Test func sharedPhotoFallsBackToLegacyURLWhenFileExportFails() async throws {
    let manager = FileManager.default
    let root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try manager.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? manager.removeItem(at: root) }
    let source = root.appendingPathComponent("legacy.jpeg")
    let bytes = Data([0xff, 0xd8, 0xff, 0xd9])
    try bytes.write(to: source)
    let provider = NoExportPhotoProvider()
    provider.registerDataRepresentation(forTypeIdentifier: UTType.jpeg.identifier, visibility: .all) { completion in
        completion(nil, NSError(domain: NSItemProvider.errorDomain, code: -1)); return nil
    }
    provider.registerItem(forTypeIdentifier: UTType.fileURL.identifier, loadHandler: { completion, _, _ in completion?(source as NSURL, nil) })
    let staged = try await SharedFileStaging.loadFile(from: provider, cacheDirectory: root.appendingPathComponent("cache"))
    try manager.removeItem(at: source)
    #expect(staged.lastPathComponent == "legacy.jpeg")
    #expect(try Data(contentsOf: staged) == bytes)
}

@Test func sharedPhotoFallsBackToEncodedDataWhenFileExportFails() async throws {
    let manager = FileManager.default
    let root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? manager.removeItem(at: root) }
    let bytes = Data([0xff, 0xd8, 0xff, 0xd9])
    let provider = NoExportPhotoProvider()
    provider.suggestedName = "写真.jpeg"
    provider.registerDataRepresentation(forTypeIdentifier: UTType.jpeg.identifier, visibility: .all) { completion in
        completion(bytes, nil); return nil
    }
    let staged = try await SharedFileStaging.loadFile(from: provider, cacheDirectory: root)
    #expect(staged.lastPathComponent == "写真.jpeg")
    #expect(try Data(contentsOf: staged) == bytes)
}

@Test func sharedPhotoLoaderRejectsDirectTextAndWebLinks() async {
    let provider = NSItemProvider(item: "https://example.invalid/" as NSString, typeIdentifier: UTType.plainText.identifier)
    await #expect(throws: (any Error).self) { try await SharedFileStaging.loadFile(from: provider) }
}

@Test func sharedPhotoProviderCopiesInsideItsFileCallback() async throws {
    let manager = FileManager.default
    let root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try manager.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? manager.removeItem(at: root) }
    let source = root.appendingPathComponent("provider.jpeg")
    let bytes = Data([0xff, 0xd8, 0xff, 0xd9])
    try bytes.write(to: source)
    let provider = NSItemProvider()
    provider.registerFileRepresentation(forTypeIdentifier: UTType.jpeg.identifier, fileOptions: [], visibility: .all) { completion in
        completion(source, false, nil)
        return nil
    }
    let staged: URL = try await withCheckedThrowingContinuation { continuation in
        provider.loadFileRepresentation(forTypeIdentifier: UTType.jpeg.identifier) { url, error in
            do {
                guard let url else { throw error ?? CocoaError(.fileReadUnknown) }
                continuation.resume(returning: try SharedFileStaging.copyFile(url, cacheDirectory: root.appendingPathComponent("cache")))
            } catch { continuation.resume(throwing: error) }
        }
    }
    try manager.removeItem(at: source)
    #expect(try Data(contentsOf: staged) == bytes)
}

@Test func sharedPhotoCopySurvivesProviderCleanup() throws {
    let manager = FileManager.default
    let root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try manager.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? manager.removeItem(at: root) }
    let source = root.appendingPathComponent("写真.jpeg")
    let bytes = Data([0xff, 0xd8, 0xff, 0xd9])
    try bytes.write(to: source)
    let cache = root.appendingPathComponent("cache")
    let staged = try SharedFileStaging.copyFile(source, cacheDirectory: cache)
    let duplicate = try SharedFileStaging.copyFile(source, cacheDirectory: cache)
    try manager.removeItem(at: source)
    #expect(staged.lastPathComponent == "写真.jpeg")
    #expect(staged != duplicate)
    #expect(try Data(contentsOf: staged) == bytes)
    #expect(try Data(contentsOf: duplicate) == bytes)
    let attributes = try manager.attributesOfItem(atPath: staged.path)
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
}

@Test func sharedPhotoStagingRejectsLinksAndKeepsLivePhotoResources() throws {
    let manager = FileManager.default
    let root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try manager.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? manager.removeItem(at: root) }
    let cache = root.appendingPathComponent("cache")
    let bundle = root.appendingPathComponent("source.pvt")
    try manager.createDirectory(at: bundle, withIntermediateDirectories: true)
    let image = bundle.appendingPathComponent("image.jpg")
    let video = bundle.appendingPathComponent("video.mov")
    try Data([1, 2]).write(to: image)
    try Data([3, 4]).write(to: video)
    let link = root.appendingPathComponent("link.jpg")
    try manager.createSymbolicLink(at: link, withDestinationURL: image)
    #expect(throws: (any Error).self) { try SharedFileStaging.copyFile(link, cacheDirectory: cache) }
    #expect(throws: (any Error).self) { try SharedFileStaging.copyFile(bundle, cacheDirectory: cache) }
    let staged = try SharedFileStaging.copyLivePhoto(bundle, cacheDirectory: cache)
    try manager.removeItem(at: bundle)
    #expect(staged.pathExtension == "pvt")
    #expect(try Data(contentsOf: staged.appendingPathComponent("image.jpg")) == Data([1, 2]))
    #expect(try Data(contentsOf: staged.appendingPathComponent("video.mov")) == Data([3, 4]))
}
