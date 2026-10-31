// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 anDrop contributors
// Appended to a disposable production-host copy by test_outgoing_selection.py.

extension AppModel {
    func exerciseNotificationExpiry() {
        let deliveredAt = Date(timeIntervalSince1970: 1_000)
        for category in ["complete", "failed"] {
            let deadline = Self.transferNotificationExpiration(category: category, deliveredAt: deliveredAt)!
            precondition(deadline.timeIntervalSince(deliveredAt) == 180)
            precondition(deadline > deliveredAt.addingTimeInterval(179.999), "Keep notifications for the full three minutes")
            precondition(deadline <= deliveredAt.addingTimeInterval(180), "Expire at three minutes")
            precondition(deadline < deliveredAt.addingTimeInterval(3 * 24 * 60 * 60), "Clean up old delivered notifications")
        }
        for category in ["receive", "manage", "", "update"] {
            precondition(Self.transferNotificationExpiration(category: category, deliveredAt: deliveredAt) == nil,
                         "Only completed and failed transfer notifications expire")
        }

        // New notifications cannot push an older notification's deadline back.
        let firstDeadline = Date().addingTimeInterval(180)
        scheduleNotificationCleanup(at: firstDeadline)
        let firstTimer = notificationCleanupTimer!
        precondition(firstTimer.isValid && firstTimer.fireDate == firstDeadline)
        scheduleNotificationCleanup(at: firstDeadline.addingTimeInterval(60))
        precondition(notificationCleanupTimer === firstTimer)
        let earlierDeadline = firstDeadline.addingTimeInterval(-30)
        scheduleNotificationCleanup(at: earlierDeadline)
        precondition(!firstTimer.isValid)
        precondition(notificationCleanupTimer?.fireDate == earlierDeadline)
        notificationCleanupTimer?.invalidate()
        notificationCleanupTimer = nil
    }
}

let notificationExpiryModel = AppModel()
notificationExpiryModel.exerciseNotificationExpiry()
print("Notification expiry regression scenarios passed")
