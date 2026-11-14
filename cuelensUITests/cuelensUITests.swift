import XCTest

final class CueLensUITests: XCTestCase {
    @MainActor
    func testCreateAssistant() throws {
        let app = XCUIApplication()
        app.launchEnvironment["CUELENS_TEST_WORKSPACE"] = UUID().uuidString
        app.launch()
        let newAssistant = app.buttons["newAssistant"]
        XCTAssertTrue(newAssistant.waitForExistence(timeout: 5))
        newAssistant.click()
        let name = app.textFields["assistantName"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.click()
        name.typeText("Mock interview")
        app.buttons["saveAssistant"].click()
        XCTAssertTrue(newAssistant.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["saveAssistant"].exists)
        XCTAssertTrue(app.buttons["startSession"].isEnabled)
    }

    @MainActor
    func testOptionalAssistantFields() throws {
        let app = XCUIApplication()
        app.launchEnvironment["CUELENS_TEST_WORKSPACE"] = UUID().uuidString
        app.launch()
        let newAssistant = app.buttons["newAssistant"]
        XCTAssertTrue(newAssistant.waitForExistence(timeout: 5))
        newAssistant.click()
        let save = app.buttons["saveAssistant"]
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        XCTAssertTrue(save.isEnabled)
        save.click()
        XCTAssertTrue(newAssistant.waitForExistence(timeout: 5))
        XCTAssertFalse(save.exists)
    }

    @MainActor
    func testSessionCanMinimizeAndEndWithoutAudioOrProvider() throws {
        let app = XCUIApplication()
        app.launchEnvironment["CUELENS_TEST_WORKSPACE"] = UUID().uuidString
        app.launch()
        let start = app.buttons["startSession"]
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        for identifier in ["microphoneToggle", "meetingAudioToggle"] {
            let toggle = app.checkBoxes[identifier]
            XCTAssertTrue(toggle.waitForExistence(timeout: 5))
            if toggle.value as? String == "1" { toggle.click() }
            XCTAssertEqual(toggle.value as? String, "0")
        }
        start.click()
        let panel = app.descendants(matching: .any).matching(identifier: "cuelens.floating").firstMatch
        let compactBar = app.descendants(matching: .any).matching(identifier: "cuelens.bar").firstMatch
        XCTAssertTrue(panel.waitForExistence(timeout: 5))
        // The live controls belong to the same window as transcript and answers.
        XCTAssertTrue(panel.buttons["barAudioSources"].exists)
        XCTAssertTrue(panel.buttons["barEndSession"].exists)
        XCTAssertFalse(compactBar.exists && compactBar.isHittable)
        let minimize = app.buttons["barMinimizeSession"]
        XCTAssertTrue(minimize.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["startSession"].exists)
        XCTAssertFalse(app.buttons["sendQuestion"].isEnabled)
        minimize.click()
        let restore = app.buttons["restoreSession"]
        XCTAssertTrue(restore.waitForExistence(timeout: 5))
        XCTAssertTrue(compactBar.buttons["barEndSession"].exists)
        XCTAssertFalse(app.buttons["sendQuestion"].exists)
        restore.click()
        XCTAssertTrue(app.buttons["sendQuestion"].waitForExistence(timeout: 5))
        XCTAssertTrue(panel.buttons["barEndSession"].exists)
        XCTAssertFalse(compactBar.exists && compactBar.isHittable)
        let end = app.buttons["barEndSession"]
        XCTAssertTrue(end.waitForExistence(timeout: 5))
        end.click()
        // Ending stays in the bar; it must not reopen the full setup window.
        XCTAssertTrue(app.buttons["quickStartSession"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["startSession"].exists)
        XCTAssertFalse(end.exists)
    }
}
