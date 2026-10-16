// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 anDrop contributors

import Foundation

@MainActor func appLanguage() -> String {
    let selected = UserDefaults.standard.string(forKey: "language") ?? "system"
    return selected == "system" ? (Locale.preferredLanguages.first?.hasPrefix("zh") == true ? "zh" : "en") : selected
}
@MainActor func L(_ english: String, _ chinese: String) -> String { appLanguage() == "zh" ? chinese : english }

@MainActor func fileCountLabel(_ count: Int) -> String {
    L("\(count) \(count == 1 ? "file" : "files")", "\(count) 个文件")
}
