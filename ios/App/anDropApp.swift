// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import UniformTypeIdentifiers
import anDropProtocol

@main struct AnDropApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = SharingModel.shared
    @Environment(\.scenePhase) private var phase
    var body: some Scene {
        WindowGroup {
            MainView(model: model)
                .task { if phase == .background { model.enterBackground() } else { model.enterForeground() } }
                .onChange(of: phase) { _, value in
                    if value == .active { model.enterForeground() }
                    else if value == .background { model.enterBackground() }
                }
        }
    }
}

struct MainView: View {
    @Bindable var model: SharingModel
    @State private var importing = false
    @State private var export: ExportedFile?
    @State private var showingHuawei = false
    @FocusState private var editingHuaweiAddress: Bool
    var body: some View {
        TabView {
            NavigationStack {
                List {
                    Section {
                        Label("iPhone・iPad 検証版", systemImage: "paperplane.fill")
                            .font(.headline).foregroundStyle(.tint)
                        Text("両方の端末を同じWi-Fiに接続してください。iOS 26以降は転送開始後に他のアプリへ切り替えても進捗を確認できます。")
                            .font(.subheadline).foregroundStyle(.secondary)
                        Label(model.bluetoothStatus, systemImage: model.enabled ? "antenna.radiowaves.left.and.right" : "pause.circle")
                            .font(.subheadline).accessibilityIdentifier("bluetoothStatus")
                        if model.hasPreparedSend {
                            Button("準備済みの送信を開始") { model.startPreparedSend() }.disabled(model.busy)
                        }
                        if model.backgroundVerificationEnabled {
                            if let result = model.backgroundVerificationResult { Text(result).accessibilityIdentifier("backgroundVerificationResult") }
                            Button("バックグラウンド転送テスト") { model.startBackgroundVerification() }
                                .disabled(model.busy).accessibilityIdentifier("verifyBackgroundTransfer")
                            Button("バックグラウンド受信テスト") { model.startBackgroundReceiveVerification() }
                                .disabled(model.busy).accessibilityIdentifier("verifyBackgroundReceive")
                        }
                        if model.busy {
                            HStack { ProgressView(); Text(model.stage).accessibilityIdentifier("transferStage") }
                            if let fraction = model.progressFraction {
                                ProgressView(value: fraction).accessibilityLabel("転送の進捗")
                                Text("\(ByteCountFormatter.string(fromByteCount: Int64(model.transferredBytes), countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: Int64(model.transferBytesTotal ?? 0), countStyle: .file))")
                                    .font(.caption).foregroundStyle(.secondary)
                            } else if model.transferredBytes > 0 {
                                Text("\(ByteCountFormatter.string(fromByteCount: Int64(model.transferredBytes), countStyle: .file)) 受信済み").font(.caption)
                            }
                            Button("転送をキャンセル", role: .destructive) { model.cancel() }
                        } else {
                            Text(model.stage).font(.subheadline).foregroundStyle(.secondary)
                            Button(model.enabled ? "待受を一時停止" : "待受を開始") {
                                if model.enabled { model.stop() } else { model.start() }
                            }.accessibilityIdentifier("receiveToggle")
                        }
                    }
                    if let message = model.errorMessage {
                        Section("転送を確認してください") {
                            Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                        }
                    }
                    if let notice = model.backgroundNotice { Section { Text(notice).font(.subheadline).foregroundStyle(.secondary) } }
                    Section("送信するファイル") {
                        if model.selectedFiles.isEmpty { Text("ファイルを選択するか、テストファイルを作成します。").foregroundStyle(.secondary) }
                        ForEach(model.selectedFiles, id: \.self) { file in
                            Label(file.lastPathComponent, systemImage: FileTypes.symbol(for: file.lastPathComponent)).lineLimit(2)
                        }
                        if !model.selectedFiles.isEmpty {
                            LabeledContent("種類", value: FileTypes.category(for: model.selectedMIME))
                                .font(.subheadline).foregroundStyle(.secondary)
                                .accessibilityElement(children: .ignore)
                                .accessibilityLabel("ファイルの種類")
                                .accessibilityValue(FileTypes.category(for: model.selectedMIME))
                                .accessibilityIdentifier("selectedFileType")
                        }
                        Button("ファイルを選択", systemImage: "folder") { importing = true }
                            .disabled(model.busy).accessibilityIdentifier("chooseFiles")
                        Button("テストファイルを作成", systemImage: "doc.badge.plus") { model.makeSample() }
                            .disabled(model.busy).accessibilityIdentifier("makeSample")
                        if let sample = model.selectedFiles.first, sample.deletingLastPathComponent().lastPathComponent == "Samples" {
                            ShareLink(item: sample) { Label("テストファイルを共有", systemImage: "square.and.arrow.up") }
                        }
                    }
                    Section("近くの対応端末") {
                        if model.sortedPeers.isEmpty {
                            Text("OPPOなどの受信側で互传を有効にし、周囲への公開を許可してください。")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(model.sortedPeers) { peer in
                            Button { model.send(to: peer) } label: {
                                HStack {
                                    Image(systemName: "smartphone")
                                    Text(peer.name).foregroundStyle(.primary)
                                    Spacer()
                                    Image(systemName: "paperplane")
                                }
                            }.disabled(model.busy || model.selectedFiles.isEmpty)
                        }
                    }
                    Section("受信") {
                        Text("Androidの標準互传で「\(model.sharingName)」を選び、このアプリで受信を許可します。保存先は「ファイル」→「このiPhone内／このiPad内」→「anDrop」→「Received」です。")
                            .font(.subheadline)
                    }
                    Section {
                        DisclosureGroup("Huawei Share（試験）", isExpanded: $showingHuawei) {
                            Text("同じWi-Fi上のHuawei端末へ送信します。初回は相手の華為分享を「全員に公開」にし、Wi-Fi設定に表示されるIPv4アドレスを入力してください。Huaweiからの受信は未対応です。")
                                .font(.subheadline).foregroundStyle(.secondary)
                            TextField("Huawei端末のIPv4アドレス", text: $model.huaweiAddress)
                                .keyboardType(.decimalPad).textInputAutocapitalization(.never).autocorrectionDisabled()
                                .focused($editingHuaweiAddress)
                                .disabled(model.busy || model.huaweiDiscovering).accessibilityIdentifier("huaweiAddress")
                            Button(model.huaweiDiscovering ? "確認中…" : "端末を確認") { model.discoverHuawei() }
                                .disabled(model.busy || model.huaweiDiscovering).accessibilityIdentifier("findHuawei")
                            if let status = model.huaweiStatus { Text(status).font(.subheadline).accessibilityIdentifier("huaweiStatus") }
                            if !model.huaweiAddress.isEmpty { Button("登録を解除", role: .destructive) { model.forgetHuawei() }.disabled(model.busy) }
                        }
                    }
                    Section {
                        Text("検証範囲：\(Limits.summary)。iOS 26以降では開始した転送を背景でも継続し、ロック画面・Dynamic Islandで進捗を表示します。Huawei ShareはIP指定による送信の試験対応です。Wi-Fi Direct・常時バックグラウンド待受は未対応です。")
                            .font(.footnote).foregroundStyle(.secondary)
                        Text("バージョン \(model.versionLabel)").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .navigationTitle("anDrop")
                .toolbar {
                    if editingHuaweiAddress {
                        ToolbarItemGroup(placement: .keyboard) {
                            Spacer()
                            Button("完了") { editingHuaweiAddress = false }.accessibilityIdentifier("finishHuaweiAddress")
                        }
                    }
                }
            }
            .tabItem { Label("転送", systemImage: "paperplane") }
            NavigationStack {
                List {
                    if model.receivedFiles.isEmpty {
                        ContentUnavailableView("受信したファイルはありません", systemImage: "tray", description: Text("受信後はファイルとSHA-256がここに表示されます。"))
                    }
                    ForEach(model.receivedFiles) { file in
                        Section(file.url.lastPathComponent) {
                            Label(FileTypes.category(for: FileTypes.mime(for: file.url.lastPathComponent)), systemImage: FileTypes.symbol(for: file.url.lastPathComponent))
                            Text(ByteCountFormatter.string(fromByteCount: Int64(file.bytes), countStyle: .file))
                            Text("SHA-256").font(.caption).foregroundStyle(.secondary)
                            Text(file.sha256).font(.caption.monospaced()).textSelection(.enabled)
                            ShareLink(item: file.url) { Label("ファイルを開く・共有", systemImage: "square.and.arrow.up") }
                        }
                    }
                }.navigationTitle("受信履歴")
            }.tabItem { Label("受信履歴", systemImage: "tray") }
            NavigationStack {
                List {
                    Section {
                        Text("Bluetoothの接続、ネットワーク交渉、転送のどこまで進んだかを記録します。書き出すログには端末名、IPアドレス、ファイル名、内容、鍵を含みません。")
                            .font(.subheadline)
                        Button("ログを書き出す", systemImage: "square.and.arrow.up") {
                            if let url = model.diagnosticURL() { export = ExportedFile(url: url) }
                        }.accessibilityIdentifier("exportDiagnostics")
                    }
                    Section("最近のイベント") {
                        ForEach(model.events.reversed()) { event in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(event.stage).font(.subheadline.monospaced())
                                if let fields = event.fields {
                                    Text(fields.sorted(by: { $0.key < $1.key }).map { "\($0.key): \($0.value)" }.joined(separator: "\n"))
                                        .font(.caption.monospaced()).foregroundStyle(.secondary)
                                }
                                Text(event.time, style: .time).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }.navigationTitle("診断")
            }.tabItem { Label("診断", systemImage: "waveform.path.ecg") }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.data], allowsMultipleSelection: true, onCompletion: model.chooseFiles)
        .sheet(item: $model.incoming, onDismiss: { model.decide(false) }) { offer in
            NavigationStack {
                Form {
                    Section("受信リクエスト") {
                        LabeledContent("送信元", value: offer.sender)
                        LabeledContent("ファイル", value: offer.name)
                        LabeledContent("種類", value: FileTypes.category(for: offer.mime))
                        LabeledContent("件数", value: String(offer.count))
                        LabeledContent("サイズ", value: ByteCountFormatter.string(fromByteCount: Int64(offer.total), countStyle: .file))
                    }
                    Section {
                        Button("受信する") { model.decide(true) }.accessibilityIdentifier("acceptTransfer")
                        Button("拒否", role: .destructive) { model.decide(false) }
                    }
                }.navigationTitle("ファイルを受信")
            }.presentationDetents([.medium, .large])
        }
        .sheet(item: $export) { ActivitySheet(url: $0.url) }
    }
}

private struct ExportedFile: Identifiable { let id = UUID(); let url: URL }
private struct ActivitySheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: [url], applicationActivities: nil) }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) { }
}
