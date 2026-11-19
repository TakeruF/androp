// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 anDrop contributors
// Appended to the isolated production host by test_outgoing_selection.py.

extension AppModel {
    func exercisePhotosImport() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let image = folder.appendingPathComponent("received.jpg")
        let video = folder.appendingPathComponent("received.mov")
        let pdf = folder.appendingPathComponent("document.pdf")
        for url in [image, video, pdf] { try Data("import fixture".utf8).write(to: url) }
        let files = [image, pdf, video].map { ["path": $0.path] }
        var permissions = 0
        var imported: [URL] = []
        photosImportDependencies = PhotosImporter.Dependencies(authorize: { permissions += 1; return .authorized },
            create: { plan in
                await Task.yield()
                imported.append(plan.source)
            })
        precondition(!autoImportToPhotos, "Automatic import defaults to off")
        updateTransfer(["id": "photos-disabled", "direction": "receive", "state": "complete", "files": files])
        precondition(photosImportTask == nil && permissions == 0)

        changeAutoImportToPhotos(true)
        precondition(AppModel().autoImportToPhotos, "The setting survives a new model")
        for (id, direction, state) in [("photos-sent", "send", "complete"),
                                       ("photos-failed", "receive", "failed"),
                                       ("photos-cancelled", "receive", "cancelled")] {
            updateTransfer(["id": id, "direction": direction, "state": state, "files": files])
        }
        precondition(photosImportTask == nil, "Only successful receives can import")

        let completion: [String: Any] = ["id": "photos-received", "direction": "receive", "state": "complete", "files": files]
        updateTransfer(completion)
        precondition(busy, "Updates and destination changes wait for Photos import")
        updateTransfer(completion)
        await photosImportTask?.value
        precondition(permissions == 1 && imported == [image, video].map { $0.resolvingSymlinksInPath() },
                     "A repeated completion event must not import twice")
        precondition(!busy && pendingPhotosImports == 0)
        precondition(transfers.first { $0.id == "photos-received" }?.paths == files.compactMap { $0["path"] })

        // Turning the setting off before queued work starts avoids library access.
        updateTransfer(["id": "photos-queued", "direction": "receive", "state": "complete", "files": files])
        changeAutoImportToPhotos(false)
        await photosImportTask?.value
        precondition(permissions == 1 && imported.count == 2 && !busy)
        precondition(!AppModel().autoImportToPhotos)

        changeAutoImportToPhotos(true)
        photosImportDependencies = PhotosImporter.Dependencies(authorize: { .denied }, create: { _ in
            preconditionFailure("A denied permission must not write to Photos")
        })
        updateTransfer(["id": "photos-denied", "direction": "receive", "state": "complete", "files": files])
        await photosImportTask?.value
        precondition(transfers.first { $0.id == "photos-denied" }?.state == "complete",
                     "Photos permission failure must not turn a successful receive into a failure")
        precondition(selectionTestNotifications.contains { $0 == ("photos-denied", "photos-import-failed") })
        precondition(FileManager.default.fileExists(atPath: pdf.path) && FileManager.default.fileExists(atPath: image.path))
        changeAutoImportToPhotos(false)
        print("Photos import integration scenarios passed")
    }
}

Task { @MainActor in
    do {
        try await AppModel().exercisePhotosImport()
        exit(0)
    } catch {
        fatalError("Photos import integration failed: \(error)")
    }
}
RunLoop.main.run()
