// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import CoreBluetooth
import Observation
import UIKit
import os
import anDropProtocol
@preconcurrency import BackgroundTasks

struct NearbyDevice: Identifiable {
    let id: UUID
    var name: String
    var lastSeen: Date
    var discoveryID: String = ""
    var huawei: HuaweiPeer?
}

struct DiagnosticEvent: Codable, Identifiable {
    let id: UUID
    let time: Date
    let stage: String
    let fields: [String: String]?
}

private final class ReceiveSession {
    let central: CBCentral
    var keys: NegotiationKeys
    let count: Int
    var route: (String, UInt16)?
    var routeChanges = 0
    var channelConnected = false
    var routePlanner: ReceiveRoutePlanner
    init(central: CBCentral, keys: NegotiationKeys, count: Int, initialHint: String?) {
        self.central = central; self.keys = keys; self.count = count; routePlanner = .init(initialHint: initialHint)
    }
}

@Observable final class SharingModel: NSObject {
    static let shared = SharingModel()
    var enabled = false
    var bluetoothStatus = "Bluetoothを準備中…"
    var stage = "準備完了"
    var errorMessage: String?
    var peers: [NearbyDevice] = []
    var selectedFiles: [URL] = []
    var receivedFiles: [ReceivedFile] = []
    var events: [DiagnosticEvent] = []
    var incoming: IncomingOffer?
    var busy = false
    var transferredBytes = 0 { didSet { updateSystemProgress() } }
    var transferBytesTotal: Int? { didSet { updateSystemProgress() } }
    var backgroundNotice: String?
    var backgroundVerificationResult: String?
    var sharedDraftID: UUID?
    var handoffPreparing = false
    var handoffRequested = false
    var hasPreparedSend = false
    var huaweiAddress = ""
    var huaweiDiscovering = false
    var huaweiStatus: String?
    @ObservationIgnored private var huaweiDiscoveryTask: Task<Void, Never>?
    @ObservationIgnored private var huaweiSender: HuaweiSender?
    @ObservationIgnored private var huaweiDiscoveryGeneration = UUID()
    @ObservationIgnored private var execution: (any TransferExecution)?
    @ObservationIgnored private var transitionTask = UIBackgroundTaskIdentifier.invalid
    @ObservationIgnored private var transitionGeneration = UUID()
    @ObservationIgnored private var originalSelection: [URL]?
    @ObservationIgnored private var resumingSharedDraft = false
    @ObservationIgnored private var transferGeneration = UUID()
    @ObservationIgnored private var activeJobID: UUID?
    @ObservationIgnored private var receiveBackgroundRequested = false
    @ObservationIgnored private var receiveBackgroundID: UUID?
    @ObservationIgnored private var isForeground = true
    @ObservationIgnored private var systemProgress = TransferProgress(stage: "preparing_files")
    @ObservationIgnored private var lastBackgroundProgress = Date.distantPast
    var sharingName = "anDrop iPhone"
    @ObservationIgnored private var central: CBCentralManager?
    @ObservationIgnored private var peripheral: CBPeripheralManager?
    @ObservationIgnored private var devices: [UUID: CBPeripheral] = [:]
    @ObservationIgnored private var characteristics: [String: CBMutableCharacteristic] = [:]
    @ObservationIgnored private var fragments: [String: Data] = [:]
    @ObservationIgnored private var notifications: [(Data, CBCentral)] = []
    @ObservationIgnored private var idleKeys = NegotiationKeys()
    @ObservationIgnored private var receiveSession: ReceiveSession?
    @ObservationIgnored private var transferTask: Task<Void, Never>?
    @ObservationIgnored private var deadline: Task<Void, Never>?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var receiver: TransferReceiver?
    @ObservationIgnored private var server: TransferServer?
    @ObservationIgnored private var approval: CheckedContinuation<Bool, Never>?
    @ObservationIgnored private var connected: CBPeripheral?
    @ObservationIgnored private var outgoingChars: [String: CBCharacteristic] = [:]
    @ObservationIgnored private var connecting: CheckedContinuation<Void, any Error>?
    @ObservationIgnored private var reading: CheckedContinuation<Data, any Error>?
    @ObservationIgnored private var writing: CheckedContinuation<Void, any Error>?
    @ObservationIgnored private var notificationReady: CheckedContinuation<Void, any Error>?
    @ObservationIgnored private var stream: AsyncStream<Data>.Continuation?
    @ObservationIgnored private var notificationFragments = Data()
    @ObservationIgnored private var discoveryID = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(6))
    @ObservationIgnored private let logger = Logger(subsystem: "com.takeruf.androp.ios", category: "transfer")
    @ObservationIgnored private let uiTesting = ProcessInfo.processInfo.arguments.contains("--ui-testing")
    var backgroundVerificationEnabled: Bool {
        #if DEBUG && SHARE_EXTENSION
        let preferences = UserDefaults(suiteName: BackgroundTransfer.groupIdentifier)
        return preferences?.bool(forKey: "localBackgroundVerification") == true
            && (preferences?.double(forKey: "localBackgroundVerificationExpiry") ?? 0) > Date().timeIntervalSince1970
        #elseif DEBUG
        return ProcessInfo.processInfo.arguments.contains("--background-transfer-test")
        #else
        return false
        #endif
    }
    @ObservationIgnored private let senderOnly: Bool

    init(senderOnly: Bool = false) {
        self.senderOnly = senderOnly
        super.init()
        huaweiAddress = UserDefaults(suiteName: BackgroundTransfer.groupIdentifier)?.string(forKey: "huaweiManualAddress") ?? ""
        let file = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "received-files.json")
        if let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode([ReceivedFile].self, from: data) {
            receivedFiles = saved.filter { FileManager.default.fileExists(atPath: $0.url.path) }
        }
        if let data = try? Data(contentsOf: diagnosticStorage), let saved = try? JSONDecoder().decode([DiagnosticEvent].self, from: data) { events = Array(saved.suffix(200)) }
    }
    private func saveHistory() {
        do {
            let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try JSONEncoder().encode(receivedFiles).write(to: root.appending(path: "received-files.json"), options: .atomic)
        } catch { record("history_save_failed") }
    }

    var documents: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }
    var destination: URL { documents.appending(path: "Received", directoryHint: .isDirectory) }
    var sortedPeers: [NearbyDevice] { peers.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending } }
    var selectedMIME: String { FileTypes.batchMIME(filenames: selectedFiles.map(\.lastPathComponent)) }
    var progressFraction: Double? {
        guard let transferBytesTotal, transferBytesTotal > 0 else { return nil }
        return min(1, Double(transferredBytes) / Double(transferBytesTotal))
    }
    var versionLabel: String {
        let info = Bundle.main
        return "\(info.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?") (\(info.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"))"
    }
    private var diagnosticStorage: URL { FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "diagnostics.json") }

    func start() {
        guard !enabled else { return }
        enabled = true; errorMessage = nil
        sharingName = UIDevice.current.userInterfaceIdiom == .pad ? "anDrop iPad" : "anDrop iPhone"
        if uiTesting { bluetoothStatus = "Bluetooth disabled for UI tests"; record("ui_test_started"); return }
        if !huaweiAddress.isEmpty { discoverHuawei() }
        #if !SHARE_EXTENSION
        UIApplication.shared.isIdleTimerDisabled = true
        #endif
        if central == nil { central = CBCentralManager(delegate: self, queue: .main) }
        if !senderOnly, peripheral == nil { peripheral = CBPeripheralManager(delegate: self, queue: .main) }
        configureBluetooth()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self, !Task.isCancelled else { return }
                self.peers.removeAll { Date().timeIntervalSince($0.lastSeen) >= ($0.huawei == nil ? 10 : 300) }
                #if !SHARE_EXTENSION
                if isForeground { hasPreparedSend = (try? BackgroundTransfer.store().loadReady()) != nil }
                #endif
            }
        }
        record("foreground_started", fields: ["version": versionLabel, "wifi_ipv4_count": String(min(WiFiIPv4Address.current().count, 16))])
    }
    func enterForeground() {
        isForeground = true; start()
        #if !SHARE_EXTENSION
        resumeReadySharedTransfer()
        #endif
    }
    func enterBackground() {
        isForeground = false
        if busy, execution != nil || transitionTask != .invalid {
            peripheral?.stopAdvertising()
            record("background_transfer_continued")
        } else { stop() }
    }
    func stop() {
        guard enabled else { return }
        enabled = false
        #if !SHARE_EXTENSION
        UIApplication.shared.isIdleTimerDisabled = backgroundVerificationEnabled
        #endif
        cancel(); central?.stopScan(); peripheral?.stopAdvertising()
        huaweiDiscoveryGeneration = UUID(); huaweiDiscoveryTask?.cancel(); huaweiDiscoveryTask = nil; huaweiDiscovering = false
        refreshTask?.cancel(); refreshTask = nil; peers.removeAll(); devices.removeAll()
        bluetoothStatus = "一時停止中"; record("foreground_stopped")
    }
    private func beginTransitionProtection() {
        #if !SHARE_EXTENSION
        guard transitionTask == .invalid else { return }
        let generation = UUID(); transitionGeneration = generation
        transitionTask = UIApplication.shared.beginBackgroundTask(withName: "anDrop transfer setup") { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, transitionGeneration == generation, transitionTask != .invalid else { return }
                cancel(stage: "background_expired")
            }
        }
        #endif
    }
    private func endTransitionProtection() {
        #if !SHARE_EXTENSION
        guard transitionTask != .invalid else { return }
        transitionGeneration = UUID()
        UIApplication.shared.endBackgroundTask(transitionTask); transitionTask = .invalid
        #endif
    }
    private func configureBluetooth() {
        guard enabled else { return }
        if central?.state == .poweredOn {
            central?.scanForPeripherals(withServices: [CBUUID(string: "3333")], options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        }
        if !senderOnly, peripheral?.state == .poweredOn, characteristics.isEmpty {
            let service = CBMutableService(type: CBUUID(string: "9999"), primary: true)
            for (uuid, properties): (String, CBCharacteristicProperties) in [("9898", [.read]), ("9896", [.write, .writeWithoutResponse]), ("9895", [.notify]), ("9984", [.notify]), ("9998", [.read])] {
                characteristics[uuid] = CBMutableCharacteristic(type: CBUUID(string: uuid), properties: properties, value: nil, permissions: [.readable, .writeable])
            }
            service.characteristics = Array(characteristics.values); peripheral?.add(service)
        } else if !senderOnly, peripheral?.state == .poweredOn { advertise() }
        bluetoothStatus = central?.state == .poweredOn && (senderOnly || peripheral?.state == .poweredOn) ? "近くの端末を検索中" : Self.stateText(central?.state ?? .unknown)
    }
    private static func stateText(_ state: CBManagerState) -> String {
        switch state {
        case .poweredOn: "Bluetooth準備完了"
        case .poweredOff: "Bluetoothをオンにしてください"
        case .unauthorized: "設定でBluetoothを許可してください"
        case .unsupported: "この端末ではBluetoothを使用できません"
        case .resetting: "Bluetoothを再起動中"
        default: "Bluetoothを準備中…"
        }
    }
    private func advertise() {
        guard !senderOnly, isForeground, enabled, peripheral?.state == .poweredOn, peripheral?.isAdvertising != true else { return }
        peripheral?.startAdvertising([CBAdvertisementDataLocalNameKey: discoveryID + "B" + String(sharingName.prefix(15)), CBAdvertisementDataServiceUUIDsKey: [CBUUID(string: "8881")]])
    }
    func record(_ code: String, fields: [String: String]? = nil) {
        var fields = fields
        if backgroundVerificationEnabled { fields = (fields ?? [:]).merging(["verification": "local"], uniquingKeysWith: { _, new in new }) }
        events.append(DiagnosticEvent(id: UUID(), time: Date(), stage: code, fields: fields))
        if events.count > 200 { events.removeFirst(events.count - 200) }
        logger.notice("Stage: \(code, privacy: .public)")
        if let title = Self.stageTitle(code) {
            stage = title
            if busy, !["foreground_started", "foreground_stopped", "ui_test_started"].contains(code) {
                systemProgress.stage = code; updateSystemProgress()
            }
        }
        if !uiTesting || backgroundVerificationEnabled {
            do {
                try FileManager.default.createDirectory(at: diagnosticStorage.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONEncoder().encode(events).write(to: diagnosticStorage, options: .atomic)
            } catch { logger.error("Could not save diagnostics.") }
        }
    }
    private static func stageTitle(_ code: String) -> String? {
        switch code {
        case "foreground_started", "foreground_stopped", "ui_test_started": "準備完了"
        case "preparing_files": "ファイルを準備中"
        case "connecting_bluetooth": "Bluetoothで接続中"
        case "key_exchange": "セッション鍵を交換中"
        case "huawei_authenticating": "Huawei Shareに接続中"
        case "waiting_for_recipient", "awaiting_acceptance": "相手の受信許可を待っています"
        case "negotiating_network": "Wi-Fi接続を交渉中"
        case "connecting_control": "暗号化接続を開始中"
        case "control_connected": "暗号化接続が完了"
        case "awaiting_approval": "受信を許可してください"
        case "sending_archive": "ファイルを送信中"
        case "downloading_archive": "ファイルを受信中"
        case "checking_archive": "ファイルの整合性を確認中"
        case "awaiting_confirmation": "相手の完了確認を待っています"
        case "receive_complete": "受信・整合性確認が完了"
        case "send_complete": "相手の受信完了を確認しました"
        case "cancelled": "キャンセルしました"
        case "failed": "転送に失敗しました"
        case "declined": "転送が拒否またはキャンセルされました"
        case "send_unconfirmed": "相手の受信完了を確認できませんでした"
        case "background_expired": "バックグラウンド転送が中止されました"
        default: nil
        }
    }
    func makeSample() {
        do {
            let root = documents.appending(path: "Samples", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let file = root.appending(path: "anDrop-test.txt")
            try Data("anDrop iOS interoperability test\nUTF-8: 日本語・中文\n\(UUID().uuidString)\n".utf8).write(to: file, options: .atomic)
            selectedFiles = [file]; errorMessage = nil
        } catch { errorMessage = "Could not prepare the test file." }
    }
    func chooseFiles(_ result: Result<[URL], any Error>) {
        switch result {
        case .success(let urls): selectedFiles = urls; errorMessage = nil
        case .failure: errorMessage = "Could not access the selected files."
        }
    }
    func diagnosticURL() -> URL? {
        do {
            try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
            let output = documents.appending(path: "anDrop-diagnostics.json")
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(events).write(to: output, options: .atomic)
            return output
        } catch { errorMessage = "Could not export diagnostics."; return nil }
    }
    func decide(_ accepted: Bool) {
        #if !SHARE_EXTENSION
        if accepted, let incoming, approval != nil, #available(iOS 26.0, *) {
            guard !receiveBackgroundRequested else { return }
            receiveBackgroundRequested = true
            beginTransitionProtection()
            let requestID = UUID(); receiveBackgroundID = requestID
            Task { [weak self] in
                guard let self else { return }
                do {
                    try await BackgroundTransfer.submit(id: requestID, title: "anDrop・\(incoming.count)ファイルを受信", subtitle: "受信を準備中")
                } catch {
                    guard receiveBackgroundRequested, receiveBackgroundID == requestID else { return }
                    record("background_submission_failed", fields: ["code": String((error as NSError).code)])
                    backgroundNotice = "バックグラウンド転送を開始できませんでした。完了までanDropを開いてください。"
                    endTransitionProtection()
                    if !isForeground { cancel(stage: "background_expired"); return }
                    receiveBackgroundRequested = false; resumeApproval(true)
                }
            }
            return
        }
        #endif
        receiveBackgroundRequested = false; resumeApproval(accepted)
    }
    private func resumeApproval(_ accepted: Bool) { let pending = approval; approval = nil; incoming = nil; pending?.resume(returning: accepted) }
    private func requestApproval(_ offer: IncomingOffer) async -> Bool {
        guard !Task.isCancelled else { return false }
        return await withCheckedContinuation { continuation in
            approval = continuation; incoming = offer
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(25))
                if self?.incoming?.id == offer.id { self?.decide(false) }
            }
        }
    }
    func cancel(stage code: String = "cancelled") {
        let wasBusy = busy
        if let session = receiveSession { notify(Data("cancel".utf8), to: session.central) }
        transferTask?.cancel(); transferTask = nil
        if wasBusy { record(code) }
        cleanup()
    }
    private func cleanup() {
        transferGeneration = UUID()
        deadline?.cancel(); deadline = nil
        receiver?.stop(); receiver = nil; server?.stop(); server = nil
        huaweiSender?.stop(); huaweiSender = nil
        receiveBackgroundRequested = false; resumeApproval(false)
        connecting?.resume(throwing: TransferFailure.closed); connecting = nil
        reading?.resume(throwing: TransferFailure.closed); reading = nil
        writing?.resume(throwing: TransferFailure.closed); writing = nil
        notificationReady?.resume(throwing: TransferFailure.closed); notificationReady = nil
        stream?.finish(); stream = nil; notificationFragments.removeAll()
        if let connected { central?.cancelPeripheralConnection(connected) }; connected = nil; outgoingChars.removeAll()
        receiveSession = nil; fragments.removeAll(); notifications.removeAll(); idleKeys = NegotiationKeys(); busy = false
        if execution != nil { record("background_transfer_finished", fields: ["succeeded": String(systemProgress.succeeded), "background": String(!isForeground)]) }
        let hadStagedFiles = activeJobID != nil
        if let id = activeJobID { try? BackgroundTransfer.store().remove(id: id); activeJobID = nil }
        if let originalSelection { selectedFiles = originalSelection; self.originalSelection = nil }
        else if hadStagedFiles { selectedFiles = [] }
        execution?.finish(success: systemProgress.succeeded); execution = nil
        endTransitionProtection()
        transferredBytes = 0; transferBytesTotal = nil
        if !isForeground, enabled { let finalStage = stage; stop(); stage = finalStage }
    }
    private func fail(_ error: any Error) {
        if Task.isCancelled { return }
        if let session = receiveSession { notify(Data("cancel".utf8), to: session.central) }
        if let routeError = error as? SendRouteError { record("send_route_rejected", fields: ["reason": routeError.rawValue]) }
        errorMessage = (error as? HuaweiFailure)?.errorDescription ?? (error as? SendRouteError)?.errorDescription ?? (error as? ReceiveRouteError)?.errorDescription ?? (error as? TransferFailure)?.errorDescription ?? "接続に失敗しました。相手の共有画面を開いたまま、ローカルネットワーク権限と診断ログを確認してください。"
        if let failure = error as? TransferFailure, case .declined = failure { record("declined") }
        else if let failure = error as? TransferFailure, case .completionUnconfirmed = failure { record("send_unconfirmed") }
        else { record("failed") }
        transferTask?.cancel(); cleanup()
    }
    private func armDeadline(seconds: Int = 90) {
        deadline?.cancel()
        deadline = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(seconds))
                self?.fail(self?.server?.awaitingConfirmation == true ? TransferFailure.completionUnconfirmed : TransferFailure.timeout)
            } catch { }
        }
    }
    private func notify(_ value: Data, to central: CBCentral) {
        guard let characteristic = characteristics["9895"] else { return }
        for offset in stride(from: 0, to: value.count, by: central.maximumUpdateValueLength) {
            notifications.append((Data(value[offset..<min(offset + central.maximumUpdateValueLength, value.count)]), central))
        }
        while let first = notifications.first {
            guard peripheral?.updateValue(first.0, for: characteristic, onSubscribedCentrals: [first.1]) == true else { return }
            notifications.removeFirst()
        }
    }
    private func notifyJSON(_ value: [String: Any], to central: CBCentral) throws { notify(try JSONSerialization.data(withJSONObject: value), to: central) }
    private func handleWrite(_ data: Data, from central: CBCentral) throws {
        guard enabled, let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw TransferFailure.invalid("Invalid Bluetooth message.") }
        if let peerKey = payload["key"] as? String {
            guard !busy else { notify(Data("3".utf8), to: central); return }
            var keys = idleKeys; try keys.derive(peer: peerKey)
            guard let raw = payload["number"] as? String, let count = Int(try keys.decrypt(raw)), (1...Limits.files).contains(count) else { throw TransferFailure.invalid("This prototype supports 1–16 files.") }
            let initialHint = try (payload["ip"] as? String).map { try keys.decrypt($0) }
            receiveSession = ReceiveSession(central: central, keys: keys, count: count, initialHint: initialHint)
            busy = true; record("key_exchange", fields: ["has_initial_hint": String(receiveSession?.routePlanner.initialHint != nil)])
            notify(Data("6".utf8), to: central); armDeadline(); return
        }
        guard let session = receiveSession, session.central.identifier == central.identifier else { return }
        guard !session.channelConnected else { return }
        let offer = try ReceiveNetworkOffer(payload: payload, keys: session.keys)
        let interfaces = WiFiIPv4Address.current()
        record("receive_network_offer", fields: session.routePlanner.diagnosticFields(for: offer, interfaces: interfaces))
        let selected: ReceiveRoute
        do {
            guard let result = try session.routePlanner.resolve(offer, interfaces: interfaces) else { return }
            selected = result
        } catch let error as ReceiveRouteError {
            record("receive_route_rejected", fields: ["reason": error.rawValue]); throw error
        }
        let host = selected.host; let port = selected.port; let local = selected.localAddress
        record("receive_route_selected", fields: ["source": selected.source.rawValue])
        if let route = session.route, route.0 == host, route.1 == port { return }
        guard session.routeChanges < 4 else { throw TransferFailure.invalid("The sender changed its network endpoint too often.") }
        session.routeChanges += 1; session.route = (host, port)
        transferTask?.cancel(); receiver?.stop()
        let receiver = TransferReceiver(); self.receiver = receiver
        receiver.onProgress = { [weak self, weak receiver] completed, total in
            guard let self, let receiver, self.receiver === receiver else { return }
            self.transferredBytes = completed; self.transferBytesTotal = total
        }
        receiver.onStage = { [weak self, weak session, weak receiver] code in
            guard let self, let session, let receiver, self.receiveSession === session, self.receiver === receiver else { return }
            if code == "control_connected" { session.channelConnected = true }
            self.record(code)
        }
        if selected.acknowledgeLAN { try notifyJSON(["wlan": "wlan", "wlan_accept": true, "ip": session.keys.encrypt(local)], to: central) }
        record("negotiating_network")
        transferTask = Task { [weak self, weak session] in
            guard let self, let session else { return }
            do {
                let saved = try await receiver.receive(host: host, port: port, expectedCount: session.count, destination: destination, approve: { [weak self] offer in await self?.requestApproval(offer) ?? false })
                guard !Task.isCancelled, receiveSession === session else { return }
                receivedFiles.insert(contentsOf: saved, at: 0); saveHistory(); cleanup()
            } catch { if !Task.isCancelled, receiveSession === session { fail(error) } }
        }
    }
    func send(to peer: NearbyDevice) {
        guard enabled, !busy, !selectedFiles.isEmpty else { return }
        #if SHARE_EXTENSION
        sendDirect(to: peer)
        #else
        if #available(iOS 26.0, *) {
            busy = true; errorMessage = nil; backgroundNotice = nil
            originalSelection = selectedFiles
            let generation = UUID(); transferGeneration = generation
            beginTransitionProtection()
            systemProgress = TransferProgress(stage: "preparing_files"); record("preparing_files")
            armDeadline(seconds: 120)
            transferTask = Task { [weak self] in
                guard let self else { return }
                var stagedJob: UUID?
                do {
                    let store = try BackgroundTransfer.store()
                    let recipient = TransferRecipient(peripheralID: peer.id, discoveryID: peer.discoveryID, name: peer.name, huawei: peer.huawei)
                    let job = try await store.enqueue(selectedFiles, recipient: recipient); stagedJob = job.id
                    guard transferGeneration == generation else { store.remove(id: job.id); return }
                    record("background_handoff_staged", fields: BackgroundTransfer.storeDiagnostics())
                    try Task.checkCancellation()
                    activeJobID = job.id
                    try await BackgroundTransfer.submit(id: job.id, title: "anDrop・\(job.names.count)ファイルを送信", subtitle: "送信を準備中")
                    guard transferGeneration == generation else { return }
                    record("background_submitted")
                } catch {
                    if let id = stagedJob { try? BackgroundTransfer.store().remove(id: id) }
                    guard transferGeneration == generation else { return }
                    activeJobID = nil
                    endTransitionProtection()
                    guard !Task.isCancelled else { return }
                    record("background_submission_failed", fields: ["code": String((error as NSError).code)])
                    if let jobError = error as? BackgroundSendJobError, case .busy = jobError {
                        errorMessage = jobError.errorDescription; record("failed"); cleanup(); return
                    }
                    backgroundNotice = "バックグラウンド転送を開始できませんでした。完了までこの画面を開いてください。"
                    if !isForeground { cancel(stage: "background_expired"); return }
                    busy = false; sendDirect(to: peer)
                }
            }
        } else { sendDirect(to: peer) }
        #endif
    }
    func prepareSharedDraft() async throws {
        guard #available(iOS 26.0, *) else { return }
        handoffPreparing = true
        defer { handoffPreparing = false }
        let store = try BackgroundTransfer.store()
        let job = try await store.enqueue(selectedFiles, recipient: .init(peripheralID: UUID(), discoveryID: "", name: ""))
        sharedDraftID = job.id
        do { try Task.checkCancellation() }
        catch { store.remove(id: job.id); sharedDraftID = nil; throw error }
        record("background_draft_prepared", fields: BackgroundTransfer.storeDiagnostics())
    }
    func discardSharedDraft() {
        if let id = sharedDraftID { try? BackgroundTransfer.store().remove(id: id); sharedDraftID = nil }
    }
    func selectSharedRecipient(_ peer: NearbyDevice) {
        guard let id = sharedDraftID, !handoffRequested else { return }
        do {
            try BackgroundTransfer.store().selectRecipient(id: id, recipient: .init(peripheralID: peer.id, discoveryID: peer.discoveryID, name: peer.name, huawei: peer.huawei))
            handoffRequested = true
            stage = "anDrop本体を開くと送信を開始します"
            record("shared_transfer_ready", fields: ["count": String(selectedFiles.count)])
        } catch { errorMessage = (error as? BackgroundSendJobError)?.errorDescription ?? "転送を準備できませんでした。もう一度共有してください。" }
    }
    private func updateSystemProgress() {
        systemProgress.completedBytes = transferredBytes; systemProgress.totalBytes = transferBytesTotal
        execution?.update(systemProgress)
        if !isForeground, execution != nil, transferredBytes > 0, Date().timeIntervalSince(lastBackgroundProgress) >= 1 {
            lastBackgroundProgress = Date()
            record("background_progress", fields: ["completed_bytes": String(transferredBytes), "total_bytes": String(transferBytesTotal ?? 0)])
        }
    }
    #if !SHARE_EXTENSION
    func startPreparedSend() { resumeReadySharedTransfer() }
    private func resumeReadySharedTransfer() {
        guard !busy, !resumingSharedDraft, #available(iOS 26.0, *), let (job, _) = try? BackgroundTransfer.store().loadReady() else { return }
        resumingSharedDraft = true
        hasPreparedSend = false
        transferTask = Task { [weak self] in
            guard let self else { return }
            defer { resumingSharedDraft = false }
            do { try await beginPreparedSharedSend(id: job.id, recipient: job.recipient) }
            catch { fail(error) }
        }
    }
    @available(iOS 26.0, *) func beginPreparedSharedSend(id: UUID, recipient: TransferRecipient) async throws {
        guard !busy else { throw BackgroundSendJobError.busy }
        for _ in 0..<50 {
            if UIApplication.shared.applicationState == .active { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        guard !busy else { throw BackgroundSendJobError.busy }
        let store = try BackgroundTransfer.store()
        try store.selectRecipient(id: id, recipient: recipient)
        let (job, files) = try store.load()
        let generation = UUID(); transferGeneration = generation
        beginTransitionProtection()
        activeJobID = job.id; selectedFiles = files; busy = true; errorMessage = nil
        systemProgress = TransferProgress(stage: "preparing_files"); start(); record("preparing_files"); armDeadline(seconds: 120)
        do {
            try await BackgroundTransfer.submit(id: id, title: "anDrop・\(job.names.count)ファイルを送信", subtitle: "送信を準備中")
            guard transferGeneration == generation else { return }
            record("shared_transfer_submitted")
        } catch {
            guard transferGeneration == generation else { return }
            endTransitionProtection()
            record("background_submission_failed", fields: ["code": String((error as NSError).code)])
            backgroundNotice = "バックグラウンド転送を開始できませんでした。完了までanDropを開いてください。"
            if !isForeground { cancel(stage: "background_expired"); return }
            if backgroundVerificationEnabled, job.recipient.discoveryID == "local-verification" { runBackgroundVerification(files: files) }
            else { waitForRecipient(job) }
        }
    }
    @available(iOS 26.0, *) func handleBackgroundTransfer(_ task: BGContinuedProcessingTask) {
        guard execution == nil else { task.setTaskCompleted(success: false); return }
        isForeground = UIApplication.shared.applicationState != .background
        let handle = ContinuedTransferExecution(task: task) { [weak self] in
            self?.errorMessage = "iOSまたはユーザーによってバックグラウンド転送が中止されました。"
            self?.cancel(stage: "background_expired")
        }
        let requestID = task.identifier.hasPrefix(BackgroundTransfer.prefix + ".") ? UUID(uuidString: String(task.identifier.dropFirst(BackgroundTransfer.prefix.count + 1))) : nil
        record("background_task_delivered", fields: BackgroundTransfer.storeDiagnostics())
        if receiveBackgroundRequested, receiveBackgroundID == requestID, approval != nil {
            execution = handle; receiveBackgroundRequested = false
            endTransitionProtection()
            record("background_task_started", fields: ["direction": "receive"])
            resumeApproval(true); return
        }
        do {
            let (job, files) = try BackgroundTransfer.store().load()
            guard job.id == requestID else { handle.finish(success: false); return }
            guard !busy || activeJobID == job.id else { throw BackgroundSendJobError.busy }
            try BackgroundTransfer.store().markStarted(id: job.id)
            activeJobID = job.id; execution = handle; selectedFiles = files
            endTransitionProtection()
            let connectionStage = job.recipient.huawei == nil ? "connecting_bluetooth" : "huawei_authenticating"
            busy = true; systemProgress = TransferProgress(stage: connectionStage)
            start(); record("background_task_started", fields: ["direction": "send", "count": String(files.count)])
            record(connectionStage); armDeadline(seconds: 120)
            if backgroundVerificationEnabled, job.recipient.discoveryID == "local-verification" {
                runBackgroundVerification(files: files)
                return
            }
            waitForRecipient(job)
        } catch {
            handle.finish(success: false)
            if requestID == activeJobID { fail(error) }
            else if let job = try? BackgroundTransfer.store().load().0, job.id == requestID { try? BackgroundTransfer.store().remove(id: job.id) }
            record("background_task_rejected", fields: ["code": String((error as NSError).code)])
        }
    }
    private func waitForRecipient(_ job: BackgroundSendJob) {
        if let huawei = job.recipient.huawei { sendHuawei(huawei); return }
        transferTask = Task { [weak self] in
                guard let self else { return }
                do {
                    for _ in 0..<200 {
                        try Task.checkCancellation()
                        if let peer = peers.first(where: { job.recipient.discoveryID.isEmpty ? $0.id == job.recipient.peripheralID : $0.discoveryID == job.recipient.discoveryID }) {
                            busy = false; sendDirect(to: peer); return
                        }
                        try await Task.sleep(for: .milliseconds(100))
                    }
                    throw TransferFailure.timeout
                } catch { if !Task.isCancelled { fail(error) } }
        }
    }
    func startBackgroundVerification() {
        guard backgroundVerificationEnabled, !busy else { return }
        backgroundVerificationResult = nil
        do {
            let root = FileManager.default.temporaryDirectory.appending(path: "anDrop-BackgroundQA", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let file = root.appending(path: "background-verification.bin")
            try Data(repeating: 37, count: 20 * 1024 * 1024).write(to: file)
            selectedFiles = [file]; start()
            send(to: NearbyDevice(id: UUID(), name: "ローカル転送テスト", lastSeen: Date(), discoveryID: "local-verification"))
        } catch { fail(error) }
    }
    func startBackgroundReceiveVerification() {
        guard backgroundVerificationEnabled, !busy else { return }
        backgroundVerificationResult = nil; start(); busy = true
        systemProgress = TransferProgress(stage: "preparing_files"); record("preparing_files"); armDeadline(seconds: 120)
        transferTask = Task { [weak self] in
            guard let self else { return }
            do {
                guard let network = WiFiIPv4Address.current().first(where: { LocalNetwork.isPrivateIPv4($0.address) }) else { throw SendRouteError.noWiFiIPv4 }
                let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: root) }
                let file = root.appending(path: "background-receive-verification.bin")
                try Data(repeating: 59, count: 20 * 1024 * 1024).write(to: file)
                let prepared = try await FileArchive.prepare([file])
                let server = try TransferServer(files: prepared, senderName: "Local verification", network: network, minimumChunkInterval: .milliseconds(60)); self.server = server
                server.onFailure = { [weak self] in self?.fail($0) }
                try server.confirmPeer(network.address); try await server.start()
                let receiver = TransferReceiver(); self.receiver = receiver
                receiver.onStage = { [weak self] in self?.record($0) }
                receiver.onProgress = { [weak self] in self?.transferredBytes = $0; self?.transferBytesTotal = $1 }
                let received = try await receiver.receive(host: network.address, port: server.port, expectedCount: 1, destination: root.appending(path: "received")) { [weak self] offer in
                    await self?.requestApproval(offer) ?? false
                }
                guard received.count == 1, try Data(contentsOf: received[0].url) == Data(contentsOf: file) else { throw TransferFailure.invalid("Local receive verification mismatch.") }
                backgroundVerificationResult = isForeground ? "前面で受信完了" : "バックグラウンドで受信完了"
                record("background_verification_complete", fields: ["background": String(!isForeground), "direction": "receive"]); cleanup()
            } catch { if !Task.isCancelled { fail(error) } }
        }
    }
    private func runBackgroundVerification(files: [URL]) {
        transferTask = Task { [weak self] in
            guard let self else { return }
            do {
                guard let network = WiFiIPv4Address.current().first(where: { LocalNetwork.isPrivateIPv4($0.address) }) else { throw SendRouteError.noWiFiIPv4 }
                let prepared = try await FileArchive.prepare(files)
                let server = try TransferServer(files: prepared, senderName: "Local verification", network: network, minimumChunkInterval: .milliseconds(60))
                self.server = server
                server.onStage = { [weak self] in self?.record($0) }
                server.onProgress = { [weak self] in self?.transferredBytes = $0; self?.transferBytesTotal = $1 }
                server.onFailure = { [weak self] in self?.fail($0) }
                try server.confirmPeer(network.address); try await server.start()
                let receiver = TransferReceiver(); self.receiver = receiver
                let destination = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
                defer { try? FileManager.default.removeItem(at: destination) }
                let received = try await receiver.receive(host: network.address, port: server.port, expectedCount: prepared.count, destination: destination) { _ in true }
                guard received.count == 1, try Data(contentsOf: received[0].url) == Data(contentsOf: files[0]) else { throw TransferFailure.invalid("Local verification mismatch.") }
                for _ in 0..<20 { if systemProgress.succeeded { break }; try await Task.sleep(for: .milliseconds(100)) }
                guard systemProgress.succeeded else { throw TransferFailure.completionUnconfirmed }
                backgroundVerificationResult = isForeground ? "前面で転送完了" : "バックグラウンドで転送完了"
                record("background_verification_complete", fields: ["background": String(!isForeground)]); cleanup()
            } catch { if !Task.isCancelled { fail(error) } }
        }
    }
    #endif
    func discoverHuawei() {
        guard !busy, !huaweiDiscovering else { return }
        let host = huaweiAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let network = WiFiIPv4Address.current().first(where: { $0.reaches(host) }) else {
            huaweiStatus = HuaweiFailure.target.errorDescription; return
        }
        if !enabled { start(); return }
        huaweiDiscovering = true; huaweiStatus = "指定したHuawei端末を確認中"
        let generation = UUID(); huaweiDiscoveryGeneration = generation
        huaweiDiscoveryTask = Task { [weak self] in
            guard let self else { return }
            defer { if huaweiDiscoveryGeneration == generation { huaweiDiscovering = false } }
            do {
                let peer = try await HuaweiDiscovery.find(host: host, network: network, name: sharingName)
                try Task.checkCancellation(); guard huaweiDiscoveryGeneration == generation else { return }
                peers.removeAll { $0.huawei?.host == host }
                peers.append(.init(id: UUID(), name: String(peer.name.prefix(70)) + " · Huawei Share（試験）", lastSeen: Date(), discoveryID: peer.discoveryID, huawei: peer))
                huaweiAddress = host; huaweiStatus = "送信先に追加しました。ファイルを選んで端末を押してください。"
                UserDefaults(suiteName: BackgroundTransfer.groupIdentifier)?.set(host, forKey: "huaweiManualAddress")
                record("huawei_discovered")
            } catch {
                guard !Task.isCancelled, huaweiDiscoveryGeneration == generation else { return }
                huaweiStatus = (error as? HuaweiFailure)?.errorDescription ?? HuaweiFailure.discovery.errorDescription
                record("huawei_discovery_failed", fields: ["code": String((error as NSError).code)])
            }
        }
    }
    func forgetHuawei() {
        guard !busy else { return }
        huaweiDiscoveryGeneration = UUID(); huaweiDiscoveryTask?.cancel(); huaweiDiscoveryTask = nil
        huaweiDiscovering = false; huaweiAddress = ""; huaweiStatus = nil
        peers.removeAll { $0.huawei != nil }
        UserDefaults(suiteName: BackgroundTransfer.groupIdentifier)?.removeObject(forKey: "huaweiManualAddress")
    }
    private func sendHuawei(_ peer: HuaweiPeer) {
        busy = true; errorMessage = nil; record("huawei_authenticating"); armDeadline(seconds: 120)
        let files = selectedFiles; let generation = transferGeneration
        let pendingDiscovery = huaweiDiscoveryTask
        transferTask = Task { [weak self] in
            guard let self else { return }
            let access = files.filter { $0.startAccessingSecurityScopedResource() }
            defer { access.forEach { $0.stopAccessingSecurityScopedResource() } }
            do {
                await pendingDiscovery?.value
                try Task.checkCancellation(); guard transferGeneration == generation else { return }
                guard let network = WiFiIPv4Address.current().first(where: { $0.reaches(peer.host) }) else { throw HuaweiFailure.target }
                let current: HuaweiPeer
                if let cached = peers.first(where: { $0.huawei?.host == peer.host && Date().timeIntervalSince($0.lastSeen) < 10 })?.huawei { current = cached }
                else { current = try await HuaweiDiscovery.find(host: peer.host, network: network, name: sharingName) }
                try Task.checkCancellation(); guard transferGeneration == generation else { return }
                guard current.discoveryID == peer.discoveryID else { throw HuaweiFailure.target }
                let identity = try HuaweiIdentity(tag: "com.takeruf.androp.ios.huawei-identity")
                let sender = HuaweiSender(); huaweiSender = sender
                sender.onStage = { [weak self, weak sender] code in
                    guard let self, let sender, huaweiSender === sender else { return }; record(code)
                }
                sender.onProgress = { [weak self, weak sender] completed, total in
                    guard let self, let sender, huaweiSender === sender else { return }
                    transferredBytes = completed; transferBytesTotal = total
                }
                record("huawei_send_started", fields: ["count": String(files.count)])
                try await sender.send(files: files, peer: current, network: network, identity: identity, senderName: sharingName, deviceType: UIDevice.current.userInterfaceIdiom == .pad ? 17 : 14)
                guard !Task.isCancelled, transferGeneration == generation else { return }
                cleanup()
            } catch { if !Task.isCancelled, transferGeneration == generation { fail(error) } }
        }
    }
    private func sendDirect(to peer: NearbyDevice) {
        if let huawei = peer.huawei, enabled, !busy, !selectedFiles.isEmpty { sendHuawei(huawei); return }
        guard enabled, !busy, !selectedFiles.isEmpty, let device = devices[peer.id] else { return }
        busy = true; errorMessage = nil; record("preparing_files"); armDeadline(seconds: 120)
        transferTask = Task { [self] in
            do {
                let files = try await FileArchive.prepare(selectedFiles)
                record("send_file_metadata", fields: ["mime": files.mime, "count": String(files.count), "size_bytes": String(files.total)])
                var candidates: [SendRouteCandidate] = []
                var candidateIndex = 0
                try Task.checkCancellation()
                record("connecting_bluetooth"); device.delegate = self; connected = device
                try await withCheckedThrowingContinuation { connecting = $0; central?.connect(device) }
                guard let stateCharacteristic = outgoingChars["9897"], let notifyCharacteristic = outgoingChars["9898"], let writeCharacteristic = outgoingChars["9896"] else { throw TransferFailure.invalid("The device has no compatible sharing service.") }
                let stateData: Data = try await withCheckedThrowingContinuation { reading = $0; device.readValue(for: stateCharacteristic) }
                guard let state = try JSONSerialization.jsonObject(with: stateData) as? [String: Any], state["state"] as? Int == 0, let peerKey = state["key"] as? String else { throw TransferFailure.invalid("The receiving device is busy.") }
                var keys = NegotiationKeys(); try keys.derive(peer: peerKey)
                @MainActor func offerAddress(_ candidate: SendRouteCandidate) async throws {
                    self.server?.stop()
                    let server = try TransferServer(files: files, senderName: sharingName, network: candidate.network); self.server = server
                    server.onStage = { [weak self] in self?.record($0) }
                    server.onProgress = { [weak self] in self?.transferredBytes = $0; self?.transferBytesTotal = $1 }
                    server.onFailure = { [weak self] in self?.fail($0) }
                    server.onComplete = { [weak self, weak server] in
                        Task { @MainActor [weak self, weak server] in
                            try? await Task.sleep(for: .milliseconds(500))
                            guard let self, let server, self.server === server else { return }
                            cleanup()
                        }
                    }
                    try await server.start()
                    record("send_address_selected", fields: ["source": candidate.source.rawValue, "candidate_index": String(candidateIndex + 1)])
                    record("negotiating_network")
                    try await write(["wlan": "wlan", "ip": keys.encrypt(candidate.network.address), "port": keys.encrypt(String(server.port))], device: device, characteristic: writeCharacteristic)
                }
                let notifications = AsyncStream<Data> { stream = $0 }
                try await withCheckedThrowingContinuation { notificationReady = $0; device.setNotifyValue(true, for: notifyCharacteristic) }
                record("key_exchange")
                try await write(files.bluetoothOffer(keys: keys, senderName: sharingName), device: device, characteristic: writeCharacteristic)
                record("waiting_for_recipient")
                for await bytes in notifications {
                    try Task.checkCancellation()
                    if bytes == Data("3".utf8) || bytes == Data("cancel".utf8) { throw TransferFailure.declined }
                    guard let value = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { continue }
                    if value["wlan"] != nil, value["wlan_accept"] == nil, let raw = value["ip"] as? String {
                        guard server == nil else { continue }
                        let hint = try keys.decrypt(raw); let interfaces = WiFiIPv4Address.current()
                        record("send_network_offer", fields: SendRoutePlanner.diagnostics(peerHint: hint, interfaces: interfaces))
                        candidates = SendRoutePlanner.candidates(peerHint: hint, interfaces: interfaces)
                        guard let candidate = candidates.first else { throw SendRouteError.noWiFiIPv4 }
                        try await offerAddress(candidate)
                    } else if let accepted = value["wlan_accept"] as? Bool {
                        record("send_network_confirmation", fields: ["accepted": String(accepted)])
                        guard let server else { throw SendRouteError.invalidConfirmation }
                        if !accepted {
                            candidateIndex += 1
                            guard candidateIndex < candidates.count else { throw SendRouteError.rejected }
                            try await offerAddress(candidates[candidateIndex]); continue
                        }
                        guard let raw = value["ip"] as? String else { throw SendRouteError.invalidConfirmation }
                        try server.confirmPeer(keys.decrypt(raw))
                    }
                }
            } catch { if !Task.isCancelled, busy { fail(error) } }
        }
    }
    private func write(_ value: [String: Any], device: CBPeripheral, characteristic: CBCharacteristic) async throws {
        let bytes = try JSONSerialization.data(withJSONObject: value, options: [.withoutEscapingSlashes])
        try await withCheckedThrowingContinuation { writing = $0; device.writeValue(bytes, for: characteristic, type: .withResponse) }
    }
}

extension SharingModel: @preconcurrency CBPeripheralManagerDelegate {
    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        if peripheral.state != .poweredOn { characteristics.removeAll(); if busy { cancel() } }
        configureBluetooth()
    }
    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: (any Error)?) {
        if let error { fail(error) } else { advertise() }
    }
    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: (any Error)?) {
        if let error { fail(error) } else { record("advertising_started") }
    }
    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
        guard enabled else { peripheral.respond(to: request, withResult: .insufficientAuthorization); return }
        do {
            let value = request.characteristic.uuid == CBUUID(string: "9898") ? try JSONSerialization.data(withJSONObject: ["state": busy ? 1 : 0, "key": idleKeys.publicKey, "version": "10014", "isFast": 0, "pv": 4]) : Data()
            guard request.offset <= value.count else { peripheral.respond(to: request, withResult: .invalidOffset); return }
            request.value = Data(value.dropFirst(request.offset)); peripheral.respond(to: request, withResult: .success)
            if request.offset == 0 { record("ble_state_read") }
        } catch { peripheral.respond(to: request, withResult: .unlikelyError) }
    }
    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        guard let first = requests.first else { return }
        guard enabled, requests.allSatisfy({ $0.characteristic.uuid == CBUUID(string: "9896") && (!busy || receiveSession?.central.identifier == $0.central.identifier) }) else { peripheral.respond(to: first, withResult: .insufficientAuthorization); return }
        do {
            for request in requests {
                let id = request.central.identifier.uuidString
                if request.offset == 0 { fragments[id] = Data() }
                guard var value = fragments[id], request.offset == value.count, value.count + (request.value?.count ?? 0) <= 65536 else { throw TransferFailure.invalid("Invalid Bluetooth fragment.") }
                value.append(request.value ?? Data()); fragments[id] = value
                if (try? JSONSerialization.jsonObject(with: value)) != nil { fragments[id] = nil; try handleWrite(value, from: request.central) }
                guard fragments.count <= 8 else { throw TransferFailure.invalid("Too many Bluetooth requests.") }
            }
            peripheral.respond(to: first, withResult: .success)
        } catch { peripheral.respond(to: first, withResult: .unlikelyError); fail(error) }
    }
    func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
        guard let characteristic = characteristics["9895"] else { return }
        while let first = notifications.first {
            guard peripheral.updateValue(first.0, for: characteristic, onSubscribedCentrals: [first.1]) else { break }
            notifications.removeFirst()
        }
    }
    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didSubscribeTo characteristic: CBCharacteristic) {
        record("ble_subscribed")
    }
}

extension SharingModel: @preconcurrency CBCentralManagerDelegate, @preconcurrency CBPeripheralDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) { configureBluetooth() }
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard enabled, let services = advertisementData[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data], let identity = services[CBUUID(string: "3333")], let text = String(data: identity, encoding: .utf8) else { return }
        let fields = text.split(separator: "-", omittingEmptySubsequences: false)
        guard text.count >= 14, fields.count >= 2, ["r", "sr"].contains(fields[1]) else { peers.removeAll { $0.id == peripheral.identifier }; return }
        let name = services[CBUUID(string: "3334")].flatMap { String(data: $0, encoding: .utf8) }?.trimmingCharacters(in: .controlCharacters) ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? "Android"
        devices[peripheral.identifier] = peripheral
        let peer = NearbyDevice(id: peripheral.identifier, name: String(name.prefix(100)), lastSeen: Date(), discoveryID: String(fields[0].prefix(100)))
        if let index = peers.firstIndex(where: { $0.id == peer.id }) { peers[index] = peer } else { peers.append(peer) }
    }
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) { peripheral.discoverServices([CBUUID(string: "9999")]) }
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: (any Error)?) { fail(error ?? TransferFailure.closed) }
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: (any Error)?) {
        if connected === peripheral, busy, server == nil { fail(error ?? TransferFailure.closed) }
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: (any Error)?) {
        if let error { fail(error); return }
        guard let services = peripheral.services, !services.isEmpty else { fail(TransferFailure.invalid("No Bluetooth sharing service.")); return }
        for service in services { peripheral.discoverCharacteristics([CBUUID(string: "9897"), CBUUID(string: "9898"), CBUUID(string: "9896")], for: service) }
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: (any Error)?) {
        if let error { fail(error); return }
        for value in service.characteristics ?? [] { outgoingChars[value.uuid.uuidString] = value }
        if outgoingChars["9897"] != nil, outgoingChars["9898"] != nil, outgoingChars["9896"] != nil {
            let pending = connecting; connecting = nil; pending?.resume()
        }
    }
    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: (any Error)?) {
        let pending = notificationReady; notificationReady = nil
        // OPPO may omit the CCC descriptor while still delivering notifications.
        if let error, !((error as NSError).domain == CBATTErrorDomain && (error as NSError).code == 10) { pending?.resume(throwing: error) }
        else { pending?.resume() }
    }
    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: (any Error)?) {
        let pending = writing; writing = nil
        if let error { pending?.resume(throwing: error) } else { pending?.resume() }
    }
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: (any Error)?) {
        if characteristic.uuid == CBUUID(string: "9897") {
            let pending = reading; reading = nil
            if let error { pending?.resume(throwing: error) } else { pending?.resume(returning: characteristic.value ?? Data()) }
        } else if characteristic.uuid == CBUUID(string: "9898"), let value = characteristic.value {
            if value == Data("3".utf8) || value == Data("cancel".utf8) || value == Data("6".utf8) { stream?.yield(value); return }
            notificationFragments.append(value)
            guard notificationFragments.count <= 65536 else { fail(TransferFailure.invalid("Bluetooth notification is too large.")); return }
            if (try? JSONSerialization.jsonObject(with: notificationFragments)) != nil { stream?.yield(notificationFragments); notificationFragments.removeAll() }
        }
    }
}
