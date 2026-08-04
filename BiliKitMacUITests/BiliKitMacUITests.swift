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

        let video = element("feed.item.fixture-video-1", in: app)
        XCTAssertTrue(video.waitForExistence(timeout: 5))
        video.click()

        let playback = element("playback.destination", in: app)
        XCTAssertTrue(playback.waitForExistence(timeout: 5))
        XCTAssertTrue(
            element("playback.status.playing", in: app)
                .waitForExistence(timeout: 5)
        )

        let backButton = app.buttons["chevron.backward"]
        XCTAssertTrue(backButton.waitForExistence(timeout: 5))
        backButton.click()

        XCTAssertTrue(feed.waitForExistence(timeout: 5))
        XCTAssertTrue(
            element("playback.status.stopped", in: app)
                .waitForExistence(timeout: 5)
        )
        XCTAssertFalse(playback.waitForExistence(timeout: 1))
    }

    @MainActor
    private func element(
        _ identifier: String,
        in app: XCUIApplication
    ) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }
}
