// SPDX-License-Identifier: GPL-3.0-only
import XCTest

final class ShareExtensionTests: XCTestCase {
    @MainActor func testFourPhotosFromPhotoLibrary() throws {
        let container = XCUIApplication(); container.launchArguments = ["--ui-testing"]; container.launch(); container.terminate()
        let photos = XCUIApplication(bundleIdentifier: "com.apple.mobileslideshow")
        photos.launch()
        let welcome = photos.buttons["Continue"]
        if welcome.waitForExistence(timeout: 2) { welcome.tap() }
        let back = photos.buttons["PUOneUpBarButtonItemIdentifierDone"]
        if back.waitForExistence(timeout: 2) { back.tap() }
        if welcome.waitForExistence(timeout: 2) { welcome.tap() }
        if photos.buttons["Cancel"].exists { photos.buttons["Cancel"].tap() }
        let images = photos.images.matching(identifier: "PXGGridLayout-Info").matching(NSPredicate(format: "label CONTAINS %@", "Screenshot"))
        guard images.count >= 4 else { throw XCTSkip("Seed four QA screenshots in the simulator Photos library before running this optional test.") }
        photos.buttons["Select"].tap()
        for index in 0..<4 { images.element(boundBy: index).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap() }
        let share = photos.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Share")).firstMatch
        XCTAssertTrue(share.waitForExistence(timeout: 5), photos.debugDescription); share.tap()
        guard openShareTarget(in: photos) else { return }
        XCTAssertTrue(photos.staticTexts["送信先を選んでください"].waitForExistence(timeout: 10), photos.debugDescription)
        let attachment = XCTAttachment(screenshot: photos.screenshot()); attachment.name = "Four Photos library files imported"; attachment.lifetime = .keepAlways; add(attachment)
        photos.buttons["closeShare"].tap()
    }
    @MainActor func testPDFAndImageSharingFromAnotherApp() {
        let container = XCUIApplication(); container.launchArguments = ["--ui-testing"]; container.launch()
        XCTAssertTrue(container.navigationBars["anDrop"].waitForExistence(timeout: 5)); container.terminate()
        let host = XCUIApplication(bundleIdentifier: "com.takeruf.androp.sharefixture")
        host.launch()
        XCTAssertTrue(host.buttons["sharePDF"].waitForExistence(timeout: 5))
        host.buttons["sharePDF"].tap()
        guard openShareTarget(in: host) else { return }
        XCTAssertTrue(host.navigationBars["anDropで送信"].waitForExistence(timeout: 8), host.debugDescription)
        XCTAssertTrue(host.staticTexts["Share Fixture.pdf"].waitForExistence(timeout: 8))
        host.buttons["closeShare"].tap()
        XCTAssertTrue(host.buttons["shareImages"].waitForExistence(timeout: 5))
        host.buttons["shareImages"].tap()
        guard openShareTarget(in: host) else { return }
        XCTAssertTrue(host.staticTexts["original-one.png"].waitForExistence(timeout: 8))
        XCTAssertTrue(host.staticTexts["original-two.png"].exists)
        let attachment = XCTAttachment(screenshot: host.screenshot()); attachment.name = "Share extension imported two original images"; attachment.lifetime = .keepAlways; add(attachment)
        let diagnostic = host.buttons["診断ログをコピー"]
        for _ in 0..<3 {
            if diagnostic.exists { break }
            host.descendants(matching: .any).matching(identifier: "shareFileList").firstMatch.swipeUp()
        }
        diagnostic.tap()
        XCTAssertTrue(host.buttons["診断ログをコピーしました"].exists)
        host.buttons["closeShare"].tap()
        XCTAssertTrue(host.buttons["sharePDF"].waitForExistence(timeout: 5))
        host.buttons["shareURL"].tap()
        XCTAssertFalse(host.cells.matching(NSPredicate(format: "label == %@", "anDrop")).firstMatch.waitForExistence(timeout: 2))
        let more = host.cells.matching(NSPredicate(format: "label == %@", "More")).firstMatch
        if more.waitForExistence(timeout: 2) { more.tap(); XCTAssertFalse(host.staticTexts["anDrop"].exists) }
    }
    @MainActor private func openShareTarget(in host: XCUIApplication) -> Bool {
        let action = host.cells.matching(NSPredicate(format: "label == %@", "anDrop")).firstMatch
        if action.waitForExistence(timeout: 2) { action.tap(); return true }
        let more = host.cells.matching(NSPredicate(format: "label == %@", "More")).firstMatch
        guard more.waitForExistence(timeout: 5) else { XCTFail("More share actions not found: \(host.debugDescription)"); return false }
        more.tap()
        let row = host.staticTexts["anDrop"].firstMatch
        guard row.waitForExistence(timeout: 5) else { XCTFail("Share target not found: \(host.debugDescription)"); return false }
        row.tap(); return true
    }
}
