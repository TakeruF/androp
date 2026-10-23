// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 anDrop contributors
import Foundation
import Testing

@MainActor @Test func receiveConnectionContextIsBoundedAndPrivate() throws {
    let id = UUID().uuidString
    let offer = try #require(DiagnosticsStore.sanitized([
        "event": "diagnostic", "detail": "receive_network_offer", "transfer_id": id,
        "mode": "direct", "host": "192.168.3.9", "ssid": "private network", "psk": "private password"
    ]))
    #expect(offer.networkMode == "direct")
    #expect(offer.transfer == id.lowercased())
    let attempt = try #require(DiagnosticsStore.sanitized([
        "event": "diagnostic", "detail": "receive_connect_attempt", "attempt": 4
    ]))
    #expect(attempt.attempt == 4)
    #expect(DiagnosticsStore.sanitized(["event": "diagnostic", "detail": "receive_connect_attempt", "attempt": 5])?.attempt == nil)
    // Older stored reports omit these fields and must remain readable.
    let decoded = try JSONDecoder().decode(DiagnosticsStore.Event.self, from: Data("{\"time\":\"2026-10-21T11:12:27Z\",\"event\":\"diagnostic\",\"code\":\"receive_failed\"}".utf8))
    #expect(decoded.connectionIssue == nil && decoded.networkMode == nil && decoded.attempt == nil)
    for issue in ["local_address_family_mismatch", "multiple_socket_errors", "interface_unavailable", "errno_unavailable"] {
        let failure = try #require(DiagnosticsStore.sanitized([
            "event": "diagnostic", "detail": "receive_connect_interrupted", "phase": "connect",
            "connection_issue": issue, "error_type": "ClientConnectorError"
        ]))
        #expect(failure.connectionIssue == issue)
    }
    let rejected = try #require(DiagnosticsStore.sanitized([
        "event": "diagnostic", "detail": "receive_failed", "phase": "connect",
        "connection_issue": "private host 192.168.3.9", "mode": "private network", "attempt": 1
    ]))
    #expect(rejected.connectionIssue == nil && rejected.networkMode == nil && rejected.attempt == nil)
    #expect(DiagnosticsStore.sanitized(["event": "diagnostic", "detail": "receive_failed", "phase": "download", "connection_issue": "errno_unavailable"])?.connectionIssue == nil)
    let encoded = String(decoding: try JSONEncoder().encode([offer, attempt, rejected]), as: UTF8.self)
    #expect(!encoded.contains("private")); #expect(!encoded.contains("192.168"))
}

@MainActor @Test func huaweiFailureSourceIsBoundedAndDropsPrivateText() throws {
    var raw: [String: Any] = ["event": "diagnostic", "detail": "huawei_receive_failed",
        "receive_module": "batch", "receive_line": 421]
    let event = try #require(DiagnosticsStore.sanitized(raw))
    #expect(event.receiveModule == "batch" && event.receiveLine == 421)
    raw["receive_module"] = "/private/user/file.py"
    raw["receive_line"] = 10001
    #expect(DiagnosticsStore.sanitized(raw)?.receiveModule == nil)
    #expect(DiagnosticsStore.sanitized(raw)?.receiveLine == nil)
    raw["detail"] = "huawei_send_failed"
    raw["receive_module"] = "batch"; raw["receive_line"] = 421
    #expect(DiagnosticsStore.sanitized(raw)?.receiveModule == nil)
    #expect(DiagnosticsStore.sanitized(raw)?.receiveLine == nil)
}
@testable import anDropIdentity

@MainActor @Test func controlAndNetworkOfferDiagnosticsExcludePayloadValues() throws {
    let event = try #require(DiagnosticsStore.sanitized([
        "event": "diagnostic", "detail": "send_offer_fields", "offer_kind": "lan_request",
        "offer_fields": ["wlan", "ip", "private@example.invalid", "ssid"],
        "ip": "192.168.3.9", "ssid": "private network", "psk": "private password"
    ]))
    #expect(event.offerFields == ["ip", "ssid", "wlan"])
    #expect(event.offerKind == "lan_request")
    let text = String(decoding: try JSONEncoder().encode(event), as: UTF8.self)
    #expect(!text.contains("private")); #expect(!text.contains("192.168"))
    #expect(DiagnosticsStore.sanitized(["event": "diagnostic", "detail": "control_message", "message_type": "binary"])?.messageType == "binary")
    #expect(DiagnosticsStore.sanitized(["event": "diagnostic", "detail": "control_message", "message_type": "private payload"])?.messageType == nil)
    #expect(DiagnosticsStore.sanitized(["event": "diagnostic", "detail": "control_action", "protocol_action": "sendRequest"])?.protocolAction == "sendRequest")
    #expect(DiagnosticsStore.sanitized(["event": "diagnostic", "detail": "control_action", "protocol_action": "private action"])?.protocolAction == nil)
    for error in ["TypeError", "SocketTimeoutError", "ConnectionTimeoutError", "ConnectionError", "UnicodeDecodeError"] {
        #expect(DiagnosticsStore.sanitized(["event": "diagnostic", "detail": "receive_failed", "error_type": error])?.errorType == error)
    }
    for code in ["live_photo_converted", "live_photo_conversion_failed", "live_photo_cleanup_failed"] {
        let converted = try #require(DiagnosticsStore.sanitized(["event": "diagnostic", "detail": code,
            "path": "/private/photo.jpg", "error": "private conversion error", "identifier": "private identifier"]))
        #expect(converted.code == code)
        #expect(!String(decoding: try JSONEncoder().encode(converted), as: UTF8.self).contains("private"))
    }
}

@MainActor @Test func diagnosticEventsExcludePrivatePayloads() throws {
    let secret = "private-name@example.invalid /Users/private/file.pdf 192.168.3.9 secret-key"
    let event = try #require(DiagnosticsStore.sanitized([
        "event": "diagnostic", "detail": secret, "peer": secret, "name": secret,
        "ip": secret, "key": secret, "error_type": secret, "phase": secret, "transfer_id": secret,
        "files": [["path": secret]], "errno": 61
    ]))
    let text = String(decoding: try JSONEncoder().encode(event), as: UTF8.self)
    #expect(!text.contains("private")); #expect(!text.contains("192.168"))
    #expect(event.errno == 61); #expect(event.errorType == "OtherError")
    #expect(event.transfer == nil); #expect(event.code == nil)
    #expect(DiagnosticsStore.sanitized(["event": "ble_notify", "data": secret]) == nil)
}
@MainActor @Test func transportFailuresKeepOnlyFixedPhaseAndBoundedErrno() throws {
    for phase in DiagnosticsStore.transportPhases {
        let event = try #require(DiagnosticsStore.sanitized([
            "event": "diagnostic", "detail": "huawei_transport_failed", "phase": phase,
            "error_type": "OSError", "errno": 49
        ]))
        #expect(event.code == "huawei_transport_failed")
        #expect(event.phase == phase)
        #expect(event.errorType == "OSError")
        #expect(event.errno == 49)
    }
    // A failure without a usable errno still records the phase.
    let bare = try #require(DiagnosticsStore.sanitized(["event": "diagnostic", "detail": "huawei_transport_failed", "phase": "transport_target"]))
    #expect(bare.errno == nil); #expect(bare.errorType == nil)

    // Anything the transport must never emit is dropped rather than stored.
    let leak = try #require(DiagnosticsStore.sanitized([
        "event": "diagnostic", "detail": "huawei_transport_failed",
        "phase": "transport_send to 192.168.3.9 (Pura 70): Can't assign requested address",
        "host": "192.168.3.9", "local": "192.168.3.4", "name": "private Pura 70",
        "data": "AAECAwQFBgc=", "key": "0123456789abcdef", "message": "No route to host",
        "errno": 999_999
    ]))
    #expect(leak.phase == nil); #expect(leak.errno == nil)
    let text = String(decoding: try JSONEncoder().encode(leak), as: UTF8.self)
    #expect(!text.contains("192.168")); #expect(!text.contains("Pura"))
    #expect(!text.contains("AAECAwQFBgc")); #expect(!text.contains("0123456789abcdef"))
    #expect(!text.lowercased().contains("route")); #expect(!text.lowercased().contains("address"))
    #expect(DiagnosticsStore.sanitized(["event": "diagnostic", "detail": "huawei_transport_failed", "phase": "transport_arbitrary"])?.phase == nil)
}
@MainActor @Test func reportPreservesFailureContextAcrossRestart() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let id = UUID().uuidString
    let store = DiagnosticsStore(folder: folder)
    let startApps = [DiagnosticsStore.RunningApp(name: "Fixture App", bundleID: "org.example.fixture")]
    let failureApps = startApps + [.init(name: "Other App", bundleID: "org.example.other")]
    store.record(["event": "transfer", "id": id, "direction": "send", "state": "preparing", "name": "private.pdf"])
    store.recordContext(id: id, direction: "send", state: "preparing", filenames: ["private.pdf", "private.JPG"], count: 2, allTypesKnown: true, brand: "OPPO", kind: "phone", apps: startApps)
    store.record(["event": "diagnostic", "transfer_id": id, "detail": "send_failed", "error_type": "OSError", "errno": 61, "phase": "connecting"])
    store.record(["event": "transfer", "id": id, "direction": "send", "state": "failed"])
    store.recordContext(id: id, direction: "send", state: "failed", filenames: ["private.pdf", "private.JPG"], count: 2, allTypesKnown: true, brand: "OPPO", kind: "phone", apps: failureApps)
    store.record(["event": "transfer", "id": UUID().uuidString, "state": "complete"])
    let restarted = DiagnosticsStore(folder: folder)
    let result = try restarted.makeReport(transfer: id, appVersion: "1.0.1 (10006)")
    let report = try JSONDecoder().decode(DiagnosticsStore.Report.self, from: Data(result.text.utf8))
    #expect(report.detailedLogAvailable)
    #expect(report.context?.fileTypes == ["jpg", "pdf"])
    #expect(report.context?.fileCount == 2)
    #expect(report.context?.peerBrand == "OPPO")
    #expect(report.context?.peerOS == "not_provided_by_protocol")
    #expect(report.context?.appsAtStart == startApps)
    #expect(report.context?.appsAtFailure == failureApps)
    #expect(report.events.last?.state == "failed")
    #expect(!result.text.contains("private.pdf"))
    let permissions = try FileManager.default.attributesOfItem(atPath: result.url.path)[.posixPermissions] as? NSNumber
    #expect(permissions?.intValue == 0o600)
}
@MainActor @Test func missingHistoricalLogIsExplicitAndCannotTraversePaths() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = DiagnosticsStore(folder: folder)
    let result = try store.makeReport(transfer: UUID().uuidString, appVersion: "test")
    let report = try JSONDecoder().decode(DiagnosticsStore.Report.self, from: Data(result.text.utf8))
    #expect(!report.detailedLogAvailable); #expect(report.context == nil)
    #expect(DiagnosticsStore.transferID("../../private") == nil)
    #expect(DiagnosticsStore.fileType("name.private-secret") == "other")
    #expect(DiagnosticsStore.fileType("name.PDF") == "pdf")
}
@MainActor @Test func logsAreBoundedAndProgressIsCoalesced() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = DiagnosticsStore(folder: folder)
    let id = UUID().uuidString
    for _ in 0..<100 { store.record(["event": "transfer", "id": id, "state": "transferring"]) }
    #expect(store.events.count == 1)
    for _ in 0..<350 { store.record(["event": "diagnostic", "detail": "receive_connect_attempt"]) }
    #expect(store.events.count == 300)
    for _ in 0..<12 { _ = try store.makeReport(transfer: nil, appVersion: "test") }
    let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
    #expect(files.filter { $0.lastPathComponent.hasPrefix("anDrop-report-") }.count == 10)
}

@MainActor @Test func latePartialTypesDoNotOverwriteCompleteTypes() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = DiagnosticsStore(folder: folder)
    let id = UUID().uuidString
    let app = DiagnosticsStore.RunningApp(name: "Fixture", bundleID: "org.example.fixture")
    func update(_ names: [String], complete: Bool) {
        store.recordContext(id: id, direction: "receive", state: "connecting", filenames: names, count: 2, allTypesKnown: complete, brand: nil, kind: nil, apps: [app, app])
    }
    func context() throws -> DiagnosticsStore.Context? {
        let result = try store.makeReport(transfer: id, appVersion: "test")
        return try JSONDecoder().decode(DiagnosticsStore.Report.self, from: Data(result.text.utf8)).context
    }
    update([], complete: false)
    update(["first.pdf"], complete: false)
    #expect(try context()?.fileTypesScope == "first_file_only")
    #expect(try context()?.appsAtStart.count == 1)
    update(["first.pdf", "second.jpg"], complete: true)
    update(["first.pdf"], complete: false)
    #expect(try context()?.fileTypesScope == "all_files")
    #expect(try context()?.fileTypes == ["jpg", "pdf"])
}

@MainActor @Test func huaweiReceiveFailuresKeepFixedStageAndDropPrivateText() throws {
    for phase in ["receive", "receive_preview", "receive_preview_frame", "receive_metadata", "receive_data"] {
        let event = try #require(DiagnosticsStore.sanitized(["event": "diagnostic", "detail": "huawei_receive_failed", "phase": phase]))
        #expect(event.phase == phase)
    }
    let event = try #require(DiagnosticsStore.sanitized(["event": "diagnostic", "detail": "huawei_receive_failed", "phase": "receive_preview /private/photo.jpg 192.168.0.4", "preview": "private thumbnail"]))
    #expect(event.phase == nil)
    let text = String(decoding: try JSONEncoder().encode(event), as: UTF8.self)
    #expect(!text.contains("private")); #expect(!text.contains("192.168")); #expect(!text.contains("thumbnail"))
}

@MainActor @Test func huaweiPreviewDiagnosticsKeepOnlyBoundedNumbers() throws {
    var raw: [String: Any] = ["event": "diagnostic", "detail": "huawei_receive_failed", "preview_issue": "thumbnail_size",
                              "preview_fields": [["tag": 11, "bytes": 18, "value": "private.jpg"], ["tag": 12, "bytes": 60001]]]
    let event = try #require(DiagnosticsStore.sanitized(raw))
    #expect(event.previewIssue == "thumbnail_size")
    #expect(event.previewFields == [.init(tag: 11, bytes: 18), .init(tag: 12, bytes: 60001)])
    #expect(!String(decoding: try JSONEncoder().encode(event), as: UTF8.self).contains("private"))
    for fields: [[String: Any]] in [[ ["tag": 11, "bytes": -1] ], [ ["tag": 256, "bytes": 1] ],
                                   [ ["tag": 12, "bytes": 1_048_577] ], [ ["tag": 11, "bytes": "private.jpg"] ],
                                   Array(repeating: ["tag": 11, "bytes": 1], count: 33)] {
        raw["preview_fields"] = fields
        #expect(DiagnosticsStore.sanitized(raw)?.previewFields == nil)
    }
    raw["preview_issue"] = "private.jpg"
    #expect(DiagnosticsStore.sanitized(raw)?.previewIssue == nil)
    let legacy = Data(#"{"time":"2026-10-17T10:56:47Z","event":"diagnostic","code":"huawei_receive_failed"}"#.utf8)
    let restored = try JSONDecoder().decode(DiagnosticsStore.Event.self, from: legacy)
    #expect(restored.previewFields == nil)
    #expect(restored.previewIssue == nil)
}
