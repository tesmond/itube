import XCTest

/// Smoke tests: the shell launches and every primary destination is reachable (ADR §60).
final class ITubeUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    func testTabsAreReachable() {
        let app = XCUIApplication()
        app.launch()
        for name in ["Home", "Search", "Library", "Settings"] {
            let tab = app.tabBars.buttons[name]
            XCTAssertTrue(tab.waitForExistence(timeout: 5), "\(name) tab missing")
            tab.tap()
        }
    }

    func testSettingsShowsPrivacySection() {
        let app = XCUIApplication()
        app.launch()
        app.tabBars.buttons["Settings"].tap()
        XCTAssertTrue(app.staticTexts["Privacy & Storage"].waitForExistence(timeout: 5))
    }
}
