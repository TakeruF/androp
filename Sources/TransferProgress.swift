// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 anDrop contributors

import Foundation

struct TransferProgress {
    let state: String
    let completed: Int64
    let total: Int64

    var fraction: Double? {
        if state == "complete" || state == "confirming" { return 1 }
        guard state == "transferring", total > 0 else { return nil }
        return min(1, max(0, Double(completed) / Double(total)))
    }
    var percent: Int? { fraction.map { Int(($0 * 100).rounded(.down)) } }
    var isIndeterminate: Bool { ["preparing", "waiting", "connecting"].contains(state) || (state == "transferring" && total <= 0) }
    var showsRing: Bool { isIndeterminate || fraction != nil }
    func label(chinese: Bool) -> String {
        switch state {
        case "preparing": return chinese ? "正在准备" : "Preparing"
        case "waiting": return chinese ? "等待接收" : "Waiting"
        case "connecting": return chinese ? "正在连接" : "Connecting"
        case "transferring":
            if let percent { return chinese ? "已发送 \(percent)%" : "Sending \(percent)%" }
            return chinese ? "正在发送" : "Sending"
        case "confirming": return chinese ? "正在确认完成" : "Finishing"
        case "complete": return chinese ? "已发送" : "Sent"
        case "declined": return chinese ? "已拒绝" : "Declined"
        case "cancelled": return chinese ? "已取消" : "Cancelled"
        default: return chinese ? "发送失败" : "Failed"
        }
    }
}

struct OutgoingPresentation {
    let id: String
    let peer: Peer
    let files: [URL]
    var preserveOriginals = false
}

/// Progress updates share one notification and are throttled per transfer.
/// A phase change is immediate; byte/count changes are posted at most every
/// two seconds. Terminal notifications bypass this gate entirely.
struct ProgressNotificationGate {
    private struct Stamp {
        let phase: String
        let value: String
        let time: TimeInterval
    }
    private var stamps: [String: Stamp] = [:]

    mutating func update(id: String, phase: String, value: String, now: TimeInterval) -> Bool? {
        let previous = stamps[id]
        if let previous, previous.phase == phase {
            guard previous.value != value, now - previous.time >= 2 else { return nil }
        }
        stamps[id] = Stamp(phase: phase, value: value, time: now)
        return previous != nil // true means a quiet replacement, not a new alert.
    }

    mutating func remove(_ id: String) { stamps.removeValue(forKey: id) }
}
