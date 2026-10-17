// SPDX-License-Identifier: GPL-3.0-only
// Appended to the isolated production-host harness. Only OS boundaries are faked.

extension AppModel {
    func exercisePetalCoexistence() {
        func drainAlerts() {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
        }
        func event(_ id: String, _ direction: String, _ state: String) {
            updateTransfer(["id": id, "direction": direction, "state": state])
        }
        petalTestRunning = false
        // A stale UI flag must not produce a recommendation after Petal exits.
        petalRunning = true
        event("without-petal", "send", "failed")
        drainAlerts()
        precondition(petalTestAlerts.isEmpty)

        petalTestRunning = true
        petalRunning = false // Detection must not wait for the environment timer.
        for state in ["complete", "declined", "cancelled", "transferring"] {
            event("nonfailure-" + state, "send", state)
            event("receive-nonfailure-" + state, "receive", state)
        }
        drainAlerts()
        precondition(petalTestAlerts.isEmpty, "Only failures warrant a recommendation")
        transfers = []

        for (language, direction) in [("en", "send"), ("zh", "receive")] {
            selectionTestDefaults.set(language, forKey: "language")
            let id = "petal-" + direction
            let count = petalTestAlerts.count
            event(id, direction, "failed")
            event(id, direction, "failed") // Duplicate terminal update.
            event(id + "-sibling", direction, "failed") // Same failure burst.
            precondition(petalRecommendationPending)
            drainAlerts()
            precondition(petalTestAlerts.count == count + 1, "Do not stack failure alerts")
            precondition(petalRecommendationPending, "Keep one alert until it is dismissed")
            let alert = petalTestAlerts.last!
            precondition(alert.buttons.count == 1, "The alert recommends; it never quits an app")
            if language == "zh" {
                precondition(alert.messageText == "建议退出鸿蒙星河互联")
                precondition(alert.informativeText.contains("独立通过华为分享收发文件"))
            } else {
                precondition(alert.messageText == "Try quitting Petal Interconnect")
                precondition(alert.informativeText.contains("Finish any transfers in Petal"))
            }
            event(id + "-later-failure", direction, "failed")
            event("continuing-send", "send", "transferring")
            drainAlerts()
            precondition(petalTestAlerts.count == count + 1, "An open alert covers later failures")
            event("continuing-send", "send", "complete")
            precondition(transfers.first { $0.id == "continuing-send" }?.state == "complete",
                         "Other transfers continue updating while the alert is open")
            alert.buttons[0].performClick(nil)
            precondition(!petalRecommendationPending && petalRecommendationAlert == nil)
            event(id, direction, "failed")
            drainAlerts()
            precondition(petalTestAlerts.count == count + 1, "Repeated terminal events stay silent")
        }

        let count = petalTestAlerts.count
        event("petal-exits-before-alert", "receive", "failed")
        petalTestRunning = false
        drainAlerts()
        precondition(petalTestAlerts.count == count && !petalRecommendationPending)

        petalTestRunning = true
        event("shutdown", "send", "failed")
        terminating = true
        drainAlerts()
        precondition(petalTestAlerts.count == count && !petalRecommendationPending)
        petalTestRunning = false
    }
}

AppModel().exercisePetalCoexistence()
print("Petal coexistence regression scenarios passed")
