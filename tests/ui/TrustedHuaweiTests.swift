// SPDX-License-Identifier: GPL-3.0-only
// Appended to a disposable production-host copy; uses isolated preferences.

extension AppModel {
    func exerciseHuaweiTrust() throws {
        let identity = "huawei-key:" + String(repeating: "a", count: 64)
        let incoming: [String: Any] = ["id": "huawei-received", "direction": "receive",
            "peer": "Huawei test", "device_identifier": identity,
            "device_kind": "phone", "device_brand": "Huawei"]
        input = FileHandle.nullDevice
        precondition(autoAcceptTrusted)
        for scope in [false, true] {
            changeTrustedOnly(scope)
            for enabled in [false, true] {
                let pipe = Pipe()
                input = pipe.fileHandleForWriting
                changeAutoAcceptTrusted(enabled)
                let commands = String(decoding: pipe.fileHandleForReading.availableData, as: UTF8.self)
                    .split(separator: "\n")
                    .map { try! JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
                let configure = commands.first { $0["command"] as? String == "configure" }!
                precondition(configure["auto_accept_trusted"] as? Bool == enabled)
                precondition(configure["trusted_only"] as? Bool == scope)
                precondition(AppModel().autoAcceptTrusted == enabled)
                precondition(AppModel().trustedOnly == scope)
                input = FileHandle.nullDevice
            }
        }
        input = FileHandle.nullDevice
        var event = incoming
        event["state"] = "transferring"
        updateTransfer(event)
        precondition(!knownDevices.contains { $0.id == identity })
        event["state"] = "complete"
        updateTransfer(event)
        let device = knownDevices.first { $0.id == identity }!
        precondition(device.brand == "Huawei" && device.kind == "phone")
        setTrusted(device, trusted: true)
        precondition(trustedDevices.contains { $0.id == identity })
        let restored = AppModel()
        precondition(restored.trustedDevices.contains { $0.id == identity })
        precondition(restored.knownDevices.contains { $0.id == identity })
        setTrusted(device, trusted: false)
        precondition(!trustedDevices.contains { $0.id == identity })
        precondition(knownDevices.contains { $0.id == identity })
        forgetDevice(device)
        precondition(!knownDevices.contains { $0.id == identity })
        // A new successful receipt makes a forgotten phone enrollable again.
        updateTransfer(event)
        precondition(knownDevices.contains { $0.id == identity })
        event["id"] = "discovery-only"
        event["device_identifier"] = "huawei:advertised-id"
        updateTransfer(event)
        precondition(!knownDevices.contains { $0.id == "huawei:advertised-id" })
        input = nil
    }
}

try AppModel().exerciseHuaweiTrust()
print("Huawei trust regression scenarios passed")
