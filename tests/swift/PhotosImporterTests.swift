// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 anDrop contributors

import Foundation
import Photos
import Testing
@testable import anDropIdentity

private struct LivePhotoPackageFixture {
    let folder: URL
    let package: URL
    let image: URL
    let video: URL

    init() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("anDrop-import-test-" + UUID().uuidString)
        package = folder.appendingPathComponent("received.pvt", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        let stem = "anDrop-" + UUID().uuidString
        image = package.appendingPathComponent(stem + ".jpg")
        video = package.appendingPathComponent(stem + ".mov")
        // The converter's identity/PhotoKit validation is tested separately.
        // The importer tests exercise planning and orchestration with inert data.
        try Data("synthetic still".utf8).write(to: image)
        try Data("synthetic movie".utf8).write(to: video)
        let metadata = try PropertyListSerialization.data(fromPropertyList: ["PFVideoComplementMetadataVersionKey": "1"],
                                                          format: .binary, options: 0)
        try metadata.write(to: package.appendingPathComponent("metadata.plist"))
    }

    var entry: [String: Any] { ["kind": "live_photo", "path": package.path] }

    func remove() { try? FileManager.default.removeItem(at: folder) }
}

private struct ReceivedMediaFixture {
    let folder: URL
    let image: URL
    let video: URL
    let pdf: URL

    init() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("anDrop-media-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        image = folder.appendingPathComponent("picture.JPG")
        video = folder.appendingPathComponent("movie.mp4")
        pdf = folder.appendingPathComponent("document.pdf")
        for url in [image, video, pdf] { try Data("inert test resource".utf8).write(to: url) }
    }

    var entries: [[String: Any]] { [image, pdf, video].map { ["path": $0.path] } }
    func remove() { try? FileManager.default.removeItem(at: folder) }
}

@Test @MainActor func disabledImportNeverRequestsPhotosAccess() async throws {
    let fixture = try ReceivedMediaFixture()
    defer { fixture.remove() }
    var calls = 0
    let dependencies = PhotosImporter.Dependencies(authorize: { calls += 1; return .authorized },
        create: { _ in calls += 1 })
    let result = try await PhotosImporter.importReceived(files: fixture.entries, enabled: false, using: dependencies)
    #expect(result == PhotosImporter.Result())
    #expect(calls == 0)
}

@Test @MainActor func nonMediaFilesNeverRequestPhotosAccess() async throws {
    var calls = 0
    let dependencies = PhotosImporter.Dependencies(authorize: { calls += 1; return .authorized },
        create: { _ in calls += 1 })
    let result = try await PhotosImporter.importReceived(files: [
        ["path": "/nonexistent/document.pdf"], ["path": "/nonexistent/archive.zip"],
        ["path": "/nonexistent/sound.mp3"], ["path": "/nonexistent/vector.svg"],
        ["path": "/nonexistent/untrusted.pvt"], ["path": "relative.jpg"], ["path": "/bad\0.jpg"]
    ], enabled: true, using: dependencies)
    #expect(result == PhotosImporter.Result())
    #expect(calls == 0)
}

@Test @MainActor func mixedBatchImportsPicturesAndVideosWhilePreservingEveryOriginal() async throws {
    let fixture = try ReceivedMediaFixture()
    defer { fixture.remove() }
    var plans: [PhotosImporter.Plan] = []
    var permissions = 0
    let dependencies = PhotosImporter.Dependencies(authorize: { permissions += 1; return .authorized },
        create: { plans.append($0) })
    let result = try await PhotosImporter.importReceived(files: fixture.entries + fixture.entries,
                                                         enabled: true, using: dependencies)
    #expect(result == PhotosImporter.Result(importedCount: 2))
    #expect(permissions == 1)
    #expect(plans.map(\.resources).map { $0.map(\.kind) } == [[.photo], [.video]])
    #expect(plans.map(\.source) == [fixture.image, fixture.video].map { $0.resolvingSymlinksInPath() })
    for url in [fixture.image, fixture.video, fixture.pdf] {
        #expect(try Data(contentsOf: url) == Data("inert test resource".utf8))
    }
}

@Test @MainActor func convertedMotionPhotoImportsOneLiveAssetWithoutAnExtraStill() async throws {
    let fixture = try LivePhotoPackageFixture()
    defer { fixture.remove() }
    let original = fixture.folder.appendingPathComponent("motion.jpg")
    try Data("original motion photo".utf8).write(to: original)
    var entry = fixture.entry
    entry["original_path"] = original.path
    var plans: [PhotosImporter.Plan] = []
    let dependencies = PhotosImporter.Dependencies(authorize: { .authorized }, create: { plans.append($0) })
    let result = try await PhotosImporter.importReceived(files: [["path": original.path], entry, entry],
                                                         enabled: true, using: dependencies)
    #expect(result == PhotosImporter.Result(importedCount: 1))
    let plan = try #require(plans.first)
    #expect(plans.count == 1)
    #expect(plan.source == fixture.package.resolvingSymlinksInPath())
    #expect(plan.resources.map(\.kind) == [.photo, .pairedVideo])
    #expect(plan.resources.map(\.url) == [fixture.image, fixture.video].map { $0.resolvingSymlinksInPath() })
    #expect(try Data(contentsOf: original) == Data("original motion photo".utf8))
}

@Test(arguments: [PHAuthorizationStatus.denied, .restricted, .notDetermined])
@MainActor func photosPermissionFailurePreservesSourcesAndDoesNotImport(_ status: PHAuthorizationStatus) async throws {
    let fixture = try ReceivedMediaFixture()
    defer { fixture.remove() }
    var writes = 0
    let dependencies = PhotosImporter.Dependencies(authorize: { status }, create: { _ in writes += 1 })
    await #expect(throws: PhotosImporter.Failure.permissionDenied) {
        try await PhotosImporter.importReceived(files: fixture.entries, enabled: true, using: dependencies)
    }
    #expect(writes == 0)
    #expect(FileManager.default.fileExists(atPath: fixture.image.path))
    #expect(FileManager.default.fileExists(atPath: fixture.video.path))
}

@Test @MainActor func anUnsupportedAssetDoesNotPreventImportingRemainingMedia() async throws {
    let fixture = try ReceivedMediaFixture()
    defer { fixture.remove() }
    var writes: [URL] = []
    let dependencies = PhotosImporter.Dependencies(authorize: { .authorized }, create: { plan in
        writes.append(plan.source)
        if plan.resources.first?.kind == .photo { throw CocoaError(.fileReadCorruptFile) }
    })
    let result = try await PhotosImporter.importReceived(files: fixture.entries, enabled: true, using: dependencies)
    #expect(result == PhotosImporter.Result(importedCount: 1, failedCount: 1))
    #expect(writes.count == 2)
    #expect(try Data(contentsOf: fixture.image) == Data("inert test resource".utf8))
}

@Test @MainActor func invalidLivePackageDoesNotBlockAnOrdinaryPhoto() async throws {
    let fixture = try ReceivedMediaFixture()
    defer { fixture.remove() }
    let badPackage: [String: Any] = ["path": fixture.folder.appendingPathComponent("bad.pvt").path,
                                    "kind": "live_photo", "original_path": fixture.image.path]
    var writes: [URL] = []
    let dependencies = PhotosImporter.Dependencies(authorize: { .limited }, create: { writes.append($0.source) })
    let result = try await PhotosImporter.importReceived(files: [badPackage, ["path": fixture.image.path]],
                                                         enabled: true, using: dependencies)
    #expect(result == PhotosImporter.Result(importedCount: 1, failedCount: 1))
    #expect(writes == [fixture.image.resolvingSymlinksInPath()])
}

@Test @MainActor func receivedDirectoriesAndSymlinksAreNotImported() async throws {
    let fixture = try ReceivedMediaFixture()
    defer { fixture.remove() }
    let link = fixture.folder.appendingPathComponent("alias.jpg")
    let directory = fixture.folder.appendingPathComponent("folder.mp4")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture.image)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    var calls = 0
    let dependencies = PhotosImporter.Dependencies(authorize: { calls += 1; return .authorized },
        create: { _ in calls += 1 })
    let result = try await PhotosImporter.importReceived(files: [["path": link.path], ["path": directory.path]],
                                                         enabled: true, using: dependencies)
    #expect(result == PhotosImporter.Result(failedCount: 2))
    #expect(calls == 0)
}

@Test @MainActor func switchingOffFinishesTheCurrentAssetAndStopsTheRemainingBatch() async throws {
    let fixture = try ReceivedMediaFixture()
    defer { fixture.remove() }
    var enabled = true
    var writes: [URL] = []
    var states: [PhotosImporter.Progress] = []
    let dependencies = PhotosImporter.Dependencies(authorize: { .authorized }, create: { plan in
        writes.append(plan.source)
        enabled = false
    })
    let result = try await PhotosImporter.importReceived(files: fixture.entries, enabled: true, using: dependencies,
        shouldContinue: { enabled }, progress: { states.append($0) })
    #expect(result == PhotosImporter.Result(importedCount: 1, remainingCount: 1, wasStopped: true))
    #expect(writes == [fixture.image.resolvingSymlinksInPath()])
    let stopped = try #require(states.last)
    #expect(stopped.phase == .stopped && stopped.importedCount == 1 && stopped.totalCount == 2)
    #expect(stopped.fraction == 0.5)
    #expect(FileManager.default.fileExists(atPath: fixture.video.path))
}

@Test @MainActor func stoppingWhileAuthorizationIsPendingNeverStartsAnAsset() async throws {
    let fixture = try ReceivedMediaFixture()
    defer { fixture.remove() }
    var enabled = true
    var writes = 0
    let dependencies = PhotosImporter.Dependencies(authorize: { enabled = false; return .authorized },
        create: { _ in writes += 1 })
    let result = try await PhotosImporter.importReceived(files: fixture.entries, enabled: true, using: dependencies,
                                                         shouldContinue: { enabled })
    #expect(result == PhotosImporter.Result(remainingCount: 2, wasStopped: true))
    #expect(writes == 0)
}

@Test @MainActor func importProgressCountsFailuresWithoutClaimingThatEveryAssetWasAdded() async throws {
    let fixture = try ReceivedMediaFixture()
    defer { fixture.remove() }
    var states: [PhotosImporter.Progress] = []
    let dependencies = PhotosImporter.Dependencies(authorize: { .authorized }, create: { plan in
        if plan.resources.first?.kind == .photo { throw CocoaError(.fileReadCorruptFile) }
    })
    let result = try await PhotosImporter.importReceived(files: fixture.entries, enabled: true, using: dependencies,
                                                         progress: { states.append($0) })
    #expect(result == PhotosImporter.Result(importedCount: 1, failedCount: 1))
    #expect(states.map(\.processedCount) == [0, 1, 2, 2])
    let final = try #require(states.last)
    #expect(final.phase == .finished && !final.active && final.fraction == 1)
    #expect(final.label(chinese: false) == "Photos · 1 added, 1 failed")
    #expect(try JSONDecoder().decode(PhotosImporter.Progress.self, from: JSONEncoder().encode(final)) == final)
}

private enum InvalidLivePhotoResource: CaseIterable {
    case missingVideo, extraFile, unrelatedStem, nonGeneratedBasename, resourceSymlink, packageSymlink, invalidMetadata
}

@Test(arguments: InvalidLivePhotoResource.allCases)
@MainActor private func malformedPackagesFailBeforeRequestingPhotosAccess(_ failure: InvalidLivePhotoResource) async throws {
    let fixture = try LivePhotoPackageFixture()
    defer { fixture.remove() }
    var entry = fixture.entry
    switch failure {
    case .missingVideo:
        try FileManager.default.removeItem(at: fixture.video)
    case .extraFile:
        try Data("extra".utf8).write(to: fixture.package.appendingPathComponent("extra.jpg"))
    case .unrelatedStem:
        try FileManager.default.moveItem(at: fixture.video,
            to: fixture.package.appendingPathComponent("anDrop-" + UUID().uuidString + ".mov"))
    case .nonGeneratedBasename:
        try FileManager.default.moveItem(at: fixture.image, to: fixture.package.appendingPathComponent("arbitrary.jpg"))
        try FileManager.default.moveItem(at: fixture.video, to: fixture.package.appendingPathComponent("arbitrary.mov"))
    case .resourceSymlink:
        let outside = fixture.folder.appendingPathComponent("outside.mov")
        try Data("outside".utf8).write(to: outside)
        try FileManager.default.removeItem(at: fixture.video)
        try FileManager.default.createSymbolicLink(at: fixture.video, withDestinationURL: outside)
    case .packageSymlink:
        let alias = fixture.folder.appendingPathComponent("alias.pvt")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.package)
        entry["path"] = alias.path
    case .invalidMetadata:
        try Data("invalid".utf8).write(to: fixture.package.appendingPathComponent("metadata.plist"))
    }
    #expect(throws: PhotosImporter.Failure.invalidPackage) {
        try PhotosImporter.livePhotoPlans(for: [entry])
    }
}
