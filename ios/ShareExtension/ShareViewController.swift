// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import UIKit
import anDropProtocol

@MainActor final class ShareViewController: UIViewController {
    private let model = SharingModel(senderOnly: true)
    private let importer = SharedFileImporter()
    private var loading: Task<Void, Never>?
    private var finished = false
    override func viewDidLoad() {
        super.viewDidLoad()
        let content = ShareView(model: model, finish: { [weak self] in
            guard let self else { return }
            finish(cancelDraft: !model.handoffRequested)
        })
        let host = UIHostingController(rootView: content)
        addChild(host); host.view.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(host.view)
        NSLayoutConstraint.activate([host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor), host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor), host.view.topAnchor.constraint(equalTo: view.topAnchor), host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)])
        host.didMove(toParent: self)
        preferredContentSize = CGSize(width: 540, height: 640)
        model.stage = "共有ファイルを読み込み中"
        loading = Task { [weak self] in
            guard let self else { return }
            do {
                let items = extensionContext?.inputItems as? [NSExtensionItem] ?? []
                let providers = items.flatMap { $0.attachments ?? [] }
                model.record("share_import_started", fields: ["count": String(providers.count)])
                let batch = try await importer.load(providers) { [weak model = self.model] diagnostic in
                    Task { @MainActor in model?.record("share_import_detail", fields: diagnostic.fields) }
                }
                guard !Task.isCancelled, !finished else { return }
                model.selectedFiles = batch.files; model.stage = "送信先を選んでください"
                model.start()
                if #available(iOS 26.0, *) { try await model.prepareSharedDraft() }
                model.record("share_import_complete", fields: ["count": String(batch.files.count), "size_bytes": String(batch.totalBytes)])
                model.stage = "送信先を選んでください"
            } catch {
                guard !Task.isCancelled, !finished else { return }
                let reason = switch error as? SharedImportError {
                case .unsupported: "unsupported"
                case .oversized: "oversized"
                case .tooManyFiles: "tooManyFiles"
                case .invalidName: "invalidName"
                case .unreadable: "unreadable"
                case .storageUnavailable: "storageUnavailable"
                case nil: "other"
                }
                model.record("share_import_failed", fields: ["reason": reason])
                model.errorMessage = (error as? SharedImportError)?.errorDescription ?? (error as? BackgroundSendJobError)?.errorDescription ?? "共有ファイルを読み込めませんでした。もう一度共有してください。"
                switch error as? SharedImportError {
                case .oversized: model.stage = "合計サイズが上限を超えています"
                case .tooManyFiles: model.stage = "選択したファイルが多すぎます"
                default: model.stage = "ファイルを読み込めませんでした"
                }
            }
        }
    }
    private func finish(cancelDraft: Bool = false) {
        guard !finished else { return }
        finished = true; loading?.cancel(); model.stop(); importer.cleanup()
        if cancelDraft || !model.handoffRequested { model.discardSharedDraft() }
        extensionContext?.completeRequest(returningItems: nil)
    }
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        finish()
    }
}

private struct ShareView: View {
    @Bindable var model: SharingModel
    let finish: () -> Void
    @State private var copiedDiagnostic = false
    var body: some View {
        NavigationStack {
            List {
                Section {
                    if #available(iOS 26.0, *) {
                        Text("背景で送る場合は、送信先を選んでからanDrop本体を開いてください。転送開始後は他のアプリへ切り替えても進捗を確認できます。")
                            .font(.subheadline).foregroundStyle(.secondary)
                    } else {
                        Text("同じWi-Fiの端末へ送信します。完了までこの共有画面を開いてください。")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    Label(model.bluetoothStatus, systemImage: "antenna.radiowaves.left.and.right").font(.subheadline)
                    Text(model.stage).accessibilityIdentifier("shareStage")
                    if model.handoffRequested {
                        Text("ファイルを引き継ぐ準備ができました。「準備を完了」で閉じ、anDrop本体を開いてください。")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    if model.selectedFiles.isEmpty, model.errorMessage == nil { ProgressView("読み込み中") }
                    if model.busy {
                        if let fraction = model.progressFraction { ProgressView(value: fraction) }
                        else { ProgressView() }
                        Button("転送をキャンセル", role: .destructive) { model.cancel() }
                    }
                }
                if let error = model.errorMessage { Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red) } }
                if let notice = model.backgroundNotice { Section { Text(notice).font(.subheadline).foregroundStyle(.secondary) } }
                Section("共有するファイル") {
                    ForEach(model.selectedFiles, id: \.self) { file in Label(file.lastPathComponent, systemImage: FileTypes.symbol(for: file.lastPathComponent)).lineLimit(2) }
                    if !model.selectedFiles.isEmpty { LabeledContent("種類", value: FileTypes.category(for: model.selectedMIME)) }
                }
                Section("送信先") {
                    if !model.huaweiAddress.isEmpty {
                        Text("本体に登録したHuawei端末も確認します。Huawei Shareは送信のみの試験対応です。")
                            .font(.subheadline).foregroundStyle(.secondary)
                        if let status = model.huaweiStatus { Text(status).font(.caption).foregroundStyle(.secondary) }
                        Button("Huawei端末を再確認") { model.discoverHuawei() }
                            .disabled(model.busy || model.huaweiDiscovering || model.handoffRequested)
                    }
                    if model.backgroundVerificationEnabled {
                        if #available(iOS 26.0, *), model.sharedDraftID != nil {
                            Button("バックグラウンド共有テスト") { model.selectSharedRecipient(.init(id: UUID(), name: "Local verification", lastSeen: Date(), discoveryID: "local-verification")) }
                                .accessibilityIdentifier("verifySharedBackgroundTransfer")
                        }
                    }
                    if model.peers.isEmpty, !model.selectedFiles.isEmpty {
                        Text("相手の互传と周囲への公開を有効にしてください。初回はanDrop本体でBluetooth・ローカルネットワークを許可してください。")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    ForEach(model.sortedPeers) { peer in
                        if #available(iOS 26.0, *), model.sharedDraftID != nil {
                            Button { model.selectSharedRecipient(peer) } label: {
                                HStack { Image(systemName: "smartphone"); Text(peer.name); Spacer(); Image(systemName: "paperplane") }
                            }.disabled(model.busy || model.handoffPreparing || model.handoffRequested)
                        } else {
                        Button { model.send(to: peer) } label: {
                            HStack { Image(systemName: "smartphone"); Text(peer.name); Spacer(); Image(systemName: "paperplane") }
                        }.disabled(model.busy || model.selectedFiles.isEmpty || model.handoffPreparing)
                        }
                    }
                }
                Section {
                    Text(Limits.summary).font(.footnote).foregroundStyle(.secondary)
                    Button(copiedDiagnostic ? "診断ログをコピーしました" : "診断ログをコピー") {
                        guard let url = model.diagnosticURL(), let value = try? String(contentsOf: url, encoding: .utf8) else { return }
                        UIPasteboard.general.string = value; copiedDiagnostic = true
                    }.disabled(model.busy)
                }
            }
            .accessibilityIdentifier("shareFileList")
            .navigationTitle("anDropで送信")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(model.handoffRequested ? "準備を完了" : model.busy ? "中止して閉じる" : "閉じる", action: finish).accessibilityIdentifier("closeShare") } }
        }
    }
}
