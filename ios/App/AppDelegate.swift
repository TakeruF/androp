// SPDX-License-Identifier: GPL-3.0-only
import UIKit

@MainActor final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        try? BackgroundTransfer.store().discardInterrupted()
        #if DEBUG
        let verification = ProcessInfo.processInfo.arguments.contains("--background-transfer-test")
        let preferences = UserDefaults(suiteName: BackgroundTransfer.groupIdentifier)
        preferences?.set(verification, forKey: "localBackgroundVerification")
        preferences?.set(verification ? Date().addingTimeInterval(600).timeIntervalSince1970 : 0, forKey: "localBackgroundVerificationExpiry")
        if ProcessInfo.processInfo.arguments.contains("--background-transfer-test") { application.isIdleTimerDisabled = true }
        #endif
        return true
    }
}
