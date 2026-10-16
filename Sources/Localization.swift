// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 anDrop contributors

import Foundation

@MainActor func appLanguage() -> String {
    let selected = UserDefaults.standard.string(forKey: "language") ?? "zh"
    return selected == "system" ? (Locale.preferredLanguages.first?.hasPrefix("zh") == true ? "zh" : "en") : selected
}
// Override only this process's localization lookup, never the system language.
@MainActor func configureBundleLanguage() {
    let selected = UserDefaults.standard.string(forKey: "language") ?? "zh"
    var arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
    if selected == "system" { arguments.removeValue(forKey: "AppleLanguages") }
    else { arguments["AppleLanguages"] = [selected == "zh" ? "zh-Hans" : "en"] }
    UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
}
@MainActor func L(_ english: String, _ chinese: String) -> String { appLanguage() == "zh" ? chinese : english }

@MainActor func fileCountLabel(_ count: Int) -> String {
    L("\(count) \(count == 1 ? "file" : "files")", "\(count) 个文件")
}
