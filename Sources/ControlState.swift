// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 anDrop contributors
import AppKit
import Foundation

nonisolated struct ReceiveControlState: Codable, Equatable, Sendable {
    var isOn: Bool
    var trustedOnly: Bool?
    var language: String
    var status: String {
        if !isOn { return language == "zh" ? "已关闭" : "Off" }
        guard let trustedOnly else { return language == "zh" ? "点击选择接收范围" : "Open to choose" }
        return language == "zh" ? (trustedOnly ? "仅限信任设备" : "所有人") : (trustedOnly ? "Trusted Devices Only" : "Everyone")
    }
    static let preview = Self(isOn: true, trustedOnly: false, language: "en")
}

@MainActor
enum ReceiveControlStore {
    static let kind = "org.androp.send"
    private static var stateURL: URL? {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "AnDropControlGroup") as? String else { return nil }
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)?.appendingPathComponent("receive-state.json")
    }
    static func write(_ state: ReceiveControlState) {
        guard let url = stateURL, let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: url, options: .atomic)
    }
    static func read() -> ReceiveControlState {
        let language = Locale.preferredLanguages.first?.hasPrefix("zh") == true ? "zh" : "en"
        let hostID = Bundle.main.object(forInfoDictionaryKey: "AnDropHostBundleIdentifier") as? String ?? Bundle.main.bundleIdentifier
        let running = NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == hostID }
        var state = stateURL.flatMap { try? Data(contentsOf: $0) }.flatMap { try? JSONDecoder().decode(ReceiveControlState.self, from: $0) }
            ?? ReceiveControlState(isOn: running, trustedOnly: nil, language: language)
        // A missing shared container must not invent an Everyone selection.
        // A crash must not leave the tile showing On indefinitely after refresh.
        if !running { state.isOn = false }
        return state
    }
}
