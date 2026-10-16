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
    private static let backgrounds: [String: NSColor] = {
        var colors = [
            "OPPO": NSColor(srgbRed: 4/255, green: 106/255, blue: 56/255, alpha: 1),
            "vivo": NSColor(srgbRed: 65/255, green: 95/255, blue: 1, alpha: 1)
        ]
        // Match the orange embedded in the unchanged official Xiaomi artwork.
        if let url = Bundle.main.resourceURL?.appendingPathComponent("BrandLogos/xiaomi.png"),
           let data = try? Data(contentsOf: url),
           let bitmap = NSBitmapImageRep(data: data),
           let color = bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 8)?.usingColorSpace(.sRGB) {
            colors["Xiaomi"] = color
        }
        return colors
    }()
    static func background(for brand: String) -> NSColor? { backgrounds[brand] }
    static func usesWhiteLogo(for brand: String) -> Bool { brand == "OPPO" || brand == "vivo" }
    static func image(for brand: String) -> NSImage? { images[brand] }
}
