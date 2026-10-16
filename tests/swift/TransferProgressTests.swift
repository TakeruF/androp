// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 anDrop contributors

import Foundation
import Testing
@testable import anDropIdentity

@Test func byteProgressDrivesTheRingAndPercent() {
    let p = TransferProgress(state: "transferring", completed: 37, total: 100)
    #expect(p.fraction == 0.37)
    #expect(p.percent == 37)
    #expect(p.label(chinese: false) == "Sending 37%")
    #expect(p.label(chinese: true) == "已发送 37%")
    #expect(!p.isIndeterminate)
}
@Test func waitingStatesDoNotInventPercentages() {
    for state in ["preparing", "waiting", "connecting"] {
        let p = TransferProgress(state: state, completed: 0, total: 1024)
        #expect(p.percent == nil)
        #expect(p.isIndeterminate)
    }
    #expect(TransferProgress(state: "transferring", completed: 0, total: 0).fraction == nil)
}
@Test func fullBytesAndConfirmedReceiptHaveDifferentLabels() {
    let sent = TransferProgress(state: "transferring", completed: 100, total: 100)
    let confirming = TransferProgress(state: "confirming", completed: 100, total: 100)
    let complete = TransferProgress(state: "complete", completed: 0, total: 0)
    #expect(sent.label(chinese: false) == "Sending 100%")
    #expect(confirming.label(chinese: false) == "Finishing")
    #expect(complete.label(chinese: false) == "Sent")
    #expect(confirming.fraction == 1 && complete.fraction == 1)
}
@Test func badProgressCannotDrawOutsideTheCircle() {
    #expect(TransferProgress(state: "transferring", completed: -10, total: 100).fraction == 0)
    #expect(TransferProgress(state: "transferring", completed: 200, total: 100).fraction == 1)
    #expect(TransferProgress(state: "transferring", completed: Int64.max, total: Int64.max).percent == 100)
    for state in ["failed", "declined", "cancelled"] {
        let p = TransferProgress(state: state, completed: 50, total: 100)
        #expect(!p.showsRing)
        #expect(p.percent == nil)
    }
}
