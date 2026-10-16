// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 anDrop contributors
// Appended to a disposable copy of the production UI by render-docs.py.

@MainActor func renderDocumentation<V: View>(_ view: V, to url: URL) throws {
    let host = NSHostingView(rootView: view.environment(\.colorScheme, .dark).background(Color(nsColor: .windowBackgroundColor)))
    host.appearance = NSAppearance(named: .darkAqua)
    host.frame = NSRect(origin: .zero, size: host.fittingSize)
    let window = NSWindow(contentRect: host.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
    window.appearance = NSAppearance(named: .darkAqua)
    window.contentView = host
    // Let SwiftUI preference-driven grid measurements settle before capturing.
    for _ in 0..<4 {
        RunLoop.current.run(until: Date().addingTimeInterval(0.025))
        window.setContentSize(host.fittingSize)
        host.layoutSubtreeIfNeeded()
    }
    let size = host.bounds.size
    guard size.width > 0, size.height > 0,
          let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,
              pixelsWide: Int(ceil(size.width * 2)), pixelsHigh: Int(ceil(size.height * 2)),
              bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
              isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
    else { throw CocoaError(.fileWriteUnknown) }
    bitmap.size = size
    host.displayIfNeeded()
    host.cacheDisplay(in: host.bounds, to: bitmap)
    window.contentView = nil
    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        throw CocoaError(.fileWriteUnknown)
    }
    try png.write(to: url)
}

let documentationApp = NSApplication.shared
// No application delegate is installed, and no UI window is shown.
documentationApp.appearance = NSAppearance(named: .darkAqua)
if let icon = Bundle.main.url(forResource: "AppIcon", withExtension: "icns").flatMap(NSImage.init(contentsOf:)) {
    documentationApp.applicationIconImage = icon
}
let imageDirectory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
for language in ["zh", "en"] {
    UserDefaults.standard.setVolatileDomain([
        "language": language, "customSharingName": "", "peerAliases": [String: String](),
        "destination": "~/Downloads", "enabled": true,
    ], forName: UserDefaults.argumentDomain)
    let model = AppModel()
    model.engineReady = true
    model.notificationsAllowed = true
    model.destination = "~/Downloads"
    model.selectedFiles = [URL(fileURLWithPath: "/mock/Project.pdf")]
    let names = language == "zh" ? ["工作手机", "旅行平板", "家用手机", "学习平板"]
        : ["Work phone", "Travel tablet", "Home phone", "Study tablet"]
    model.peers = [
        Peer(id: "mock-phone", name: names[0], brand: "OPPO", kind: .phone),
        Peer(id: "mock-tablet", name: names[1], brand: "OPPO", kind: .tablet),
        Peer(id: "mock-vivo", name: names[2], brand: "vivo", kind: .phone),
        Peer(id: "mock-xiaomi", name: names[3], brand: "Xiaomi", kind: .tablet),
    ]
    try renderDocumentation(RecipientView(model: model), to: imageDirectory.appendingPathComponent("recipients-\(language).png"))
    model.outgoing = OutgoingPresentation(id: "mock-transfer", peer: model.peers[0], files: model.selectedFiles)
    model.transfers = [Transfer(id: "mock-transfer", direction: "send", peer: names[0],
        state: "transferring", name: "Project.pdf", total: 100, completed: 42)]
    try renderDocumentation(RecipientView(model: model), to: imageDirectory.appendingPathComponent("sending-\(language).png"))
    model.outgoing = nil
    model.transfers = []
    try renderDocumentation(SettingsView(model: model), to: imageDirectory.appendingPathComponent("settings-\(language).png"))
}
print("Rendered six mock documentation images.")
