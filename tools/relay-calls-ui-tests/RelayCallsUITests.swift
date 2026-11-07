import XCTest

final class RelayCallsUITests: XCTestCase {
    @MainActor
    private func dismissSystemPrompts() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for _ in 0..<3 {
            let allow = springboard.alerts.buttons["Allow"]
            guard allow.waitForExistence(timeout: 1) else { return }
            allow.tap()
        }
    }

    @MainActor
    func testJoinAndMute() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "org.relaychat.Relay")
        app.activate()
        dismissSystemPrompts()
        if !app.staticTexts["Connected"].exists {
            let call = app.descendants(matching: .any).matching(identifier: "Start or join voice call").firstMatch
            if call.exists {
                call.tap()
            } else {
                XCTFail("Open the isolated call before running the media-control checks; the current Telegram navigation renderer does not always expose its phone icon to accessibility.")
                return
            }
        }
        dismissSystemPrompts()
        XCTAssertTrue(app.staticTexts["Connected"].waitForExistence(timeout: 30))
        let mute = app.buttons["Mute"]
        XCTAssertTrue(mute.waitForExistence(timeout: 20))
        mute.tap()
        let unmute = app.buttons["Unmute"]
        XCTAssertTrue(unmute.waitForExistence(timeout: 10))
        unmute.tap()
        XCTAssertTrue(mute.waitForExistence(timeout: 10))
        let image = XCTAttachment(screenshot: app.screenshot())
        image.name = "Relay call connected"
        image.lifetime = .keepAlways
        add(image)
    }

    @MainActor
    func testGroupScreenPresentation() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "org.relaychat.Relay")
        app.activate()
        XCTAssertTrue(app.staticTexts["Connected"].waitForExistence(timeout: 15))
        let names = app.staticTexts.matching(identifier: "Relay Tester")
        let presentation = NSPredicate { _, _ in names.count == 4 }
        expectation(for: presentation, evaluatedWith: app)
        waitForExpectations(timeout: 20)
        let image = XCTAttachment(screenshot: app.screenshot())
        image.name = "Three devices receiving the shared window"
        image.lifetime = .keepAlways
        add(image)
    }

    @MainActor
    func testCallEnded() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "org.relaychat.Relay")
        app.activate()
        XCTAssertTrue(app.staticTexts["Call disconnected"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.buttons["Join call"].exists)
        XCTAssertFalse(app.buttons["Mute"].exists)
    }

    @MainActor
    func testLeave() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "org.relaychat.Relay")
        app.activate()
        XCTAssertTrue(app.buttons["Leave"].waitForExistence(timeout: 10))
        app.buttons["Leave"].tap()
        XCTAssertTrue(app.buttons["Leave"].waitForNonExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["Connected"].exists)
    }
}
