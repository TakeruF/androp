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

@Test @MainActor func ordinaryReceivedFilesNeverAccessPhotos() async throws {
    var calls = 0
    let dependencies = LivePhotoImporter.Dependencies(authorize: { calls += 1; return .authorized },
        create: { _ in calls += 1 }, open: { calls += 1 })
    let imported = try await LivePhotoImporter.importAndOpen(files: [
        ["path": "/nonexistent/ordinary.jpg"],
        ["path": "/nonexistent/untrusted.pvt"],
        ["kind": "photo", "path": "/nonexistent/ordinary.heic"]
    ], using: dependencies)
    #expect(!imported)
    #expect(calls == 0)
}

@Test @MainActor func livePhotoImportsOneAssetWithTwoResourcesThenOpensPhotos() async throws {
    let fixture = try LivePhotoPackageFixture()
    defer { fixture.remove() }
    var events: [String] = []
    var importedPlans: [LivePhotoImporter.Plan] = []
    let dependencies = LivePhotoImporter.Dependencies(authorize: { events.append("permission"); return .authorized },
        create: { plans in events.append("create"); importedPlans = plans }, open: { events.append("open") })
    let imported = try await LivePhotoImporter.importAndOpen(files: [fixture.entry, fixture.entry], using: dependencies)
    #expect(imported)
    #expect(events == ["permission", "create", "open"])
    #expect(importedPlans.count == 1)
    let plan = try #require(importedPlans.first)
    #expect(plan.package == fixture.package.resolvingSymlinksInPath())
    #expect(plan.resources.map(\.kind) == [.photo, .pairedVideo])
    #expect(plan.resources.map(\.url) == [fixture.image.resolvingSymlinksInPath(), fixture.video.resolvingSymlinksInPath()])
    #expect(try Data(contentsOf: fixture.image) == Data("synthetic still".utf8))
    #expect(try Data(contentsOf: fixture.video) == Data("synthetic movie".utf8))
}

@Test(arguments: [PHAuthorizationStatus.denied, .restricted, .notDetermined])
@MainActor func photosPermissionFailurePreservesSourcesAndDoesNotImport(_ status: PHAuthorizationStatus) async throws {
    let fixture = try LivePhotoPackageFixture()
    defer { fixture.remove() }
    var writes = 0
    var opens = 0
    let dependencies = LivePhotoImporter.Dependencies(authorize: { status }, create: { _ in writes += 1 }, open: { opens += 1 })
    await #expect(throws: LivePhotoImporter.Failure.permissionDenied) {
        try await LivePhotoImporter.importAndOpen(files: [fixture.entry], using: dependencies)
    }
    #expect(writes == 0 && opens == 0)
    #expect(FileManager.default.fileExists(atPath: fixture.image.path))
    #expect(FileManager.default.fileExists(atPath: fixture.video.path))
}

@Test @MainActor func photosWriteFailureDoesNotOpenPhotosOrRemoveSources() async throws {
    let fixture = try LivePhotoPackageFixture()
    defer { fixture.remove() }
    var opens = 0
    let dependencies = LivePhotoImporter.Dependencies(authorize: { .authorized },
        create: { _ in throw CocoaError(.fileWriteUnknown) }, open: { opens += 1 })
    await #expect(throws: LivePhotoImporter.Failure.importFailed) {
        try await LivePhotoImporter.importAndOpen(files: [fixture.entry], using: dependencies)
    }
    #expect(opens == 0)
    #expect(try Data(contentsOf: fixture.image) == Data("synthetic still".utf8))
    #expect(try Data(contentsOf: fixture.video) == Data("synthetic movie".utf8))
}

@Test @MainActor func photosOpenFailureKeepsSuccessfulImportDistinct() async throws {
    let fixture = try LivePhotoPackageFixture()
    defer { fixture.remove() }
    var writes = 0
    let dependencies = LivePhotoImporter.Dependencies(authorize: { .authorized }, create: { _ in writes += 1 },
        open: { throw CocoaError(.featureUnsupported) })
    await #expect(throws: LivePhotoImporter.Failure.openFailed) {
        try await LivePhotoImporter.importAndOpen(files: [fixture.entry], using: dependencies)
    }
    #expect(writes == 1)
    #expect(FileManager.default.fileExists(atPath: fixture.package.path))
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
    var systemCalls = 0
    let dependencies = LivePhotoImporter.Dependencies(authorize: { systemCalls += 1; return .authorized },
        create: { _ in systemCalls += 1 }, open: { systemCalls += 1 })
    await #expect(throws: LivePhotoImporter.Failure.invalidPackage) {
        try await LivePhotoImporter.importAndOpen(files: [entry], using: dependencies)
    }
    #expect(systemCalls == 0)
}
