import XCTest

@MainActor
final class ScreenshotFlows: XCTestCase {
    private var screenshotsDirectory: URL {
        if let envDir = ProcessInfo.processInfo.environment["SCREENSHOTS_DIR"], !envDir.isEmpty {
            return URL(fileURLWithPath: envDir, isDirectory: true)
        }
        return URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("StashyScreenshots", isDirectory: true)
    }

    func testCaptureReleaseScreens() throws {
        try FileManager.default.createDirectory(at: screenshotsDirectory, withIntermediateDirectories: true)

        var app = launch(arguments: ["-onboarding.complete", "NO", "--ui-testing"])
        capture(app, named: "onboarding.png")
        app.buttons["onboarding.skip"].tap()
        capture(app, named: "catch-empty.png")
        let tikTok = app.buttons["catch.source.tikTok"]
        XCTAssertTrue(tikTok.waitForExistence(timeout: 5))
        tikTok.tap()
        capture(app, named: "source-picker-tiktok.png")
        app.buttons["Cancel"].tap()

        app.terminate()
        app = launch(arguments: ["-onboarding.complete", "YES", "--ui-testing", "--ui-results-fixture"])
        let result = app.buttons["catch.results"]
        XCTAssertTrue(result.waitForExistence(timeout: 8))
        result.tap()
        capture(app, named: "results-mixed-media.png")
        app.buttons["results.textCard"].tap()
        capture(app, named: "text-card-composer.png")
        app.buttons["Done"].tap()

        openTab("Queue", in: app)
        capture(app, named: "queue.png")
        openTab("Library", in: app)
        capture(app, named: "library-posts.png")
        let createCollection = app.buttons["New collection"]
        XCTAssertTrue(createCollection.waitForExistence(timeout: 5))
        createCollection.tap()
        let collectionName = app.textFields["Collection name"]
        XCTAssertTrue(collectionName.waitForExistence(timeout: 5))
        collectionName.tap()
        collectionName.typeText("Weekend ideas")
        app.buttons["New collection"].tap()
        capture(app, named: "library-collection.png")
        let mediaSegment = app.buttons["Media"]
        XCTAssertTrue(mediaSegment.waitForExistence(timeout: 5))
        mediaSegment.tap()
        capture(app, named: "library-media.png")
        let firstLibraryRow = app.cells.firstMatch
        XCTAssertTrue(firstLibraryRow.waitForExistence(timeout: 8))
        firstLibraryRow.tap()
        capture(app, named: "living-post.png")
        app.navigationBars.buttons.firstMatch.tap()

        openTab("Settings", in: app)
        capture(app, named: "settings.png")
        app.buttons["Platform support status"].tap()
        capture(app, named: "discord-disabled.png")
        app.buttons["Done"].tap()

        app.terminate()
        app = launch(arguments: ["-onboarding.complete", "YES", "--ui-testing", "-AppleLanguages", "(ar)", "-AppleLocale", "ar_SA"])
        capture(app, named: "ar-catch.png")
        openTab("المكتبة", in: app)
        capture(app, named: "ar-library.png")

        app.terminate()
        app = launch(arguments: ["-onboarding.complete", "YES", "--ui-testing", "--ui-dark"])
        capture(app, named: "dark-catch.png")
        openTab("Library", in: app)
        capture(app, named: "dark-library.png")
    }

    private func launch(arguments: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = arguments
        app.launch()
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 10) || app.buttons["onboarding.skip"].exists)
        return app
    }

    private func openTab(_ title: String, in app: XCUIApplication) {
        let tab = app.tabBars.buttons[title]
        XCTAssertTrue(tab.waitForExistence(timeout: 5), "Missing \(title) tab")
        tab.tap()
    }

    private func capture(_ app: XCUIApplication, named name: String) {
        let destination = screenshotsDirectory.appendingPathComponent(name)
        let screenshot = app.screenshot()
        let data = screenshot.pngRepresentation
        XCTAssertNoThrow(try data.write(to: destination, options: .atomic), "Could not write \(name)")
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
