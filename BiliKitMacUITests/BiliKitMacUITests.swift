import XCTest

final class BiliKitMacUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testPlaybackRoundTripInOneWindow() {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing"]
        app.launch()
        if !app.windows.firstMatch.waitForExistence(timeout: 2) {
            app.activate()
            app.typeKey("n", modifierFlags: .command)
        }
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 2))

        let feed = element("feed.grid", in: app)
        XCTAssertTrue(feed.waitForExistence(timeout: 5))
        let navigationSidebar = element("sidebar.navigation", in: app)
        XCTAssertTrue(navigationSidebar.waitForExistence(timeout: 5))

        let searchSource = element("sidebar.search", in: app)
        XCTAssertTrue(searchSource.waitForExistence(timeout: 5))
        searchSource.click()
        XCTAssertTrue(
            element("search.prompt", in: app)
                .waitForExistence(timeout: 5)
        )

        let historySource = element("sidebar.history", in: app)
        XCTAssertTrue(historySource.waitForExistence(timeout: 5))
        historySource.click()
        XCTAssertTrue(
            element("history.signed-out", in: app)
                .waitForExistence(timeout: 5)
        )

        let popularSource = element("sidebar.popular", in: app)
        XCTAssertTrue(popularSource.waitForExistence(timeout: 5))
        popularSource.click()
        XCTAssertTrue(feed.waitForExistence(timeout: 5))

        let video = element("feed.item.fixture-video-1", in: app)
        XCTAssertTrue(video.waitForExistence(timeout: 5))
        video.click()

        let playback = element("playback.destination", in: app)
        XCTAssertTrue(playback.waitForExistence(timeout: 5))
        XCTAssertTrue(
            element("sidebar.playback-context", in: app)
                .waitForExistence(timeout: 5)
        )
        XCTAssertTrue(navigationSidebar.waitForNonExistence(timeout: 5))
        XCTAssertTrue(
            element("playback.status.playing", in: app)
                .waitForExistence(timeout: 5)
        )

        let backButton = app.buttons["chevron.backward"]
        XCTAssertTrue(backButton.waitForExistence(timeout: 5))
        backButton.click()

        XCTAssertTrue(feed.waitForExistence(timeout: 5))
        XCTAssertTrue(navigationSidebar.waitForExistence(timeout: 5))
        XCTAssertTrue(
            element("sidebar.playback-context", in: app)
                .waitForNonExistence(timeout: 5)
        )
        XCTAssertTrue(
            element("playback.status.stopped", in: app)
                .waitForExistence(timeout: 5)
        )
        XCTAssertTrue(playback.waitForNonExistence(timeout: 5))
    }

    @MainActor
    private func element(
        _ identifier: String,
        in app: XCUIApplication
    ) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }
}
