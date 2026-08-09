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
        XCTAssertTrue(tikTok.waitForExistence(timeout: 5), "TikTok is advertised as a source but is not on the Catch screen")
        // A source that exists but cannot be reached is not offered. The picker used to hide ten
        // of its fourteen entries off the right edge, which is what this catches.
        for _ in 0 ..< 5 where !tikTok.isHittable { app.swipeUp() }
        XCTAssertTrue(tikTok.isHittable, "TikTok is on the Catch screen but cannot be reached")
        tikTok.tap()
        capture(app, named: "source-picker-tiktok.png")
        app.buttons["Cancel"].tap()

        app.terminate()
        app = launch(arguments: ["-onboarding.complete", "YES", "--ui-testing", "--ui-results-fixture"])
        // The review opens itself once the fixture resolves, so the first media card is what to
        // wait for rather than a button that has to be tapped to reach it.
        let firstCard = app.buttons["results.media.0"]
        XCTAssertTrue(firstCard.waitForExistence(timeout: 10))
        capture(app, named: "results-mixed-media.png")
        app.buttons["results.textCard"].tap()
        capture(app, named: "text-card-composer.png")
        app.buttons["Done"].tap()

        openTab("Queue", in: app)
        capture(app, named: "queue.png")
        openTab("Library", in: app)
        // The fixture writes real media during launch. Photographing the library before that
        // finishes captures an empty archive and calls it the empty state.
        awaitLibraryContent(in: app)
        capture(app, named: "library-posts.png")
        let createCollection = app.buttons["New collection"]
        XCTAssertTrue(createCollection.waitForExistence(timeout: 5))
        createCollection.tap()
        let collectionName = app.textFields["Collection name"]
        XCTAssertTrue(collectionName.waitForExistence(timeout: 15), "The new-collection alert never appeared")
        collectionName.tap()
        collectionName.typeText("Weekend ideas")
        app.alerts["New collection"].buttons["New collection"].tap()
        capture(app, named: "library-collection.png")
        let mediaSegment = app.buttons["Media"]
        XCTAssertTrue(mediaSegment.waitForExistence(timeout: 5))
        mediaSegment.tap()
        capture(app, named: "library-media.png")
        let firstLibraryRow = app.buttons["library.mediaItem"].firstMatch
        XCTAssertTrue(firstLibraryRow.waitForExistence(timeout: 8))
        firstLibraryRow.tap()
        capture(app, named: "living-post.png")
        // A saved post gives the whole screen to the platform, so there is no Stashy navigation
        // bar to dismiss from. The way out is the archive strip Stashy keeps along the bottom.
        let done = app.descendants(matching: .any).matching(identifier: "livingPost.done").firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 5), "A saved post has no way back to the library")
        done.tap()

        openTab("Settings", in: app)
        capture(app, named: "settings.png")
        let platformStatus = app.buttons["settings.platformDiagnostics"]
        // Bounded: an element that never appears has to fail the test, not hang the run until
        // the whole job times out with no evidence at all.
        for _ in 0 ..< 8 where !platformStatus.exists { app.swipeUp() }
        XCTAssertTrue(platformStatus.waitForExistence(timeout: 5), "Platform support status is unreachable in Settings")
        platformStatus.tap()
        capture(app, named: "discord-disabled.png")
        app.buttons["Done"].tap()

        app.terminate()
        app = launch(arguments: ["-onboarding.complete", "YES", "--ui-testing", "--ui-arabic", "-AppleLanguages", "(ar)", "-AppleLocale", "ar_SA"])
        capture(app, named: "ar-catch.png")
        openTab("المكتبة", in: app)
        awaitLibraryContent(in: app)
        capture(app, named: "ar-library.png")

        app.terminate()
        app = launch(arguments: ["-onboarding.complete", "YES", "--ui-testing", "--ui-dark"])
        capture(app, named: "dark-catch.png")
        openTab("Library", in: app)
        awaitLibraryContent(in: app)
        capture(app, named: "dark-library.png")
    }

    /// Blocks until the saved-post row exists. Every language and appearance run builds its own
    /// fixture at launch, so each of them has to wait for its own.
    private func awaitLibraryContent(in app: XCUIApplication) {
        let row = app.buttons.matching(identifier: "library.postRow").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 20), "The screenshot fixture never reached the library")
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
