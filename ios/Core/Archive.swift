// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import CryptoKit
import ZIPFoundation

public struct ReceivedFile: Codable, Identifiable, Sendable {
    public var id: URL { url }
    public let url: URL
    public let bytes: Int
    public let sha256: String
}

public struct PreparedFiles: Sendable {
    public let archive: Data
    public let count: Int
    public let total: Int
    public let firstName: String
    public let mime: String
    public func bluetoothOffer(keys: NegotiationKeys, senderName: String) throws -> [String: Any] {
        try ["key": keys.publicKey, "version": keys.encrypt("10014"), "pv": 4, "isFast": 0,
         "number": keys.encrypt(String(count)), "type": keys.encrypt(mime),
         "device_name": keys.encrypt(senderName), "random_code": keys.encrypt("")]
    }
    public func sendRequest(taskID: String, senderName: String) -> [String: Any] {
        ["id": taskID, "senderId": String(taskID.prefix(12)), "senderName": senderName,
         "fileName": firstName, "fileCount": count, "number": String(count), "totalSize": total,
         "mimeType": mime, "wlan": true]
    }
}

public enum FileArchive {
    public static func safeName(_ raw: String) throws -> String {
        let normalized = raw.replacingOccurrences(of: "\\", with: "/")
        let parts = normalized.split(separator: "/", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              let name = parts.last.map(String.init), name.utf8.count <= 240,
              !name.unicodeScalars.contains(where: { $0.value < 32 || $0 == ":" || $0.value == 127 })
        else { throw TransferFailure.invalid("Unsafe archive file name.") }
        return name
    }
    @concurrent public static func prepare(_ files: [URL]) async throws -> PreparedFiles {
        guard (1...Limits.files).contains(files.count) else { throw TransferFailure.invalid("Choose 1–16 files.") }
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appending(path: "outgoing.zip")
        let archive = try Archive(url: target, accessMode: .create)
        var total = 0; var names = Set<String>()
        for file in files {
            try Task.checkCancellation()
            let access = file.startAccessingSecurityScopedResource()
            defer { if access { file.stopAccessingSecurityScopedResource() } }
            let name = try safeName(file.lastPathComponent)
            let metadata = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard metadata.isRegularFile == true, metadata.isSymbolicLink != true, let size = metadata.fileSize,
                  size <= Limits.bytes - total, names.insert(name.lowercased()).inserted else { throw TransferFailure.invalid("ファイル名の重複を避け、合計サイズを\(Limits.byteLimitMiB)MiB以下にしてください。") }
            let bytes = try Data(contentsOf: file, options: .mappedIfSafe)
            guard bytes.count == size else { throw TransferFailure.invalid("A source file changed while preparing it.") }
            total += bytes.count
            try archive.addEntry(with: name, type: .file, uncompressedSize: Int64(bytes.count), compressionMethod: .none) { position, count in
                Data(bytes[Int(position)..<min(Int(position) + count, bytes.count)])
            }
        }
        // This immutable, app-owned file is mapped instead of retaining the
        // whole ZIP in heap memory. The mapping stays valid after unlinking.
        let bytes = try Data(contentsOf: target, options: .alwaysMapped)
        guard bytes.count <= Limits.archive else { throw TransferFailure.invalid("Archive exceeds the prototype limit.") }
        return PreparedFiles(archive: bytes, count: files.count, total: total, firstName: files[0].lastPathComponent,
                             mime: FileTypes.batchMIME(filenames: files.map(\.lastPathComponent)))
    }
    @concurrent public static func extract(_ bytes: Data, count: Int, total: Int, destination: URL) async throws -> [ReceivedFile] {
        guard (1...Limits.files).contains(count), (0...Limits.bytes).contains(total), bytes.count <= Limits.archive else { throw TransferFailure.invalid("Transfer exceeds the prototype limits.") }
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let zip = root.appending(path: "incoming.zip"); try bytes.write(to: zip)
        let archive = try Archive(url: zip, accessMode: .read)
        let entries = Array(archive)
        guard entries.count <= 64 else { throw TransferFailure.invalid("Too many archive entries.") }
        var expected = UInt64(0); var names = Set<String>()
        let files = try entries.filter { entry in
            _ = try safeName(entry.type == .directory ? String(entry.path.dropLast()) : entry.path)
            guard entry.type == .directory || entry.type == .file else { throw TransferFailure.invalid("Links are not supported.") }
            return entry.type == .file
        }
        guard files.count == count else { throw TransferFailure.invalid("File count mismatch.") }
        for entry in files {
            let name = try safeName(entry.path)
            guard entry.uncompressedSize <= UInt64(total) - expected, names.insert(name.lowercased()).inserted else { throw TransferFailure.invalid("Invalid archive contents.") }
            expected += entry.uncompressedSize
        }
        guard expected == UInt64(total) else { throw TransferFailure.invalid("File size mismatch.") }
        var staged: [(URL, String, Int, String)] = []
        for entry in files {
            try Task.checkCancellation()
            var data = Data()
            let crc = try archive.extract(entry) { chunk in
                guard chunk.count <= total - data.count else { throw TransferFailure.invalid("Archive expands beyond its announced size.") }
                data.append(chunk)
            }
            guard crc == entry.checksum, data.count == entry.uncompressedSize else { throw TransferFailure.invalid("Archive checksum or size mismatch.") }
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            let file = root.appending(path: UUID().uuidString)
            try data.write(to: file, options: .withoutOverwriting)
            guard Data(SHA256.hash(data: try Data(contentsOf: file))) == Data(SHA256.hash(data: data)) else { throw TransferFailure.invalid("File readback failed.") }
            staged.append((file, try safeName(entry.path), data.count, digest))
        }
        var saved: [ReceivedFile] = []
        do {
            for (temporary, name, size, digest) in staged {
                try Task.checkCancellation()
                let path = name as NSString; let ext = path.pathExtension; let stem = path.deletingPathExtension
                var published: URL?
                for index in 0..<10_000 {
                    let candidate = destination.appending(path: index == 0 ? name : stem + " (\(index))" + (ext.isEmpty ? "" : "." + ext))
                    do { try FileManager.default.copyItem(at: temporary, to: candidate); published = candidate; break }
                    catch CocoaError.fileWriteFileExists { continue }
                }
                guard let published else { throw TransferFailure.invalid("Too many files have the same name.") }
                saved.append(ReceivedFile(url: published, bytes: size, sha256: digest))
            }
            return saved
        } catch {
            for file in saved { try? FileManager.default.removeItem(at: file.url) }
            throw error
        }
    }
}
