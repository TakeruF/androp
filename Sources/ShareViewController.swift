// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 anDrop contributors

import AppKit
import UniformTypeIdentifiers

@objc(ShareViewController)
@MainActor final class ShareViewController: NSViewController {
    private let titleLabel = NSTextField(labelWithString: L("Opening files in anDrop…", "正在将文件传递给 anDrop…"))
    private var started = false
    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 380, height: 160))
        titleLabel.frame = NSRect(x: 24, y: 92, width: 332, height: 42); titleLabel.maximumNumberOfLines = 2; titleLabel.font = .systemFont(ofSize: 15)
        view.addSubview(titleLabel)
        let close = NSButton(title: L("Close", "关闭"), target: self, action: #selector(finish)); close.frame = NSRect(x: 260, y: 28, width: 96, height: 32); view.addSubview(close)
    }
    override func viewDidAppear() {
        super.viewDidAppear()
        guard !started else { return }; started = true
        Task { await share() }
    }
    private func share() async {
        var urls: [URL] = []
        for item in extensionContext?.inputItems as? [NSExtensionItem] ?? [] {
            for provider in item.attachments ?? [] {
                guard provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) else { continue }
                let url: URL? = await withCheckedContinuation { continuation in
                    provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { value, _ in
                        if let url = value as? URL { continuation.resume(returning: url) }
                        else if let data = value as? Data { continuation.resume(returning: URL(dataRepresentation: data, relativeTo: nil)) }
                        else { continuation.resume(returning: nil) }
                    }
                }
                if let url, url.isFileURL { urls.append(url) }
            }
        }
        guard !urls.isEmpty else { titleLabel.stringValue = L("Could not open these files. Use Send Files in anDrop.", "无法获取这些文件。请使用 anDrop 的发送文件功能。"); return }
        var components = URLComponents(); components.scheme = "androp"; components.host = "share"
        components.queryItems = urls.map { URLQueryItem(name: "file", value: $0.path) }
        guard let url = components.url, NSWorkspace.shared.open(url) else { titleLabel.stringValue = L("Open anDrop once, then try sharing again.", "请先启动 anDrop，然后重试共享。"); return }
        finish()
    }
    @objc private func finish() { extensionContext?.completeRequest(returningItems: nil, completionHandler: nil) }
}
