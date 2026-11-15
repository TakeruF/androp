// SPDX-License-Identifier: GPL-3.0-only
import XCTest

final class AppTests: XCTestCase {
    @MainActor func testPrepareSampleAndInspectDiagnostics() {
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing"]; app.launch()
        XCTAssertTrue(app.navigationBars["anDrop"].waitForExistence(timeout: 5))
        app.buttons["makeSample"].tap()
        XCTAssertTrue(app.staticTexts["anDrop-test.txt"].exists)
        let type = app.descendants(matching: .any).matching(identifier: "selectedFileType").firstMatch
        XCTAssertTrue(type.exists)
        XCTAssertEqual(type.value as? String, "テキスト")
        tab("診断", in: app).tap()
        XCTAssertTrue(app.buttons["exportDiagnostics"].exists)
        XCTAssertTrue(app.staticTexts["ui_test_started"].exists)
        tab("受信履歴", in: app).tap()
        XCTAssertTrue(app.staticTexts["受信したファイルはありません"].exists)
        tab("転送", in: app).tap()
        app.buttons["receiveToggle"].tap()
        XCTAssertTrue(app.buttons["待受を開始"].exists)
        app.buttons["receiveToggle"].tap()
        XCTAssertTrue(app.buttons["待受を一時停止"].exists)
    }
    @MainActor private func tab(_ title: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label == %@ AND (elementType == %d OR elementType == %d)", title, XCUIElement.ElementType.button.rawValue, XCUIElement.ElementType.cell.rawValue)).firstMatch
    }
}
