// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 anDrop contributors
import Foundation

/// Export only structured diagnostic fields. Never attach the legacy status
/// files, which may contain names, addresses, paths or raw protocol messages.
@MainActor
final class DiagnosticsStore {
    struct Event: Codable, Equatable {
        var time: String
        var event: String
        var transfer: String?
        var direction: String?
        var state: String?
        var code: String?
        var phase: String?
        var errorType: String?
        var errno: Int?
    }
    struct RunningApp: Codable, Hashable {
        var name: String
        var bundleID: String?
    }
    struct Context: Codable {
        var transfer: String
        var direction: String
        var fileTypes: [String]
        var fileCount: Int
        var fileTypesScope: String
        var peerBrand: String
        var peerKind: String
        // The current protocol does not expose the Android/ColorOS version.
        // Its protocol version must never be presented as an OS version.
        var peerOS = "not_provided_by_protocol"
        var appsAtStart: [RunningApp]
        var appsAtFailure: [RunningApp]?
    }
    struct Report: Codable {
        var formatVersion = 1
        var created: String
        var appVersion: String
        var macOS: String
        var architecture: String
        var selectedTransfer: String?
        var detailedLogAvailable: Bool
        var context: Context?
        var events: [Event]
    }
    let folder: URL
    private(set) var events: [Event] = []
    private var contexts: [String: Context] = [:]
    private let fileManager = FileManager.default
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]; return encoder
    }()
    static let states: Set<String> = ["preparing", "waiting", "verifying", "connecting", "request", "transferring", "confirming", "complete", "failed", "declined", "cancelled"]
    static let codes: Set<String> = ["receive_connect_attempt", "receive_connect_interrupted", "receive_untrusted_sender", "receive_endpoint_replaced", "receive_network_offer", "receive_udp_probe_unavailable", "receive_connected", "receive_negotiating", "receive_download_start", "receive_save_start", "receive_failed", "send_failed", "send_offer_fields", "engine_stopped", "engine_start_failed", "ignored_unrelated_invalid_write", "WebSocket connected", "Bandwidth probes sent"]
    static let phases = states.union(["connect", "bandwidth", "negotiate", "download", "save", "bind"])
    static let errorTypes: Set<String> = ["ClientConnectorError", "ClientConnectionError", "ClientOSError", "ClientPayloadError", "ServerDisconnectedError", "ServerTimeoutError", "TimeoutError", "OSError", "PermissionError", "ConnectionRefusedError", "ConnectionResetError", "BrokenPipeError", "FileNotFoundError", "ValueError", "TransferError", "BleakError", "BleakDBusError", "ClientSSLError", "ServerFingerprintMismatch", "WSServerHandshakeError", "BadZipFile"]
    static let extensions: Set<String> = ["txt", "pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "csv", "json", "xml", "md", "html", "css", "js", "py", "swift", "log", "jpg", "jpeg", "png", "gif", "webp", "heic", "heif", "avif", "svg", "tif", "tiff", "bmp", "raw", "dng", "mp4", "mov", "mkv", "avi", "webm", "m4v", "mp3", "m4a", "aac", "wav", "flac", "ogg", "zip", "7z", "rar", "gz", "tar", "dmg", "pkg", "apk", "bin", "epub"]
    static func fileType(_ filename: String) -> String {
        let ext = (filename as NSString).pathExtension.lowercased()
        return ext.isEmpty ? "no_extension" : extensions.contains(ext) ? ext : "other"
    }
    static func transferID(_ raw: String?) -> String? {
        guard let raw, let uuid = UUID(uuidString: raw) ?? UUID(uuidString: raw.count == 32 ? "\(raw.prefix(8))-\(raw.dropFirst(8).prefix(4))-\(raw.dropFirst(12).prefix(4))-\(raw.dropFirst(16).prefix(4))-\(raw.suffix(12))" : "") else { return nil }
        return uuid.uuidString.lowercased()
    }
    static func sanitized(_ value: [String: Any], now: Date = Date()) -> Event? {
        guard let event = value["event"] as? String, ["transfer", "diagnostic", "ready", "error"].contains(event) else { return nil }
        func allowed(_ field: String, _ values: Set<String>) -> String? {
            guard let text = value[field] as? String, values.contains(text) else { return nil }; return text
        }
        let rawType = value["error_type"] as? String
        return Event(time: now.ISO8601Format(), event: event,
                     transfer: transferID(value["transfer_id"] as? String ?? value["id"] as? String),
                     direction: allowed("direction", ["send", "receive"]), state: allowed("state", states),
                     code: allowed("detail", codes), phase: allowed("phase", phases),
                     errorType: rawType.map { errorTypes.contains($0) ? $0 : "OtherError" },
                     errno: (value["errno"] as? Int).flatMap { (-65535...65535).contains($0) ? $0 : nil })
    }
    init(folder: URL) {
        self.folder = folder
        if let data = try? Data(contentsOf: folder.appendingPathComponent("recent.json")), data.count <= 524_288,
           let saved = try? JSONDecoder().decode([Event].self, from: data) { events = Array(saved.suffix(300)) }
    }
    private func write<T: Encodable>(_ value: T, to url: URL) throws {
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try encoder.encode(value).write(to: url, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    func record(_ value: [String: Any]) {
        guard let entry = Self.sanitized(value) else { return }
        if entry.event == "transfer", let previous = events.last,
           previous.event == entry.event, previous.transfer == entry.transfer, previous.state == entry.state { return }
        events.append(entry); events = Array(events.suffix(300))
        try? write(events, to: folder.appendingPathComponent("recent.json"))
    }
    func needsAppSnapshot(id: String, state: String) -> Bool {
        guard let id = Self.transferID(id) else { return false }
        return contexts[id] == nil || state == "failed"
    }
    func recordContext(id: String, direction: String, state: String, filenames: [String], count: Int, allTypesKnown: Bool, brand: String?, kind: String?, apps: [RunningApp]) {
        guard let id = Self.transferID(id) else { return }
        let types = Array(Set(filenames.map(Self.fileType))).sorted()
        let uniqueApps = Array(Set(apps)).sorted { ($0.bundleID ?? "", $0.name) < ($1.bundleID ?? "", $1.name) }
        let brands: Set<String> = ["OPPO", "OnePlus", "realme", "Xiaomi", "Redmi", "vivo", "iQOO", "HONOR", "Huawei", "HUAWEI", "Meizu", "ZTE", "Nubia", "Lenovo", "Samsung"]
        if contexts[id] == nil {
            if contexts.count >= 30 { contexts.removeAll() }
            contexts[id] = Context(transfer: id, direction: direction == "send" ? "send" : "receive", fileTypes: types,
                fileCount: max(0, min(count, 10000)), fileTypesScope: types.isEmpty ? "not_available" : allTypesKnown ? "all_files" : "first_file_only",
                peerBrand: brands.contains(brand ?? "") ? brand! : "unknown", peerKind: ["phone", "tablet"].contains(kind ?? "") ? kind! : "unknown",
                appsAtStart: Array(uniqueApps.prefix(200)))
        }
        if !types.isEmpty, allTypesKnown || contexts[id]?.fileTypesScope != "all_files" {
            contexts[id]?.fileTypes = types
            contexts[id]?.fileTypesScope = allTypesKnown ? "all_files" : "first_file_only"
        }
        contexts[id]?.fileCount = max(0, min(count, 10000))
        if brands.contains(brand ?? "") { contexts[id]?.peerBrand = brand! }
        if ["phone", "tablet"].contains(kind ?? "") { contexts[id]?.peerKind = kind! }
        if state == "failed" {
            contexts[id]?.appsAtFailure = Array(uniqueApps.prefix(200))
            try? write(Snapshot(context: contexts[id], events: Array(events.suffix(150))), to: failureURL(id))
            prune(prefix: "failure-", keep: 20)
        }
    }
    private struct Snapshot: Codable { var context: Context?; var events: [Event] }
    private func failureURL(_ id: String) -> URL { folder.appendingPathComponent("failure-\(id).json") }
    private func prune(prefix: String, keep: Int) {
        let files = (try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let sorted = files.filter { $0.lastPathComponent.hasPrefix(prefix) && $0.pathExtension == "json" }.sorted {
            ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) > ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
        }
        for file in sorted.dropFirst(keep) { try? fileManager.removeItem(at: file) }
    }
    func makeReport(transfer rawID: String?, appVersion: String) throws -> (url: URL, text: String) {
        let id = Self.transferID(rawID)
        let snapshot: Snapshot? = id.flatMap { id in
            guard let data = try? Data(contentsOf: failureURL(id)), data.count <= 524_288 else { return nil }
            return try? JSONDecoder().decode(Snapshot.self, from: data)
        }
        let selected = snapshot?.events ?? (id == nil ? events : events.filter { $0.transfer == id })
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "x86_64"
        #endif
        let report = Report(created: Date().ISO8601Format(), appVersion: appVersion,
            macOS: ProcessInfo.processInfo.operatingSystemVersionString, architecture: architecture,
            selectedTransfer: id, detailedLogAvailable: !selected.isEmpty,
            context: snapshot?.context ?? id.flatMap { contexts[$0] }, events: selected)
        let url = folder.appendingPathComponent("anDrop-report-\(UUID().uuidString.lowercased()).json")
        try write(report, to: url); prune(prefix: "anDrop-report-", keep: 10)
        return (url, String(decoding: try encoder.encode(report), as: UTF8.self))
    }
}
