import XCTest

@MainActor
final class ScreenshotFlows: XCTestCase {
    private var screenshotsDirectory: URL {
        if let path = ProcessInfo.processInfo.environment["SCREENSHOTS_DIR"], !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).appendingPathComponent("StashyScreenshots", isDirectory: true)
    }

    func testCaptureEveryScreen() throws {
        try FileManager.default.createDirectory(at: screenshotsDirectory, withIntermediateDirectories: true)

        var app = launch(["--reset-onboarding"])
        XCTAssertTrue(app.buttons["onboarding.start"].waitForExistence(timeout: 10))
        capture(app, "onboarding.png")
        app.buttons["onboarding.start"].tap()
        XCTAssertTrue(app.buttons["catch.paste"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.otherElements["catch.source.tikTok"].exists || app.staticTexts["TikTok"].exists)
        capture(app, "catch-empty.png")
        app.terminate()

        app = launch(["--ui-fixture"])
        // Capture whatever the fixture launch renders, before asserting, so a failure is visible.
        _ = app.buttons["catch.saveButton"].waitForExistence(timeout: 30)
        capture(app, "diag-fixture-launch.png")
        XCTAssertTrue(app.buttons["catch.saveButton"].exists, "The fixture post never appeared on the Catch screen")
        capture(app, "catch-preview.png")
        app.swipeUp()
        capture(app, "catch-preview-options.png")

        openTab(app, "tab.queue")
        XCTAssertTrue(app.staticTexts["Downloading"].waitForExistence(timeout: 5))
        capture(app, "queue.png")

        openTab(app, "tab.library")
        let firstArchive = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'library.archive.'")).firstMatch
        XCTAssertTrue(firstArchive.waitForExistence(timeout: 10), "No archive tile in the library")
        capture(app, "library.png")
        firstArchive.tap()
        XCTAssertTrue(app.buttons["detail.menu"].waitForExistence(timeout: 10))
        capture(app, "archive-detail.png")
        app.navigationBars.buttons.firstMatch.tap()

        openTab(app, "tab.settings")
        XCTAssertTrue(app.buttons["settings.credential.discordBotToken"].waitForExistence(timeout: 5))
        capture(app, "settings.png")
        app.buttons["What each source gives"].tap()
        XCTAssertTrue(app.otherElements["sources.youTube"].waitForExistence(timeout: 5) || app.staticTexts["YouTube"].waitForExistence(timeout: 5))
        capture(app, "sources.png")
        app.terminate()

        app = launch(["--ui-fixture", "--arabic"])
        XCTAssertTrue(app.buttons["catch.saveButton"].waitForExistence(timeout: 30))
        capture(app, "ar-catch-preview.png")
        openTab(app, "tab.library")
        XCTAssertTrue(firstArchiveTile(app).waitForExistence(timeout: 10))
        capture(app, "ar-library.png")
        openTab(app, "tab.settings")
        capture(app, "ar-settings.png")
        app.terminate()
    }

    private func firstArchiveTile(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'library.archive.'")).firstMatch
    }

    private func launch(_ arguments: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = arguments
        app.launch()
        return app
    }

    /// Tabs are found by their identifier-independent labels in both languages.
    private func openTab(_ app: XCUIApplication, _ key: String) {
        let labels: [String: [String]] = [
            "tab.catch": ["Catch", "التقط"],
            "tab.library": ["Library", "المكتبة"],
            "tab.queue": ["Queue", "التنزيلات"],
            "tab.settings": ["Settings", "الإعدادات"]
        ]
        for label in labels[key] ?? [] {
            let button = app.tabBars.buttons[label]
            if button.waitForExistence(timeout: 2) {
                button.tap()
                return
            }
        }
        XCTFail("Tab \(key) not found")
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let screenshot = app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        try? screenshot.pngRepresentation.write(to: screenshotsDirectory.appendingPathComponent(name))
    }
}
