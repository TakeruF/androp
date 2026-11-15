// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Testing
import ZIPFoundation
@testable import anDropProtocol

@Test func declaresConcreteTypesAndTreatsNamesAsFiles() {
    let cases = [
        "写真.JPG": "image/jpeg", "photo.png": "image/png", "photo.HEIC": "image/heic",
        "movie.mp4": "video/mp4", "sound.mp3": "audio/mpeg", "sound.wav": "audio/vnd.wave",
        "書類.PDF": "application/pdf", "note.txt": "text/plain", "archive.zip": "application/zip",
        "word.docx": "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
        "sheet.xlsx": "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        "slides.pptx": "application/vnd.openxmlformats-officedocument.presentationml.presentation",
        "archive.tar.gz": "application/gzip", "notes.txt.bz2": "application/x-bzip2",
        "file?#.pdf": "application/pdf", "notes.pdf.unknown-extension": "file/*",
        "README": "file/*", ".pdf": "file/*", "empty.bin": "file/*"
    ]
    for (name, expected) in cases { #expect(FileTypes.mime(for: name) == expected, "Unexpected declaration for \(name)") }
}

@Test func batchDeclarationIncludesEveryFile() {
    let cases: [([String], String)] = [
        (["a.pdf", "b.PDF"], "application/pdf"), (["a.jpg", "b.png"], "image/*"),
        (["a.mp3", "b.wav"], "audio/*"), (["a.mp4", "b.mov"], "video/*"),
        (["a.jpg", "b.pdf"], "file/*"), (["a.pdf", "b.jpg"], "file/*"),
        (["a.jpg", "b.unknown-extension"], "file/*"), (["a.pdf", "b.docx"], "file/*"), ([], "file/*")
    ]
    for (files, expected) in cases { #expect(FileTypes.batchMIME(filenames: files) == expected) }
}

@Test func incomingTypeIsAdvisoryAndCannotInjectHeaders() {
    #expect(FileTypes.normalizedDeclaration("APPLICATION/PDF") == "application/pdf")
    #expect(FileTypes.normalizedDeclaration(nil) == "file/*")
    for value: Any in [42, "image/png\r\nX: value", "invalid", String(repeating: "a", count: 200)] {
        #expect(FileTypes.normalizedDeclaration(value) == "file/*")
    }
}

@Test func initialBLEAndLaterControlUseSameTypeWithoutChangingZIP() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let samples: [([String], String)] = [(["書類.PDF"], "application/pdf"), (["a.jpg", "b.png"], "image/*"), (["a.pdf", "b.jpg"], "file/*")]
    for (names, expected) in samples {
        var urls: [URL] = []
        for name in names { let file = root.appending(path: name); try Data("fixture: \(name)".utf8).write(to: file); urls.append(file) }
        let files = try await FileArchive.prepare(urls)
        var sender = NegotiationKeys(); var receiver = NegotiationKeys()
        try sender.derive(peer: receiver.publicKey); try receiver.derive(peer: sender.publicKey)
        // The pre-approval declaration is available even if the peer declines
        // before a WebSocket or sendRequest exists.
        let ble = try files.bluetoothOffer(keys: sender, senderName: "Fixture")
        let encryptedType = try #require(ble["type"] as? String)
        #expect(try receiver.decrypt(encryptedType) == expected)
        let request = files.sendRequest(taskID: "fixture-task", senderName: "Fixture")
        #expect(request["mimeType"] as? String == expected)
        #expect(request["fileName"] as? String == names[0])
        #expect(request["fileCount"] as? Int == names.count)
        #expect(request["totalSize"] as? Int == files.total)
        #expect(files.archive.starts(with: [0x50, 0x4b, 0x03, 0x04]))
        let extracted = try await FileArchive.extract(files.archive, count: names.count, total: files.total, destination: root.appending(path: UUID().uuidString))
        #expect(extracted.map { $0.url.lastPathComponent } == names)
        for (original, result) in zip(urls, extracted) { #expect(try Data(contentsOf: original) == Data(contentsOf: result.url)) }
    }
}
