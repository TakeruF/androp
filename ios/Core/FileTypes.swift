// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import UniformTypeIdentifiers

/// Content declarations describe the selected files, not their ZIP envelope.
/// These are hints for presentation; they never authorize or validate contents.
public enum FileTypes {
    public static let generic = "file/*"
    // Keep common wire types stable across OS versions and aligned with macOS.
    private static let known: [String: String] = [
        "bin": "file/*",
        "pdf": "application/pdf", "txt": "text/plain", "text": "text/plain", "md": "text/markdown",
        "csv": "text/csv", "tsv": "text/tab-separated-values", "json": "application/json",
        "xml": "text/xml", "html": "text/html", "htm": "text/html", "rtf": "text/rtf",
        "jpg": "image/jpeg", "jpeg": "image/jpeg", "jpe": "image/jpeg", "png": "image/png",
        "gif": "image/gif", "heic": "image/heic", "heif": "image/heif", "avif": "image/avif",
        "webp": "image/webp", "bmp": "image/bmp", "tif": "image/tiff", "tiff": "image/tiff", "svg": "image/svg+xml",
        "mp4": "video/mp4", "m4v": "video/x-m4v", "mov": "video/quicktime", "mkv": "video/x-matroska",
        "webm": "video/webm", "avi": "video/x-msvideo", "mpeg": "video/mpeg", "mpg": "video/mpeg", "3gp": "audio/3gpp",
        "mp3": "audio/mpeg", "m4a": "audio/mp4", "aac": "audio/aac", "wav": "audio/vnd.wave",
        "flac": "audio/flac", "ogg": "audio/ogg", "opus": "audio/opus", "aiff": "audio/x-aiff", "aif": "audio/x-aiff",
        "doc": "application/msword", "docx": "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
        "xls": "application/vnd.ms-excel", "xlsx": "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        "ppt": "application/vnd.ms-powerpoint", "pptx": "application/vnd.openxmlformats-officedocument.presentationml.presentation",
        "odt": "application/vnd.oasis.opendocument.text", "ods": "application/vnd.oasis.opendocument.spreadsheet",
        "odp": "application/vnd.oasis.opendocument.presentation", "epub": "application/epub+zip",
        "zip": "application/zip", "7z": "application/x-7z-compressed", "rar": "application/x-rar-compressed",
        "tar": "application/x-tar", "gz": "application/gzip", "tgz": "application/gzip",
        "bz2": "application/x-bzip2", "tbz2": "application/x-bzip2", "xz": "application/x-xz",
        "z": "application/x-compress", "br": "application/x-brotli"
    ]
    public static func mime(for filename: String) -> String {
        // Treat ? and # as filename characters, not URL components.
        let name = (filename as NSString).lastPathComponent
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return generic }
        let suffix = String(name[name.index(after: dot)...]).lowercased()
        guard !suffix.isEmpty else { return generic }
        if let mime = known[suffix] { return mime }
        guard let type = UTType(filenameExtension: suffix), !type.isDynamic,
              let mime = type.preferredMIMEType?.lowercased(), mime != "application/octet-stream",
              validMIME(mime) else { return generic }
        return mime
    }
    public static func batchMIME(filenames: [String]) -> String {
        let types = Set(filenames.map { mime(for: $0) })
        if types.count == 1 { return types.first ?? generic }
        let families = Set(types.map { String($0.split(separator: "/")[0]) })
        if families.count == 1, let family = families.first, ["image", "audio", "video"].contains(family) { return family + "/*" }
        return generic
    }
    public static func normalizedDeclaration(_ value: Any?) -> String {
        guard let mime = value as? String else { return generic }
        let normalized = mime.lowercased()
        return validMIME(normalized) ? normalized : generic
    }
    private static func validMIME(_ value: String) -> Bool {
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789!#$&^_.+-*")
        return value.utf8.count <= 160 && parts.count == 2 && parts.allSatisfy { !$0.isEmpty && $0.unicodeScalars.allSatisfy { allowed.contains($0) } }
    }
    public static func category(for mime: String) -> String {
        if mime.hasPrefix("image/") { return "画像" }
        if mime.hasPrefix("video/") { return "動画" }
        if mime.hasPrefix("audio/") { return "音声" }
        if mime == "application/pdf" { return "PDF書類" }
        if mime.contains("wordprocessing") || mime == "application/msword" { return "Word書類" }
        if mime.contains("spreadsheet") || mime == "application/vnd.ms-excel" { return "表計算書類" }
        if mime.contains("presentation") || mime == "application/vnd.ms-powerpoint" { return "プレゼンテーション" }
        if mime.hasPrefix("text/") { return "テキスト" }
        if ["application/zip", "application/gzip", "application/x-7z-compressed", "application/x-rar-compressed", "application/x-tar", "application/x-bzip2", "application/x-xz"].contains(mime) { return "アーカイブ" }
        return "ファイル"
    }
    public static func symbol(for filename: String) -> String {
        let mime = mime(for: filename)
        if mime.hasPrefix("image/") { return "photo" }
        if mime.hasPrefix("video/") { return "film" }
        if mime.hasPrefix("audio/") { return "music.note" }
        if category(for: mime) == "アーカイブ" { return "doc.zipper" }
        return mime == generic ? "doc" : "doc.text"
    }
}
