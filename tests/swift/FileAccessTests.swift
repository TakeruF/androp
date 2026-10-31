import Foundation
import Testing
@testable import anDropIdentity

@Test @MainActor func implicitBookmarksShareFilesAndRejectCorruptData() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = folder.appendingPathComponent("共有.txt")
    try Data("fixture".utf8).write(to: file)
    let access = FileAccess()
    defer { access.close() }
    let urls = try access.resolveShared([FileBookmarks.encode(file)])
    #expect(try Data(contentsOf: urls[0]) == Data("fixture".utf8))
    #expect(throws: (any Error).self) { try access.resolveShared([FileBookmarks.encode(file), "corrupt"]) }
    #expect(throws: (any Error).self) { try access.resolveShared([]) }
    access.releaseFiles(except: [])
}

@Test @MainActor func legacyCustomFolderMustBeSelectedAgain() throws {
    let name = "org.androp.tests.destination.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    let access = FileAccess()
    defer { access.close() }
    #expect(try access.restoreDestination(defaults: defaults) == FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0])
    defaults.set("/a/legacy/custom/folder", forKey: "destination")
    #expect(throws: (any Error).self) { try access.restoreDestination(defaults: defaults) }
    defaults.set(Data("corrupt".utf8), forKey: "destinationBookmark")
    #expect(throws: (any Error).self) { try access.restoreDestination(defaults: defaults) }
}
