// SPDX-License-Identifier: GPL-3.0-only
import Foundation

public struct TransferProgress: Sendable, Equatable {
    public var stage: String
    public var completedBytes: Int
    public var totalBytes: Int?
    public init(stage: String, completedBytes: Int = 0, totalBytes: Int? = nil) {
        self.stage = stage; self.completedBytes = max(0, completedBytes); self.totalBytes = totalBytes
    }
    public var succeeded: Bool { ["send_complete", "receive_complete"].contains(stage) }
    public var terminal: Bool { succeeded || ["cancelled", "failed", "declined", "send_unconfirmed", "background_expired"].contains(stage) }
    public var completedUnits: Int64 {
        if succeeded { return 1000 }
        guard let totalBytes, totalBytes > 0 else { return 0 }
        // Completion requires peer confirmation / integrity checks, not just
        // the last network byte. Reserve the last percent until that succeeds.
        return Int64(max(0, min(1, Double(completedBytes) / Double(totalBytes))) * 990)
    }
    public var subtitle: String {
        let label: String = switch stage {
        case "preparing_files": "ファイルを準備中"
        case "huawei_authenticating": "Huawei Shareに接続中"
        case "connecting_bluetooth", "key_exchange", "negotiating_network", "connecting_control", "control_connected", "send_lan_confirmed": "端末に接続中"
        case "waiting_for_recipient", "awaiting_acceptance": "相手の受信許可待ち"
        case "sending_archive": "送信中"
        case "downloading_archive": "受信中"
        case "checking_archive": "整合性を確認中"
        case "awaiting_confirmation": "相手の完了確認待ち"
        case "send_complete": "送信が完了しました"
        case "receive_complete": "受信が完了しました"
        case "cancelled": "キャンセルしました"
        case "declined": "相手が受信を拒否しました"
        case "send_unconfirmed": "相手の受信完了を確認できませんでした"
        case "background_expired": "バックグラウンド転送が中止されました"
        case "failed": "転送に失敗しました"
        default: "転送を準備中"
        }
        guard !terminal, let totalBytes, totalBytes > 0, completedBytes > 0 else { return label }
        return label + " · " + ByteCountFormatter.string(fromByteCount: Int64(min(completedBytes, totalBytes)), countStyle: .file) + " / " + ByteCountFormatter.string(fromByteCount: Int64(totalBytes), countStyle: .file)
    }
}
