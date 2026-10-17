// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 anDrop contributors
// Appended to a disposable production-host copy by test_outgoing_selection.py.

extension AppModel {
    func exerciseOutgoingSelection() throws {
        let first = URL(fileURLWithPath: "/mock/前回.txt")
        let second = URL(fileURLWithPath: "/mock/今回.pdf")
        let third = URL(fileURLWithPath: "/mock/追加.png")
        let peer = Peer(id: "mock-phone", name: "Test phone", brand: "OPPO", kind: .phone)

        func selectPeer() {
            peers = [peer]
            engineReady = true
        }
        func readCommands(_ pipe: Pipe) throws -> [[String: Any]] {
            input = nil
            try pipe.fileHandleForWriting.close()
            return try pipe.fileHandleForReading.readDataToEndOfFile()
                .split(separator: 10).map {
                    try JSONSerialization.jsonObject(with: Data($0)) as! [String: Any]
                }
        }

        let other = Peer(id: "mock-huawei", name: "Other phone", brand: "Huawei", kind: .phone)
        peers = [peer, other]; engineReady = true; input = FileHandle.nullDevice
        addFiles([first])
        let batchPipe = Pipe(); input = batchPipe.fileHandleForWriting
        send(to: peer)
        precondition(outgoing.count == 1 && outgoingActive, "One click starts the first send")
        precondition(canSend(to: other), "Another device stays clickable while sending")
        precondition(!canSend(to: peer), "Started recipients must not be duplicated")
        precondition(visiblePeers.contains { $0.id == other.id }, "Unsent devices stay visible")
        // A queued Finder selection must never replace the batch sent to others.
        addFiles([second])
        send(to: peer) // A rapid duplicate click must be ignored.
        send(to: other)
        precondition(selectedFiles == [second], "The next selection stays queued")
        send(to: other) // A duplicate click on the second recipient is ignored too.
        precondition(outgoing.count == 2 && outgoingActive)
        precondition(Set(visiblePeers.map(\.id)) == [peer.id, other.id])
        let allBatchCommands = try readCommands(batchPipe)
        precondition(!allBatchCommands.contains { $0["command"] as? String == "scan" && $0["value"] as? Bool == false }, "Sending must not stop discovery")
        let batchCommands = allBatchCommands.filter { $0["command"] as? String == "send" }
        precondition(batchCommands.count == 2)
        precondition(Set(batchCommands.compactMap { $0["peer"] as? String }) == [peer.id, other.id])
        precondition(Set(batchCommands.compactMap { $0["request_id"] as? String }).count == 2)
        precondition(batchCommands.allSatisfy { $0["paths"] as? [String] == [first.path] })
        let firstID = outgoing.first { $0.peer.id == peer.id }!.id
        let otherID = outgoing.first { $0.peer.id == other.id }!.id
        updateTransfer(["id": firstID, "state": "failed", "detail": "Test failure"])
        precondition(outgoingActive && !outgoingComplete)
        precondition(outgoingTransfer(for: other)?.state == "preparing")
        // Retry only the failed recipient while its sibling continues sending.
        peers = [peer]; lastPeerUpdate = .now
        let retryBatchPipe = Pipe(); input = retryBatchPipe.fileHandleForWriting
        retryOutgoing(firstID)
        peers = [peer]; lastPeerUpdate = .now
        attemptOutgoingRetry()
        let retryCommands = try readCommands(retryBatchPipe).filter { $0["command"] as? String == "send" }
        precondition(retryCommands.count == 1 && retryCommands[0]["peer"] as? String == peer.id)
        precondition(outgoing.count == 2 && outgoingTransfer(for: other)?.id == otherID)
        let retriedID = outgoing.first { $0.peer.id == peer.id }!.id
        updateTransfer(["id": retriedID, "state": "complete"])
        precondition(!outgoingComplete && outgoingActive, "One completion must not dismiss another active send")
        let cancelPipe = Pipe(); input = cancelPipe.fileHandleForWriting
        cancelOrCloseRecipients()
        let cancelCommands = try readCommands(cancelPipe).filter { $0["command"] as? String == "cancel" }
        precondition(cancelCommands.count == 1 && cancelCommands[0]["id"] as? String == otherID)
        updateTransfer(["id": otherID, "state": "complete"])
        precondition(outgoingComplete)
        // Completed sends stay visible, and a newly discovered device is clickable.
        let later = Peer(id: "later-phone", name: "Later phone", brand: "OPPO", kind: .phone)
        peers = [later]; lastPeerUpdate = .now
        precondition(Set(visiblePeers.map(\.id)) == [peer.id, other.id, later.id])
        precondition(canSend(to: later))
        let laterPipe = Pipe(); input = laterPipe.fileHandleForWriting
        send(to: later)
        let laterCommands = try readCommands(laterPipe)
        precondition(laterCommands.first?["paths"] as? [String] == [first.path])
        precondition(selectedFiles == [second])
        updateTransfer(["id": outgoing.last!.id, "state": "complete"])

        // A hidden or disappeared recipient cannot receive the batch.
        outgoing = []; transfers = []; selectedFiles = []
        addFiles([second]); peers = [peer, other]
        hidePeer(other)
        let missingPipe = Pipe(); input = missingPipe.fileHandleForWriting
        send(to: other)
        peers = []
        send(to: peer)
        precondition(selectedFiles == [second])
        let missingCommands = try readCommands(missingPipe)
        precondition(missingCommands.isEmpty)
        hiddenDevices = HiddenDevices()

        peers = [peer]; lastPeerUpdate = .now
        transfers = [Transfer(id: "incoming", direction: "receive", state: "transferring")]
        precondition(!canSend(to: peer))
        transfers = []
        lastPeerUpdate = .now.advanced(by: .seconds(-7))
        let stalePipe = Pipe(); input = stalePipe.fileHandleForWriting
        send(to: peer)
        let staleCommands = try readCommands(stalePipe)
        precondition(staleCommands.isEmpty && selectedFiles == [second])

        for selectsDuringTransfer in [false, true] {
            for state in ["declined", "failed", "cancelled", "complete"] {
                outgoing = []; transfers = []; selectedFiles = []
                addFiles([first]); selectPeer()
                let pipe = Pipe()
                input = pipe.fileHandleForWriting
                send(to: peer)
                let id = outgoing.first!.id
                precondition(selectedFiles.isEmpty, "Started files must leave the selection")
                precondition(recipientFiles == [first], "Progress must retain the original batch")
                let commands = try readCommands(pipe)
                precondition(commands.first?["paths"] as? [String] == [first.path])

                // New files may arrive from Finder while the first transfer is active.
                if selectsDuringTransfer { addFiles([second]) }
                precondition(recipientFiles == [first])
                updateTransfer(["id": id, "state": state])
                if selectsDuringTransfer {
                    precondition(selectedFiles == [second], "A terminal event must preserve later selections")
                } else {
                    addFiles([second])
                    precondition(recipientFiles == [second])
                }
                if selectsDuringTransfer {
                    precondition(recipientFiles == [first], "Keep the finished transfer visible")
                }
                addFiles([third])
                precondition(outgoing.isEmpty)
                precondition(Set(selectedFiles) == Set([second, third]))
                precondition(!recipientFiles.contains(first), "Finished files must not reappear")

                selectPeer()
                let nextPipe = Pipe()
                input = nextPipe.fileHandleForWriting
                send(to: peer)
                let nextCommands = try readCommands(nextPipe)
                let paths = nextCommands.first?["paths"] as! [String]
                precondition(Set(paths) == Set([second.path, third.path]), "Only new files may be sent")
            }
        }

        // A failure to submit the command must also consume the attempted batch.
        outgoing = []; transfers = []; selectedFiles = []
        addFiles([first]); selectPeer(); input = nil
        send(to: peer)
        precondition(outgoingTransfers.first?.state == "failed")
        precondition(selectedFiles.isEmpty)
        precondition(recipientFiles == [first])
        addFiles([second])
        precondition(recipientFiles == [second])

        // Before sending, adding and deduplicating a multi-file batch still works.
        addFiles([second, third, URL(string: "https://example.com/file")!])
        precondition(Set(selectedFiles) == Set([second, third]))
        selectPeer(); engineReady = false
        send(to: peer)
        precondition(Set(selectedFiles) == Set([second, third]), "An unavailable service must preserve unsubmitted files")

        for state in ["declined", "failed"] {
            cancelOutgoingRetry(); outgoing = []; transfers = []; selectedFiles = []
            addFiles([first]); selectPeer()
            let initialPipe = Pipe()
            input = initialPipe.fileHandleForWriting
            send(to: peer)
            let previousID = outgoing.first!.id
            _ = try readCommands(initialPipe)
            addFiles([second])
            updateTransfer(["id": previousID, "state": state])

            // A same-named device must never receive the retry by mistake.
            peers = [Peer(id: "different-phone", name: peer.name, brand: peer.brand, kind: peer.kind)]
            let retryPipe = Pipe()
            input = retryPipe.fileHandleForWriting
            retryOutgoing(outgoing.first!.id)
            precondition(pendingRetryIDs == [previousID])
            retryOutgoing(outgoing.first!.id) // Double clicks must not create another request.
            attemptOutgoingRetry()
            precondition(outgoing.first?.id == previousID)

            // A newly discovered route for the original identity can proceed.
            peers = [Peer(id: peer.id, name: "Refreshed phone", brand: peer.brand, kind: peer.kind)]
            lastPeerUpdate = .now
            attemptOutgoingRetry()
            precondition(pendingRetryIDs.isEmpty)
            precondition(outgoing.first?.id != previousID)
            precondition(outgoing.first?.peer.name == "Refreshed phone")
            precondition(outgoing.first?.files == [first])
            precondition(selectedFiles == [second], "Retry must preserve the next selection")
            precondition(outgoingTransfers.first?.state == "preparing")
            retryOutgoing(outgoing.first!.id) // An active retry must not be duplicated either.
            let commands = try readCommands(retryPipe)
            let sends = commands.filter { $0["command"] as? String == "send" }
            precondition(sends.count == 1)
            precondition(sends[0]["paths"] as? [String] == [first.path])
            precondition(sends[0]["peer"] as? String == peer.id)
            precondition(sends[0]["request_id"] as? String == outgoing.first?.id)

            // A second failure may be retried; cancelling discovery stops it.
            updateTransfer(["id": outgoing.first!.id, "state": state])
            peers = [] // Exercise cancellation while rediscovery is still pending.
            let cancelledPipe = Pipe()
            input = cancelledPipe.fileHandleForWriting
            retryOutgoing(outgoing.first!.id)
            precondition(!pendingRetryIDs.isEmpty)
            cancelOrCloseRecipients()
            precondition(pendingRetryIDs.isEmpty)
            peers = [peer]; lastPeerUpdate = .now
            attemptOutgoingRetry()
            let cancelledCommands = try readCommands(cancelledPipe)
            precondition(!cancelledCommands.contains { $0["command"] as? String == "send" })

            // Selecting new files abandons the retry of the previous batch.
            input = FileHandle.nullDevice
            peers = []
            retryOutgoing(outgoing.first!.id)
            precondition(!pendingRetryIDs.isEmpty)
            addFiles([third])
            precondition(pendingRetryIDs.isEmpty && outgoing.isEmpty)
            precondition(Set(selectedFiles) == Set([second, third]))
            input = nil
        }
    }
}

let testApp = NSApplication.shared
// The application delegate is never installed: no engine, Bluetooth or updater.
defer { selectionTestDefaults.removePersistentDomain(forName: CommandLine.arguments[2]) }
try AppModel().exerciseOutgoingSelection()
print("Outgoing selection regression scenarios passed")
