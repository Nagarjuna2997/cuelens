import XCTest

final class CueLensUITests: XCTestCase {
    @MainActor
    func testCreateAssistant() throws {
        let app = XCUIApplication()
        app.launchEnvironment["CUELENS_TEST_WORKSPACE"] = UUID().uuidString
        app.launch()
        app.buttons["overviewPrimaryAction"].click()
        let name = app.textFields["assistantName"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.click()
        name.typeText("Mock interview")
        app.buttons["saveAssistant"].click()
        XCTAssertTrue(app.staticTexts["Start a session"].waitForExistence(timeout: 5))
    }
}
