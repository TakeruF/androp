// SPDX-License-Identifier: GPL-3.0-only
// Standalone research app. No advertising, Wi-Fi changes or payload transfer.
// GO-request writes exist only in the explicitly selected, bounded research mode.
// Private inventory/results are created exclusively with mode 0600; do not publish them.
import AppKit
import CoreBluetooth
import Darwin

private struct Options {
    var seconds: Double = 8
    var target: UUID?
    var matchNativeID: Data?
    var inventory: String?
    var result: String?
    var scanAll = false
    var readNativeInfo = false
    var testNativeNotify = false
    var inspectNativeDescriptors = false
    var goRequest: Data?
    var goResult: String?

    static func parse(_ arguments: [String]) throws -> Options {
        var options = Options()
        var index = 0
        var explicitSeconds = false
        while index < arguments.count {
            let argument = arguments[index]
            func value() throws -> String {
                guard index + 1 < arguments.count else { throw Failure.arguments }
                index += 1
                return arguments[index]
            }
            switch argument {
            case "--seconds":
                guard let seconds = Double(try value()), seconds.isFinite, (1...60).contains(seconds) else { throw Failure.arguments }
                options.seconds = seconds; explicitSeconds = true
            case "--target":
                guard let target = UUID(uuidString: try value()) else { throw Failure.arguments }
                options.target = target
            case "--match-native-id-file":
                guard options.matchNativeID == nil else { throw Failure.arguments }
                options.matchNativeID = try readPrivateNativeID(from: value())
            case "--inventory": options.inventory = try value()
            case "--result": options.result = try value()
            case "--scan-all": options.scanAll = true
            case "--read-native-info": options.readNativeInfo = true
            case "--test-native-notify": options.testNativeNotify = true
            case "--inspect-native-descriptors": options.inspectNativeDescriptors = true
            case "--request-native-go-file":
                guard options.goRequest == nil else { throw Failure.arguments }
                options.goRequest = try readPrivateGORequest(from: value())
            case "--go-result": options.goResult = try value()
            default: throw Failure.arguments
            }
            index += 1
        }
        guard options.target == nil || options.matchNativeID == nil else { throw Failure.arguments }
        if options.hasTarget, !explicitSeconds { options.seconds = 15 }
        guard !options.readNativeInfo || (options.hasTarget && options.result != nil),
              !options.testNativeNotify || (options.hasTarget && options.readNativeInfo && options.result != nil),
              !options.inspectNativeDescriptors || (options.hasTarget && !options.testNativeNotify),
              (options.goRequest == nil) == (options.goResult == nil),
              options.goRequest == nil || (options.matchNativeID != nil && options.readNativeInfo && options.result != nil
                  && !options.inspectNativeDescriptors && !options.testNativeNotify),
              options.result == nil || options.readNativeInfo,
              options.inventory != options.result || options.inventory == nil else { throw Failure.arguments }
        let outputPaths = [options.inventory, options.result, options.goResult].compactMap({ $0 })
        guard Set(outputPaths).count == outputPaths.count else { throw Failure.arguments }
        for path in outputPaths {
            guard path.hasPrefix("/"), !FileManager.default.fileExists(atPath: path) else { throw Failure.arguments }
        }
        if options.testNativeNotify || options.inspectNativeDescriptors || options.matchNativeID != nil { options.seconds = min(options.seconds, 15) }
        return options
    }

    var hasTarget: Bool { target != nil || matchNativeID != nil }
}

private enum Failure: Error { case arguments, privateOutput }

private func readPrivateGORequest(from path: String) throws -> Data {
    guard path.hasPrefix("/") else { throw Failure.arguments }
    let descriptor = path.withCString { open($0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK) }
    guard descriptor >= 0 else { throw Failure.arguments }
    let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    defer { try? file.close() }
    var info = stat()
    guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
          info.st_uid == geteuid(), info.st_mode & 0o077 == 0, info.st_size == 17,
          let bytes = try file.read(upToCount: 18), bytes.count == 17,
          let text = String(data: bytes, encoding: .ascii) else { throw Failure.arguments }
    let fields = text.components(separatedBy: "&")
    guard fields.count == 3, fields[0] == "11", fields[2] == "1", fields[1].utf8.count == 12,
          fields[1].utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) else {
        throw Failure.arguments
    }
    return bytes
}

private func readPrivateNativeID(from path: String) throws -> Data {
    guard path.hasPrefix("/") else { throw Failure.arguments }
    let descriptor = path.withCString { open($0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK) }
    guard descriptor >= 0 else { throw Failure.arguments }
    let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    defer { try? file.close() }
    var info = stat()
    guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
          info.st_uid == geteuid(), info.st_mode & 0o077 == 0, info.st_size == 12,
          let bytes = try file.read(upToCount: 13), bytes.count == 12,
          bytes.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) else {
        throw Failure.arguments
    }
    return Data(bytes.map { (97...102).contains($0) ? $0 - 32 : $0 })
}

private func writePrivate(_ bytes: Data, to path: String) throws {
    let descriptor = path.withCString { open($0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, S_IRUSR | S_IWUSR) }
    guard descriptor >= 0 else { throw Failure.privateOutput }
    let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    do { try file.write(contentsOf: bytes); try file.close() }
    catch { try? file.close(); throw Failure.privateOutput }
}

@MainActor
private final class NativeProbe: NSObject, NSApplicationDelegate, @preconcurrency CBCentralManagerDelegate, @preconcurrency CBPeripheralDelegate {
    private let options: Options
    private var manager: CBCentralManager?
    private var peer: CBPeripheral?
    private var inventory: [UUID: [String: Any]] = [:]
    private var characteristics: [[String: Any]] = []
    private var pendingServices: Set<String> = []
    private var started = false
    private var finishing = false
    private var reading = false
    private var nativeInfoSaved = false
    private var nativeVersionSupported = false
    private var notificationTest: [String: Any]?
    private var descriptorInspectionStarted = false
    private var pendingDescriptors: Set<ObjectIdentifier> = []
    private var descriptorRecords: [[String: Any]] = []
    private var descriptorReadFailures = 0
    private var goRequestAttempted = false
    private var goWriteResponse: [String: Any]?
    private var goResponse = Data()
    private var goFragmentLengths: [Int] = []
    private var deadline: Timer?
    private let nativeServices = ["3333", "6667", "00003331-0000-1000-8000-008123456789"].map(CBUUID.init(string:))

    init(options: Options) { self.options = options }

    func applicationDidFinishLaunching(_ notification: Notification) {
        print("probe-start mode=\(!options.hasTarget ? "scan" : options.goRequest != nil ? "request-native-go" : options.inspectNativeDescriptors ? "inspect-native-descriptors" : options.testNativeNotify ? "test-native-notify" : options.readNativeInfo ? "enumerate-and-read-9996" : "enumerate") seconds=\(Int(options.seconds))")
        deadline = Timer.scheduledTimer(withTimeInterval: options.seconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.finish(reason: "timeout", code: self?.options.hasTarget == false ? 0 : 3) }
        }
        manager = CBCentralManager(delegate: self, queue: nil, options: [CBCentralManagerOptionShowPowerAlertKey: false])
    }

    func applicationWillTerminate(_ notification: Notification) {
        deadline?.invalidate(); manager?.stopScan()
        if let peer { manager?.cancelPeripheralConnection(peer) }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        print("bluetooth-state=\(central.state.rawValue) authorization=\(CBManager.authorization.rawValue)")
        guard central.state == .poweredOn else {
            if central.state == .unauthorized || central.state == .unsupported { finish(reason: "bluetooth-unavailable", code: 2) }
            return
        }
        guard !started else { return }; started = true
        if let target = options.target, let known = central.retrievePeripherals(withIdentifiers: [target]).first {
            connect(known)
        } else {
            let filter: [CBUUID]? = options.matchNativeID != nil ? [CBUUID(string: "3333")]
                : options.scanAll || options.target != nil ? nil : nativeServices
            central.scanForPeripherals(withServices: filter,
                                       options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard !finishing else { return }
        let serviceIDs = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []).map(\.uuidString)
        let serviceData = advertisementData[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data] ?? [:]
        let previous = inventory[peripheral.identifier]
        let native = (previous?["native_candidate"] as? Bool == true)
            || serviceIDs.contains { value in nativeServices.contains { $0.uuidString == value } }
            || serviceData.keys.contains { ["3333", "3334", "6666", "6667", "01FF"].contains($0.uuidString) }
        // A common-format scan response may arrive before its 3331 advertisement.
        // It cannot establish the vendor or ownership by itself: retain it as a
        // provisional candidate, never as a confirmed native advertisement.
        let commonResponse = serviceData.contains { key, value in
            ["0703", "0704", "0204", "FFFF"].contains(key.uuidString) && value.count == 27
        }
        guard options.scanAll || native || commonResponse || previous != nil || options.target == peripheral.identifier else { return }
        guard previous != nil || inventory.count < 256 else { return }
        let isNew = previous == nil
        let incomingData = Dictionary(uniqueKeysWithValues: serviceData.map { key, value in
            (key.uuidString, ["length": value.count, "base64": value.prefix(1024).base64EncodedString()] as [String: Any])
        })
        var data = previous?["service_data"] as? [String: [String: Any]] ?? [:]
        data.merge(incomingData) { _, latest in latest }
        let mergedServices = Array(Set((previous?["advertised_services"] as? [String] ?? []) + serviceIDs)).sorted()
        var record = previous ?? [:]
        record["identifier"] = peripheral.identifier.uuidString
        record["native_candidate"] = native
        record["common_response_only"] = !native && (commonResponse || previous?["common_response_only"] as? Bool == true)
        record["advertised_services"] = mergedServices
        record["service_data"] = data
        record["rssi"] = RSSI.intValue
        if let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String { record["local_name"] = String(name.prefix(128)) }
        if let manufacturer = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data {
            record["manufacturer_data"] = ["length": manufacturer.count, "base64": manufacturer.prefix(1024).base64EncodedString()]
        }
        inventory[peripheral.identifier] = record
        if isNew {
            let counts = serviceData.keys.sorted { $0.uuidString < $1.uuidString }.map { "\($0.uuidString):\(serviceData[$0]?.count ?? 0)" }.joined(separator: ",")
            print("candidate=\(inventory.count) native=\(native) advertised-services=\(serviceIDs.joined(separator: ",")) service-data-lengths=\(counts)")
        }
        if let expected = options.matchNativeID,
           let advertisement = serviceData[CBUUID(string: "3333")], advertisement.count <= 128,
           let first = advertisement.split(separator: 45, omittingEmptySubsequences: false).first,
           first.count == 12,
           Data(first.map { (97...102).contains($0) ? $0 - 32 : $0 }) == expected {
            // Operator-selected discovery identity only; this is not an
            // authentication/trust assertion and does not approve any transfer.
            print("native-discovery-id-matched")
            connect(peripheral)
        } else if options.target == peripheral.identifier { connect(peripheral) }
    }

    private func connect(_ peripheral: CBPeripheral) {
        guard peer == nil, !finishing else { return }
        manager?.stopScan(); peer = peripheral; peripheral.delegate = self
        print("target-connect")
        manager?.connect(peripheral, options: nil)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard !finishing else { central.cancelPeripheralConnection(peripheral); return }
        print("target-connected"); peripheral.discoverServices(nil)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: (any Error)?) {
        finish(reason: "connection-failed", code: 3)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: (any Error)?) {
        if !finishing { finish(reason: "disconnected", code: 3) }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: (any Error)?) {
        guard !finishing else { return }
        guard error == nil, let services = peripheral.services, !services.isEmpty else { finish(reason: "services-failed", code: 3); return }
        pendingServices = Set(services.map { $0.uuid.uuidString })
        print("services=\(services.map { $0.uuid.uuidString }.joined(separator: ","))")
        for service in services { peripheral.discoverCharacteristics(nil, for: service) }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: (any Error)?) {
        guard !finishing else { return }
        pendingServices.remove(service.uuid.uuidString)
        if error == nil {
            for characteristic in service.characteristics ?? [] {
                characteristics.append(["service": service.uuid.uuidString, "uuid": characteristic.uuid.uuidString,
                                        "properties": characteristic.properties.rawValue])
                print("characteristic service=\(service.uuid.uuidString) uuid=\(characteristic.uuid.uuidString) properties=\(characteristic.properties.rawValue)")
                if options.readNativeInfo, !reading, service.uuid == CBUUID(string: "9999"), characteristic.uuid == CBUUID(string: "9996") {
                    guard characteristic.properties.contains(.read) else { finish(reason: "9996-not-readable", code: 3); return }
                    reading = true
                    print("read-native-info characteristic=9996")
                    peripheral.readValue(for: characteristic)
                }
            }
        }
        if pendingServices.isEmpty, !reading, !options.inspectNativeDescriptors { finish(reason: options.readNativeInfo ? "9996-not-found" : "enumerated", code: options.readNativeInfo ? 3 : 0) }
        if pendingServices.isEmpty, options.inspectNativeDescriptors, options.readNativeInfo, !reading {
            finish(reason: "9996-not-found", code: 3); return
        }
        attemptNotificationTestIfReady()
        attemptDescriptorInspectionIfReady()
        attemptGORequestIfReady()
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: (any Error)?) {
        if !finishing, goRequestAttempted, characteristic.uuid == CBUUID(string: "9989"), characteristic.service?.uuid == CBUUID(string: "9999") {
            guard error == nil, let bytes = characteristic.value else { finish(reason: "native-go-value-error", code: 3); return }
            guard bytes.count <= 4096 - goResponse.count, goFragmentLengths.count < 3 else {
                finish(reason: "native-go-response-limit", code: 3); return
            }
            goResponse.append(bytes); goFragmentLengths.append(bytes.count)
            print("native-go-unsolicited-value bytes=\(bytes.count) total-bytes=\(goResponse.count)")
            // Preserve exact fragments in memory. The operator parses the
            // private result separately; this is not transfer acceptance.
            return
        }
        guard !finishing, reading, characteristic.uuid == CBUUID(string: "9996") else { return }
        guard error == nil, let bytes = characteristic.value, bytes.count <= 65536, let result = options.result else {
            finish(reason: "9996-read-failed", code: 3); return
        }
        do {
            try writePrivate(bytes, to: result)
            print("native-info bytes=\(bytes.count) format=\(String(data: bytes, encoding: .utf8) == nil ? "binary" : "utf8")")
            nativeInfoSaved = true
            if options.testNativeNotify || options.goRequest != nil {
                // Format/version gate only. Optional public key/proof is neither
                // authenticated nor converted into any approval/trust assertion.
                let fields = String(data: bytes, encoding: .utf8)?.components(separatedBy: "&") ?? []
                if [2, 5, 6].contains(fields.count), fields[1] == "3" {
                    let mac = fields[0].replacingOccurrences(of: ":", with: "")
                    nativeVersionSupported = mac.utf8.count == 12 && mac.utf8.allSatisfy {
                        (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
                    }
                }
                guard nativeVersionSupported else { finish(reason: "native-version-format-unsupported", code: 3); return }
                attemptNotificationTestIfReady()
                attemptGORequestIfReady()
            } else if options.inspectNativeDescriptors { attemptDescriptorInspectionIfReady() }
            else { finish(reason: "9996-read-complete", code: 0) }
        } catch { finish(reason: "result-write-failed", code: 4) }
    }

    private func attemptNotificationTestIfReady() {
        guard options.testNativeNotify, nativeInfoSaved, nativeVersionSupported,
              pendingServices.isEmpty, notificationTest == nil, !finishing, let peer else { return }
        guard let characteristic = peer.services?.first(where: { $0.uuid == CBUUID(string: "9999") })?
            .characteristics?.first(where: { $0.uuid == CBUUID(string: "9989") }) else {
            finish(reason: "9989-not-found", code: 3); return
        }
        let advertisedNotify = characteristic.properties.contains(.notify) || characteristic.properties.contains(.indicate)
        notificationTest = ["service": "9999", "characteristic": "9989", "attempted": true,
                            "advertised_notify": advertisedNotify, "callback_received": false]
        print("native-notify-test characteristic=9989 advertised-notify=\(advertisedNotify)")
        fflush(nil)
        // Explicit research mode: Android registers notifications on this RW-only
        // characteristic. Test the actual macOS boundary; no GO request follows.
        peer.setNotifyValue(true, for: characteristic)
    }

    private func attemptGORequestIfReady() {
        guard let request = options.goRequest, nativeInfoSaved, nativeVersionSupported,
              pendingServices.isEmpty, !goRequestAttempted, !finishing, let peer else { return }
        guard let characteristic = peer.services?.first(where: { $0.uuid == CBUUID(string: "9999") })?
            .characteristics?.first(where: { $0.uuid == CBUUID(string: "9989") }),
              characteristic.properties.contains(.write), peer.maximumWriteValueLength(for: .withResponse) >= request.count else {
            finish(reason: "native-go-write-unavailable", code: 3); return
        }
        goRequestAttempted = true
        print("native-go-request-write bytes=\(request.count) notify-registration=false")
        fflush(nil)
        // Exactly one source-derived request, using the operator's actual local
        // Bluetooth MAC. No notification registration, approval or start write.
        peer.writeValue(request, for: characteristic, type: .withResponse)
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: (any Error)?) {
        guard !finishing, goRequestAttempted, characteristic.uuid == CBUUID(string: "9989"),
              characteristic.service?.uuid == CBUUID(string: "9999"), goWriteResponse == nil else { return }
        if let error {
            let value = error as NSError
            goWriteResponse = ["acknowledged": false, "error_domain": value.domain, "error_code": value.code]
            print("native-go-write-response error-domain=\(value.domain) error-code=\(value.code)")
            finish(reason: "native-go-write-failed", code: 3)
        } else {
            goWriteResponse = ["acknowledged": true]
            print("native-go-write-response error=none")
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: (any Error)?) {
        guard !finishing, notificationTest != nil, characteristic.uuid == CBUUID(string: "9989"),
              characteristic.service?.uuid == CBUUID(string: "9999") else { return }
        notificationTest?["callback_received"] = true
        notificationTest?["enabled"] = characteristic.isNotifying
        if let error {
            let value = error as NSError
            notificationTest?["error_domain"] = value.domain
            notificationTest?["error_code"] = value.code
            print("native-notify-state enabled=\(characteristic.isNotifying) error-domain=\(value.domain) error-code=\(value.code)")
        } else { print("native-notify-state enabled=\(characteristic.isNotifying) error=none") }
        finish(reason: "native-notify-test-complete", code: error == nil && characteristic.isNotifying ? 0 : 3)
    }

    private func attemptDescriptorInspectionIfReady() {
        guard options.inspectNativeDescriptors, !descriptorInspectionStarted, pendingServices.isEmpty,
              !options.readNativeInfo || nativeInfoSaved, !finishing, let peer else { return }
        guard let characteristic = peer.services?.first(where: { $0.uuid == CBUUID(string: "9999") })?
            .characteristics?.first(where: { $0.uuid == CBUUID(string: "9989") }) else {
            finish(reason: "9989-not-found", code: 3); return
        }
        descriptorInspectionStarted = true
        print("native-descriptors-discover service=9999 characteristic=9989")
        peer.discoverDescriptors(for: characteristic)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverDescriptorsFor characteristic: CBCharacteristic, error: (any Error)?) {
        guard !finishing, options.inspectNativeDescriptors, descriptorInspectionStarted,
              characteristic.uuid == CBUUID(string: "9989"), characteristic.service?.uuid == CBUUID(string: "9999") else { return }
        if let error {
            let value = error as NSError
            descriptorRecords.append(["discovery_error_domain": value.domain, "discovery_error_code": value.code])
            print("native-descriptors-error domain=\(value.domain) code=\(value.code)")
            finish(reason: "native-descriptor-discovery-failed", code: 3); return
        }
        let descriptors = characteristic.descriptors ?? []
        guard descriptors.count <= 32 else { finish(reason: "native-descriptor-limit", code: 3); return }
        print("native-descriptors count=\(descriptors.count) cccd-present=\(descriptors.contains { $0.uuid == CBUUID(string: "2902") })")
        pendingDescriptors = Set(descriptors.map(ObjectIdentifier.init))
        for descriptor in descriptors {
            print("native-descriptor uuid=\(descriptor.uuid.uuidString)")
            peripheral.readValue(for: descriptor)
        }
        if pendingDescriptors.isEmpty { finish(reason: "native-descriptor-inspection-complete", code: 0) }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor descriptor: CBDescriptor, error: (any Error)?) {
        guard !finishing, options.inspectNativeDescriptors, pendingDescriptors.remove(ObjectIdentifier(descriptor)) != nil else { return }
        var record: [String: Any] = ["uuid": descriptor.uuid.uuidString]
        if let error {
            let value = error as NSError
            descriptorReadFailures += 1
            record["error_domain"] = value.domain; record["error_code"] = value.code
            print("native-descriptor-read uuid=\(descriptor.uuid.uuidString) error-domain=\(value.domain) error-code=\(value.code)")
        } else {
            // Values are deliberately not persisted, even in private inventory.
            // CoreBluetooth may bridge standard descriptor values as String or
            // NSNumber rather than Data; do not invent a raw wire length then.
            if let bytes = descriptor.value as? Data {
                record["value_bytes"] = bytes.count
                print("native-descriptor-read uuid=\(descriptor.uuid.uuidString) bytes=\(bytes.count)")
            } else if descriptor.value == nil {
                record["value_kind"] = "none"
                print("native-descriptor-read uuid=\(descriptor.uuid.uuidString) value-kind=none")
            } else {
                record["value_kind"] = "bridged-standard"
                print("native-descriptor-read uuid=\(descriptor.uuid.uuidString) value-kind=bridged-standard")
            }
        }
        descriptorRecords.append(record)
        if pendingDescriptors.isEmpty { finish(reason: "native-descriptor-inspection-complete", code: descriptorReadFailures == 0 ? 0 : 3) }
    }

    private func finish(reason: String, code: Int32) {
        guard !finishing else { return }; finishing = true
        deadline?.invalidate(); manager?.stopScan()
        if let peer { manager?.cancelPeripheralConnection(peer) }
        var exitCode = code
        if let path = options.goResult, !goResponse.isEmpty {
            do { try writePrivate(goResponse, to: path) }
            catch { print("go-result-write-failed"); exitCode = 4 }
        }
        if let path = options.inventory {
            do {
                var object: [String: Any] = ["reason": reason, "candidates": inventory.values.sorted {
                    ($0["identifier"] as? String ?? "") < ($1["identifier"] as? String ?? "")
                }, "characteristics": characteristics]
                if let notificationTest { object["native_notification_test"] = notificationTest }
                if options.inspectNativeDescriptors {
                    object["native_descriptor_inspection"] = ["started": descriptorInspectionStarted,
                        "pending_reads": pendingDescriptors.count, "descriptors": descriptorRecords]
                }
                if options.goRequest != nil {
                    var observation: [String: Any] = ["attempted": goRequestAttempted,
                        "notification_registration": false, "fragment_lengths": goFragmentLengths,
                        "received_bytes": goResponse.count]
                    if let goWriteResponse { observation["write_response"] = goWriteResponse }
                    object["native_go_request"] = observation
                }
                try writePrivate(JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .prettyPrinted]), to: path)
            } catch { print("inventory-write-failed"); exitCode = 4 }
        }
        print("probe-end reason=\(reason) candidates=\(inventory.count)")
        fflush(nil)
        let finalCode = exitCode
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { exit(finalCode) }
    }
}

@main
private struct ProbeMain {
    static func main() {
        if CommandLine.arguments.dropFirst().contains("--help") {
            print("OppoNativeProbe [--seconds 1...60] [--scan-all] [--inventory ABSENT_ABSOLUTE_PATH] [--target CBUUID | --match-native-id-file PRIVATE_ID_PATH] [--read-native-info --result ABSENT_ABSOLUTE_PATH] [--test-native-notify | --inspect-native-descriptors | --request-native-go-file PRIVATE_REQUEST_PATH --go-result ABSENT_ABSOLUTE_PATH]")
            return
        }
        do {
            let options = try Options.parse(Array(CommandLine.arguments.dropFirst()))
            let app = NSApplication.shared
            let probe = NativeProbe(options: options)
            app.setActivationPolicy(.accessory); app.delegate = probe
            withExtendedLifetime(probe) { app.run() }
        } catch { print("invalid-arguments-or-output-path; use --help"); exit(2) }
    }
}
