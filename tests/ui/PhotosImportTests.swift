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
        var allowed = false
        var permissions = 0
        var imported: [URL] = []
        photosImportDependencies = PhotosImporter.Dependencies(authorize: {
            permissions += 1
            return allowed ? .authorized : .denied
        }, create: { plan in
            await Task.yield()
            imported.append(plan.source)
        }, status: { allowed ? .authorized : .denied })
        precondition(!autoImportToPhotos, "Automatic import defaults to off")
        updateTransfer(["id": "photos-disabled", "direction": "receive", "state": "complete", "files": files])
        precondition(photosImportTask == nil && permissions == 0)

        changeAutoImportToPhotos(true)
        await photosAuthorizationTask?.value
        precondition(!autoImportToPhotos && !photosImportError.isEmpty && !authorizingPhotosImport,
                     "Denied permission must leave the switch off")
        allowed = true
        changeAutoImportToPhotos(true)
        precondition(authorizingPhotosImport && !autoImportToPhotos, "Keep OFF until authorization completes")
        await photosAuthorizationTask?.value
        precondition(autoImportToPhotos && AppModel().autoImportToPhotos && photosImportError.isEmpty)
        for (id, direction, state) in [("photos-sent", "send", "complete"),
                                       ("photos-failed", "receive", "failed"),
                                       ("photos-cancelled", "receive", "cancelled")] {
            updateTransfer(["id": id, "direction": direction, "state": state, "files": files])
        }
        precondition(photosImportTask == nil, "Only successful receives can import")

        let completion: [String: Any] = ["id": "photos-received", "direction": "receive", "state": "complete", "files": files]
        updateTransfer(completion)
        precondition(busy, "Updates and destination changes wait for Photos import")
        precondition(transfers.first { $0.id == "photos-received" }?.photosImport?.phase == .queued)
        updateTransfer(completion)
        await photosImportTask?.value
        precondition(imported == [image, video].map { $0.resolvingSymlinksInPath() }, "Duplicate completion must not import twice")
        precondition(!busy && pendingPhotosImports == 0)
        let received = transfers.first { $0.id == "photos-received" }!
        precondition(received.paths == files.compactMap { $0["path"] })
        precondition(received.photosImport?.phase == .finished && received.photosImport?.importedCount == 2)
        let savedHistory = try JSONDecoder().decode([Transfer].self, from: selectionTestDefaults.data(forKey: "history")!)
        precondition(savedHistory.first { $0.id == received.id }?.photosImport == received.photosImport,
                     "Photos results must survive a restart")
        let progressRequests = selectionTestNotificationRequests.filter { $0.identifier == received.id && $0.content.categoryIdentifier == "photos-importing" }
        precondition(!progressRequests.isEmpty && progressRequests.last!.content.title.contains("%"))
        precondition(selectionTestNotificationRequests.last!.content.body.contains("2"))

        var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(received)) as! [String: Any]
        legacy.removeValue(forKey: "photosImport")
        let legacyTransfer = try JSONDecoder().decode(Transfer.self, from: JSONSerialization.data(withJSONObject: legacy))
        precondition(legacyTransfer.photosImport == nil,
                     "Older transfer history must still decode")

        photosImportDependencies.create = { plan in
            if plan.resources.first?.kind == .photo { throw CocoaError(.fileReadCorruptFile) }
            imported.append(plan.source)
        }
        updateTransfer(["id": "photos-partial", "direction": "receive", "state": "complete", "files": files])
        await photosImportTask?.value
        let partial = transfers.first { $0.id == "photos-partial" }!
        precondition(partial.state == "complete" && partial.photosImport?.importedCount == 1 && partial.photosImport?.failedCount == 1)
        precondition(selectionTestNotificationRequests.last!.content.categoryIdentifier == "photos-import-failed")
        photosImportDependencies.create = { imported.append($0.source) }

        // OFF invalidates already queued batches, including after a quick OFF/ON.
        let previousWrites = imported.count
        updateTransfer(["id": "photos-queued", "direction": "receive", "state": "complete", "files": files])
        changeAutoImportToPhotos(false)
        changeAutoImportToPhotos(true)
        await photosAuthorizationTask?.value
        await photosImportTask?.value
        precondition(imported.count == previousWrites && !busy)
        precondition(transfers.first { $0.id == "photos-queued" }?.photosImport?.phase == .stopped)

        // Pause one actual creation call, switch OFF, then finish only that item.
        var inFlight: CheckedContinuation<Void, Never>?
        photosImportDependencies.create = { plan in
            await withCheckedContinuation { inFlight = $0 }
            imported.append(plan.source)
        }
        updateTransfer(["id": "photos-stop-mid-batch", "direction": "receive", "state": "complete", "files": files])
        for _ in 0..<1000 where inFlight == nil { await Task.yield() }
        precondition(inFlight != nil, "The first asset must have started")
        clearHistory()
        precondition(transfers.contains { $0.id == "photos-stop-mid-batch" }, "Clearing history must preserve an active import")
        changeAutoImportToPhotos(false)
        inFlight!.resume()
        await photosImportTask?.value
        let stopped = transfers.first { $0.id == "photos-stop-mid-batch" }!.photosImport!
        precondition(stopped.phase == .stopped && stopped.importedCount == 1 && stopped.totalCount == 2)
        precondition(imported.count == previousWrites + 1 && !busy)

        // The per-batch Stop action leaves automatic import enabled for future receives.
        changeAutoImportToPhotos(true)
        await photosAuthorizationTask?.value
        inFlight = nil
        updateTransfer(["id": "photos-stop-action", "direction": "receive", "state": "complete", "files": files])
        for _ in 0..<1000 where inFlight == nil { await Task.yield() }
        precondition(inFlight != nil)
        stopPhotosImport(transfers.first { $0.id == "photos-stop-action" }!)
        inFlight!.resume()
        await photosImportTask?.value
        precondition(autoImportToPhotos && transfers.first { $0.id == "photos-stop-action" }?.photosImport?.phase == .stopped)
        let writesBeforeRevocation = imported.count

        // Permission revoked outside anDrop clears the persisted setting.
        photosImportDependencies.create = { imported.append($0.source) }
        changeAutoImportToPhotos(true)
        await photosAuthorizationTask?.value
        allowed = false
        refreshPhotosAuthorization()
        precondition(!autoImportToPhotos && !AppModel().autoImportToPhotos && !photosImportError.isEmpty)
        updateTransfer(["id": "photos-revoked", "direction": "receive", "state": "complete", "files": files])
        precondition(transfers.first { $0.id == "photos-revoked" }?.photosImport == nil)
        precondition(imported.count == writesBeforeRevocation)

        // A late OS permission response cannot undo a user's newer OFF choice.
        var permissionResponse: CheckedContinuation<Void, Never>?
        photosImportDependencies.authorize = {
            await withCheckedContinuation { permissionResponse = $0 }
            return .authorized
        }
        changeAutoImportToPhotos(true)
        let authorization = photosAuthorizationTask!
        for _ in 0..<1000 where permissionResponse == nil { await Task.yield() }
        precondition(permissionResponse != nil)
        changeAutoImportToPhotos(false)
        permissionResponse!.resume()
        await authorization.value
        precondition(!autoImportToPhotos && !authorizingPhotosImport)

        var interrupted = Transfer(id: "photos-interrupted", state: "complete")
        interrupted.photosImport = .init(phase: .importing, importedCount: 3, totalCount: 20)
        transfers = [interrupted]
        stopInterruptedPhotosImports()
        precondition(transfers[0].photosImport?.phase == .stopped && transfers[0].photosImport?.importedCount == 3)
        precondition(FileManager.default.fileExists(atPath: pdf.path) && FileManager.default.fileExists(atPath: image.path))
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
