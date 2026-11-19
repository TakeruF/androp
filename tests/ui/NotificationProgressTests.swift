// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 anDrop contributors
// Appended to the isolated production host by test_outgoing_selection.py.

extension AppModel {
    func exerciseProgressNotifications() {
        let oldLanguage = selectionTestDefaults.object(forKey: "language")
        selectionTestDefaults.set("en", forKey: "language")
        defer { selectionTestDefaults.set(oldLanguage, forKey: "language") }
        var transfer = Transfer(id: "notification-progress", direction: "send", peer: "Test phone", state: "transferring", total: 100, completed: 42)
        let start = selectionTestNotificationRequests.count
        updateTransferProgressNotification(transfer, now: 100)
        let first = selectionTestNotificationRequests.last!
        precondition(first.identifier == transfer.id && first.content.title == "Sending 42%")
        precondition(first.content.body == "Test phone · 1 file" && first.content.sound == nil)
        precondition(first.content.userInfo["progressUpdate"] as? Bool == false)

        transfer.completed = 43
        updateTransferProgressNotification(transfer, now: 101)
        precondition(selectionTestNotificationRequests.count == start + 1, "Throttle rapid byte/count updates")
        updateTransferProgressNotification(transfer, now: 102)
        let replacement = selectionTestNotificationRequests.last!
        precondition(replacement.identifier == first.identifier && replacement.content.title == "Sending 43%")
        precondition(replacement.content.userInfo["progressUpdate"] as? Bool == true)
        precondition(replacement.content.interruptionLevel == .passive && replacement.content.sound == nil)
        transfer.state = "confirming"
        updateTransferProgressNotification(transfer, now: 102.1)
        precondition(selectionTestNotificationRequests.last!.content.title == "Finishing", "Report a new protocol phase immediately")

        dismissedProgressNotifications.insert(transfer.id)
        let dismissedCount = selectionTestNotificationRequests.count
        transfer.state = "transferring"; transfer.completed = 90
        updateTransferProgressNotification(transfer, now: 110)
        precondition(selectionTestNotificationRequests.count == dismissedCount, "Progress must not resurface a dismissed notification")
        updateTransfer(["id": transfer.id, "direction": "send", "state": "complete"])
        precondition(selectionTestNotificationRequests.last!.content.categoryIdentifier == "complete")
        precondition(!dismissedProgressNotifications.contains(transfer.id))

        transfer.id = "notification-receive"; transfer.direction = "receive"; transfer.completed = 37
        updateTransferProgressNotification(transfer, now: 120)
        precondition(selectionTestNotificationRequests.last!.content.title == "Receiving 37%")
        transfer.id = "notification-unknown-size"; transfer.total = 0
        updateTransferProgressNotification(transfer, now: 120)
        precondition(selectionTestNotificationRequests.last!.content.title == "Receiving", "Do not invent percentages for unknown totals")
        precondition(!selectionTestNotificationRequests.last!.content.body.contains("menu bar"))
        print("Notification progress integration scenarios passed")
    }
}

let progressNotificationModel = AppModel()
progressNotificationModel.exerciseProgressNotifications()
