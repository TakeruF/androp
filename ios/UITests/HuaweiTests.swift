// SPDX-License-Identifier: GPL-3.0-only
import XCTest

final class HuaweiTests: XCTestCase {
    @MainActor func testExperimentalHuaweiControlsRejectInvalidAddress() {
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing"]; app.launch()
        let settings = app.buttons["Huawei Share（試験）"]
        for _ in 0..<6 {
            if settings.exists, settings.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(settings.waitForExistence(timeout: 5)); settings.tap()
        let address = app.textFields["huaweiAddress"]
        if !address.isHittable { app.swipeUp() }
        XCTAssertTrue(address.waitForExistence(timeout: 5)); address.tap(); address.typeText("8.8.8.8")
        app.buttons["finishHuaweiAddress"].tap()
        app.buttons["findHuawei"].tap()
        XCTAssertTrue(app.staticTexts["同じWi-Fi上の端末のIPv4アドレスを指定してください。"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Huaweiからの受信は未対応です。")).firstMatch.exists)
        app.buttons["登録を解除"].tap()
        XCTAssertEqual(address.value as? String, "Huawei端末のIPv4アドレス")
    }
}
