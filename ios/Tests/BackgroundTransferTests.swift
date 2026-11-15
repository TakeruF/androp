// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Testing
@testable import anDropProtocol

private struct BackgroundFixture {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    var store: BackgroundSendJobStore { .init(directory: root.appending(path: "handoff")) }
    var recipient: TransferRecipient { .init(peripheralID: UUID(), discoveryID: "fixture-recipient", name: "Fixture") }
    init() throws { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
    func file(_ name: String, bytes: Data) throws -> URL {
        let file = root.appending(path: name); try bytes.write(to: file); return file
    }
}

@Test func backgroundHandoffOwnsBytesAfterProviderCleanupAndSeparatesMetadata() async throws {
    let fixture = try BackgroundFixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
    let source = try fixture.file("manifest.json", bytes: Data("original private content".utf8))
    let job = try await fixture.store.enqueue([source], recipient: fixture.recipient)
    try FileManager.default.removeItem(at: source)
    let (loaded, files) = try fixture.store.load()
    #expect(loaded.id == job.id && files[0].lastPathComponent == "manifest.json")
    #expect(try Data(contentsOf: files[0]) == Data("original private content".utf8))
    fixture.store.remove(id: UUID())
    #expect(try fixture.store.load().0.id == job.id)
    fixture.store.remove(id: job.id)
    #expect(throws: (any Error).self) { try fixture.store.load() }
}

@Test func backgroundHandoffRejectsOverlapWithoutRemovingFirstTransfer() async throws {
    let fixture = try BackgroundFixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
    let source = try fixture.file("fixture.txt", bytes: Data([1,2,3]))
    let job = try await fixture.store.enqueue([source], recipient: fixture.recipient)
    await #expect(throws: BackgroundSendJobError.busy) { try await fixture.store.enqueue([source], recipient: fixture.recipient) }
    #expect(try fixture.store.load().0.id == job.id)
    #expect(try Data(contentsOf: fixture.store.load().1[0]) == Data([1,2,3]))
}

@Test func backgroundHandoffRejectsChangedPayloadAndUnsafeManifestPaths() async throws {
    let fixture = try BackgroundFixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
    let source = try fixture.file("fixture.txt", bytes: Data([1,2,3]))
    let job = try await fixture.store.enqueue([source], recipient: fixture.recipient)
    let payload = try fixture.store.load().1[0]
    try Data([1]).write(to: payload)
    #expect(throws: BackgroundSendJobError.invalid) { try fixture.store.load() }
    let manifest = fixture.store.directory.appending(path: "active/manifest.json")
    var value = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any])
    value["names"] = ["../fixture.txt"]
    try JSONSerialization.data(withJSONObject: value).write(to: manifest)
    #expect(throws: BackgroundSendJobError.invalid) { try fixture.store.load() }
    fixture.store.remove(id: job.id)
    #expect(try Data(contentsOf: source) == Data([1,2,3]))
}

@Test func backgroundHandoffRecoversOnlyStaleOwnedStaging() async throws {
    let fixture = try BackgroundFixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
    let active = fixture.store.directory.appending(path: "active")
    try FileManager.default.createDirectory(at: active, withIntermediateDirectories: true)
    try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -601)], ofItemAtPath: active.path)
    let source = try fixture.file("fixture.txt", bytes: Data([1]))
    let job = try await fixture.store.enqueue([source], recipient: fixture.recipient)
    #expect(try fixture.store.load().0.id == job.id)
}

@Test func backgroundHandoffRejectsLinksAndCleansOnlyItsRequest() async throws {
    let fixture = try BackgroundFixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
    let source = try fixture.file("source.txt", bytes: Data([1,2,3]))
    let link = fixture.root.appending(path: "link.txt")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
    await #expect(throws: BackgroundSendJobError.invalid) { try await fixture.store.enqueue([link], recipient: fixture.recipient) }
    #expect(try Data(contentsOf: source) == Data([1,2,3]))
    #expect(!FileManager.default.fileExists(atPath: fixture.store.directory.appending(path: "active").path))
}

@Test func systemProgressReservesCompletionForConfirmedSuccess() {
    let sent = TransferProgress(stage: "awaiting_confirmation", completedBytes: 100, totalBytes: 100)
    #expect(sent.completedUnits == 990 && !sent.succeeded && !sent.terminal)
    #expect(sent.subtitle.contains("完了確認待ち"))
    #expect(TransferProgress(stage: "send_complete", completedBytes: 100, totalBytes: 100).completedUnits == 1000)
    #expect(TransferProgress(stage: "receive_complete").succeeded)
    #expect(TransferProgress(stage: "failed", completedBytes: 100, totalBytes: 100).completedUnits == 990)
    #expect(TransferProgress(stage: "background_expired").terminal)
    #expect(TransferProgress(stage: "sending_archive", completedBytes: 101, totalBytes: 100).completedUnits == 990)
    #expect(TransferProgress(stage: "sending_archive", completedBytes: -10, totalBytes: 100).completedUnits == 0)
    #expect(TransferProgress(stage: "sending_archive", completedBytes: 0, totalBytes: 0).completedUnits == 0)
}

@Test func newAppProcessDiscardsOnlyPreviouslyStartedHandoff() async throws {
    let fixture = try BackgroundFixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
    let source = try fixture.file("fixture.txt", bytes: Data([1,2,3]))
    let job = try await fixture.store.enqueue([source], recipient: fixture.recipient)
    fixture.store.discardInterrupted()
    #expect(try fixture.store.load().0.id == job.id)
    try fixture.store.markStarted(id: job.id)
    fixture.store.discardInterrupted()
    #expect(throws: (any Error).self) { try fixture.store.load() }
    #expect(try Data(contentsOf: source) == Data([1,2,3]))
}

@Test func recipientSelectionCanChangeOnlyItsUnstartedDraftAndKeepsPayload() async throws {
    let fixture = try BackgroundFixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
    let source = try fixture.file("fixture.txt", bytes: Data([1,2,3]))
    let job = try await fixture.store.enqueue([source], recipient: fixture.recipient)
    let selected = TransferRecipient(peripheralID: UUID(), discoveryID: "selected-recipient", name: "Selected")
    #expect(throws: BackgroundSendJobError.invalid) { try fixture.store.selectRecipient(id: UUID(), recipient: selected) }
    try fixture.store.selectRecipient(id: job.id, recipient: selected)
    #expect(try fixture.store.load().0.recipient == selected)
    #expect(try Data(contentsOf: fixture.store.load().1[0]) == Data([1,2,3]))
    try fixture.store.markStarted(id: job.id)
    #expect(throws: BackgroundSendJobError.invalid) { try fixture.store.selectRecipient(id: job.id, recipient: fixture.recipient) }
    #expect(try fixture.store.load().0.recipient == selected)
}
