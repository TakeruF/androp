// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 anDrop contributors

import AppKit
import UniformTypeIdentifiers

@objc(ShareViewController)
@MainActor final class ShareViewController: NSViewController {
    private let titleLabel = NSTextField(labelWithString: L("Opening in anDrop…", "正在传递给 anDrop…"))
    private var started = false
    override func loadView() {
        preferredContentSize = NSSize(width: 480, height: 210)
        view = NSView(frame: NSRect(origin: .zero, size: preferredContentSize))
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.maximumNumberOfLines = 0
        titleLabel.preferredMaxLayoutWidth = preferredContentSize.width - 48
        titleLabel.usesSingleLineMode = false
        titleLabel.lineBreakMode = .byWordWrapping
        titleLabel.cell?.wraps = true
        titleLabel.cell?.isScrollable = false
        titleLabel.font = .systemFont(ofSize: 15)
        view.addSubview(titleLabel)
        let close = NSButton(title: L("Close", "关闭"), target: self, action: #selector(finish))
        close.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(close)
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            titleLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            titleLabel.topAnchor.constraint(equalTo: view.topAnchor, constant: 24),
            titleLabel.bottomAnchor.constraint(lessThanOrEqualTo: close.topAnchor, constant: -20),
            close.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            close.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -24),
            close.widthAnchor.constraint(greaterThanOrEqualToConstant: 96)
        ])
    }
    override func viewDidLayout() {
        super.viewDidLayout()
        let width = max(1, view.bounds.width - 48)
        if titleLabel.preferredMaxLayoutWidth != width {
            titleLabel.preferredMaxLayoutWidth = width
            titleLabel.invalidateIntrinsicContentSize()
        }
    }
    override func viewDidAppear() {
        super.viewDidAppear()
        guard !started else { return }; started = true
        Task { await share() }
    }
    private func share() async {
        var urls: [URL] = []
        var handedOff = false
        defer {
            if !handedOff {
                for url in urls { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            }
        }
        for item in extensionContext?.inputItems as? [NSExtensionItem] ?? [] {
            for provider in item.attachments ?? [] {
                let livePhotoTypes = ["com.apple.live-photo-bundle", "com.apple.private.live-photo-bundle"]
                if let type = livePhotoTypes.first(where: { provider.hasItemConformingToTypeIdentifier($0) }) {
                    // The provider's URL may disappear when its callback returns.
                    // Copy both resources while access is valid, before dismissing
                    // Photos' share sheet. Bookmarks grant the host cache access.
                    let bundle: URL? = await withCheckedContinuation { continuation in
                        provider.loadFileRepresentation(forTypeIdentifier: type) { url, _ in
                            guard let url else { continuation.resume(returning: nil); return }
                            continuation.resume(returning: try? SharedFileStaging.copyLivePhoto(url))
                        }
                    }
                    guard let bundle else {
                        titleLabel.stringValue = L("Could not read the full Live Photo. Export the unmodified image and video from Photos, then choose both in anDrop.", "无法读取完整实况照片。请从照片导出未修改的照片和视频，然后在 anDrop 中一起选择。")
                        return
                    }
                    urls.append(bundle)
                    continue
                }
                let url: URL
                do {
                    url = try await SharedFileStaging.loadFile(from: provider)
                } catch {
                    titleLabel.stringValue = L("Could not read the shared file. Share it again or export it and use Send Files in anDrop. URL and text sharing are not supported.", "无法读取共享文件。请重新共享，或导出后使用 anDrop 的发送文件功能。不支持 URL 或文本共享。")
                    return
                }
                urls.append(url)
            }
        }
        guard !urls.isEmpty else { titleLabel.stringValue = L("Choose files to share. URL and text sharing are not supported.", "请选择文件共享，不支持 URL 或文本共享。"); return }
        var components = URLComponents(); components.scheme = "androp"; components.host = "share"
        do { components.queryItems = try urls.map { URLQueryItem(name: "bookmark", value: try FileBookmarks.encode($0)) } }
        catch { titleLabel.stringValue = L("Could not grant access to the shared files. Share them again.", "无法授予共享文件的访问权限，请重新共享。"); return }
        guard let url = components.url, NSWorkspace.shared.urlForApplication(toOpen: url) != nil,
              let context = extensionContext else { titleLabel.stringValue = L("Open anDrop once, then try sharing again.", "请先启动 anDrop，然后重试共享。"); return }
        // Dismissing the host's share sheet restores its focus. Finish that
        // handoff before opening our recipient window, otherwise Finder can
        // immediately cover the window we just activated.
        let copies = urls
        handedOff = true
        context.completeRequest(returningItems: nil) { expired in
            guard !expired else {
                for copy in copies { try? FileManager.default.removeItem(at: copy.deletingLastPathComponent()) }
                return
            }
            Task { @MainActor in
                NSWorkspace.shared.open(url)
            }
        }
    }
    @objc private func finish() { extensionContext?.completeRequest(returningItems: nil, completionHandler: nil) }
}
