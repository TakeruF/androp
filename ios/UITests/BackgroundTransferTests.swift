// SPDX-License-Identifier: GPL-3.0-only
import XCTest

final class BackgroundTransferTests: XCTestCase {
    @MainActor func testAcceptedReceiveContinuesOnHomeScreen() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Continued processing requires a physical device.")
        #else
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing", "--background-transfer-test"]; app.launch()
        XCTAssertTrue(app.buttons["verifyBackgroundReceive"].waitForExistence(timeout: 5))
        app.buttons["verifyBackgroundReceive"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.buttons["acceptTransfer"].waitForExistence(timeout: 10), app.debugDescription)
        app.buttons["acceptTransfer"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.staticTexts["ファイルを受信中"].waitForExistence(timeout: 12), app.debugDescription)
        XCUIDevice.shared.press(.home)
        let began = Date()
        let show = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in Date().timeIntervalSince(began) >= 4 }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [show], timeout: 8), .completed)
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); attachment.name = "Receive system progress"; attachment.lifetime = .keepAlways; add(attachment)
        // Notification Center uses the Lock Screen presentation without locking
        // the paired test device or requiring the user's passcode.
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.001)).press(forDuration: 0.1, thenDragTo: springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.8)))
        let lockPresentation = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); lockPresentation.name = "Receive progress in Notification Center"; lockPresentation.lifetime = .keepAlways; add(lockPresentation)
        let finish = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in Date().timeIntervalSince(began) >= 25 }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [finish], timeout: 30), .completed)
        app.activate()
        XCTAssertTrue(app.staticTexts["バックグラウンドで受信完了"].waitForExistence(timeout: 5), app.debugDescription)
        #endif
    }
    @MainActor func testShareExtensionHandsOffBackgroundTransfer() throws {
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing", "--background-transfer-test"]; app.launch()
        XCTAssertTrue(app.buttons["verifyBackgroundTransfer"].waitForExistence(timeout: 5))
        XCUIDevice.shared.press(.home)
        let host = XCUIApplication(bundleIdentifier: "com.takeruf.androp.sharefixture"); host.launch()
        XCTAssertTrue(host.buttons["shareBackground"].waitForExistence(timeout: 5)); host.buttons["shareBackground"].tap()
        let direct = host.cells.matching(NSPredicate(format: "label == %@", "anDrop")).firstMatch
        _ = direct.waitForExistence(timeout: 2)
        for _ in 0..<16 {
            if direct.exists, direct.frame.midX > 20, direct.frame.midX < host.frame.width - 20 { break }
            let more = host.cells.matching(NSPredicate(format: "label IN %@", ["More", "その他"])).firstMatch
            if more.exists { break }
            let cells = host.cells.matching(identifier: "shareCell")
            guard cells.count >= 2 else { break }
            let start = cells.element(boundBy: min(3, cells.count - 1)).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            let end = cells.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            start.press(forDuration: 0.1, thenDragTo: end)
        }
        if direct.exists, direct.frame.midX > 20, direct.frame.midX < host.frame.width - 20 {
            direct.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
        else {
            let more = host.cells.matching(NSPredicate(format: "label IN %@", ["More", "その他"])).firstMatch
            XCTAssertTrue(more.waitForExistence(timeout: 5), host.debugDescription); more.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            let row = host.staticTexts["anDrop"].firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 5), host.debugDescription); row.tap()
        }
        XCTAssertTrue(host.staticTexts["background-verification.bin"].waitForExistence(timeout: 10), host.debugDescription)
        let send = host.buttons["verifySharedBackgroundTransfer"]
        for _ in 0..<3 {
            if send.exists { break }
            host.descendants(matching: .any).matching(identifier: "shareFileList").firstMatch.swipeUp()
        }
        send.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(host.staticTexts["anDrop本体を開くと送信を開始します"].waitForExistence(timeout: 5))
        host.buttons["closeShare"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 12), host.debugDescription)
        XCTAssertTrue(app.staticTexts["ファイルを送信中"].waitForExistence(timeout: 12), app.debugDescription)
        #if targetEnvironment(simulator)
        XCTAssertTrue(app.staticTexts["前面で転送完了"].waitForExistence(timeout: 35), app.debugDescription)
        #else
        XCUIDevice.shared.press(.home)
        let began = Date()
        let show = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in Date().timeIntervalSince(began) >= 4 }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [show], timeout: 8), .completed)
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); attachment.name = "Shared transfer system progress"; attachment.lifetime = .keepAlways; add(attachment)
        let finish = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in Date().timeIntervalSince(began) >= 25 }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [finish], timeout: 30), .completed)
        app.activate()
        XCTAssertTrue(app.staticTexts["バックグラウンドで転送完了"].waitForExistence(timeout: 5), app.debugDescription)
        #endif
    }
    @MainActor func testTransferContinuesOnHomeScreen() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("BGContinuedProcessingTask is unavailable on Simulator; verify this flow on a physical iPhone.")
        #else
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing", "--background-transfer-test"]; app.launch()
        XCTAssertTrue(app.buttons["verifyBackgroundTransfer"].waitForExistence(timeout: 5))
        app.buttons["verifyBackgroundTransfer"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.staticTexts["ファイルを送信中"].waitForExistence(timeout: 12), app.debugDescription)
        XCUIDevice.shared.press(.home)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        XCTAssertTrue(springboard.wait(for: .runningForeground, timeout: 5))
        let began = Date()
        let showProgress = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in Date().timeIntervalSince(began) >= 4 }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [showProgress], timeout: 8), .completed)
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); attachment.name = "System transfer progress on Home Screen"; attachment.lifetime = .keepAlways; add(attachment)
        // Activation preserves the running process and its in-flight transfer.
        // The transfer itself takes around twenty seconds at the QA-only rate.
        let finishInBackground = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in Date().timeIntervalSince(began) >= 25 }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [finishInBackground], timeout: 30), .completed)
        app.activate()
        XCTAssertTrue(app.staticTexts["バックグラウンドで転送完了"].waitForExistence(timeout: 5), app.debugDescription)
        #endif
    }
    @MainActor func testUnavailableSchedulerShowsForegroundFallback() throws {
        #if targetEnvironment(simulator)
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing", "--background-transfer-test"]; app.launch()
        app.buttons["verifyBackgroundTransfer"].tap()
        XCTAssertTrue(app.staticTexts["バックグラウンド転送を開始できませんでした。完了までこの画面を開いてください。"].waitForExistence(timeout: 8))
        #else
        throw XCTSkip("This case verifies the Simulator's unsupported scheduler.")
        #endif
    }
}
