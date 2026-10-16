// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 anDrop contributors

import AppKit

@MainActor enum BrandLogos {
    private static let files = [
        "OPPO": "oppo.svg", "Xiaomi": "xiaomi.png", "HONOR": "honor.svg",
        "vivo": "vivo.svg", "iQOO": "iqoo.svg", "realme": "realme.svg",
        "OnePlus": "oneplus.svg", "Meizu": "meizu.png", "Lenovo": "lenovo.png",
        "Samsung": "samsung.svg"
    ]
    private static let images: [String: NSImage] = files.reduce(into: [:]) { result, item in
        guard let root = Bundle.main.resourceURL,
              let image = NSImage(contentsOf: root.appendingPathComponent("BrandLogos").appendingPathComponent(item.value)) else { return }
        result[item.key] = image
    }
    static func image(for brand: String) -> NSImage? { images[brand] }
}
