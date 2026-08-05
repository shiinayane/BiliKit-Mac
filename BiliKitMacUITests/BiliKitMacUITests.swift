import Foundation
import XCTest

final class BiliKitMacUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testPlaybackRoundTripInOneWindow() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-ui-testing",
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
        ]
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
        let popularSource = element("sidebar.popular", in: app)
        let historySource = element("sidebar.history", in: app)
        XCTAssertTrue(waitForHittable(searchSource, timeout: 5))
        XCTAssertTrue(waitForHittable(popularSource, timeout: 5))
        XCTAssertTrue(waitForHittable(historySource, timeout: 5))
        popularSource.click()
        XCTAssertTrue(
            waitForKeyboardFocus(
                in: app,
                within: [navigationSidebar],
                timeout: 5
            )
        )
        toggleSystemSidebar(in: app)
        XCTAssertTrue(waitForNotHittable(searchSource, timeout: 5))
        XCTAssertTrue(waitForNotHittable(popularSource, timeout: 5))
        XCTAssertTrue(waitForNotHittable(historySource, timeout: 5))
        XCTAssertTrue(
            waitForNoKeyboardFocus(
                in: navigationSidebar,
                app: app,
                timeout: 5
            )
        )
        toggleSystemSidebar(in: app)
        XCTAssertTrue(waitForHittable(searchSource, timeout: 5))
        XCTAssertTrue(waitForHittable(popularSource, timeout: 5))
        XCTAssertTrue(waitForHittable(historySource, timeout: 5))

        XCTAssertTrue(searchSource.waitForExistence(timeout: 5))
        searchSource.click()
        XCTAssertTrue(
            element("search.prompt", in: app)
                .waitForExistence(timeout: 5)
        )
        let searchField = app.searchFields.firstMatch
        XCTAssertTrue(searchField.waitForExistence(timeout: 5))
        XCTAssertEqual(app.searchFields.count, 1)

        XCTAssertTrue(historySource.waitForExistence(timeout: 5))
        historySource.click()
        XCTAssertTrue(
            element("history.signed-out", in: app)
                .waitForExistence(timeout: 5)
        )

        XCTAssertTrue(popularSource.waitForExistence(timeout: 5))
        popularSource.click()
        XCTAssertTrue(feed.waitForExistence(timeout: 5))

        let video = element("feed.item.fixture-video-1", in: app)
        XCTAssertTrue(video.waitForExistence(timeout: 5))
        video.click()

        let playback = element("playback.destination", in: app)
        XCTAssertTrue(playback.waitForExistence(timeout: 5))
        let playbackSidebar = element("sidebar.playback-context", in: app)
        XCTAssertTrue(playbackSidebar.waitForExistence(timeout: 5))
        let playbackSidebarTitle = app.staticTexts["评论尚未接入"]
        XCTAssertTrue(waitForHittable(playbackSidebarTitle, timeout: 5))
        XCTAssertTrue(navigationSidebar.waitForNonExistence(timeout: 5))
        XCTAssertTrue(
            element("playback.status.playing", in: app)
                .waitForExistence(timeout: 5)
        )
        toggleSystemSidebar(in: app)
        XCTAssertTrue(waitForNotHittable(playbackSidebarTitle, timeout: 5))
        XCTAssertTrue(
            waitForNoKeyboardFocus(
                in: playbackSidebar,
                app: app,
                timeout: 5
            )
        )
        XCTAssertTrue(
            element("playback.status.playing", in: app).exists
        )
        toggleSystemSidebar(in: app)
        XCTAssertTrue(waitForHittable(playbackSidebarTitle, timeout: 5))

        guard
            let backButton = uniqueHittableButton(
                matching: NSPredicate(format: "label == %@", "Back"),
                in: app,
                timeout: 5
            )
        else {
            XCTFail("Expected one visible system Back button")
            return
        }
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
        XCTAssertTrue(
            waitForKeyboardFocus(
                in: app,
                within: [navigationSidebar, feed],
                timeout: 5
            )
        )
    }

    @MainActor
    private func element(
        _ identifier: String,
        in app: XCUIApplication
    ) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }

    @MainActor
    private func toggleSystemSidebar(in app: XCUIApplication) {
        guard
            let toggle = uniqueHittableButton(
                matching: NSPredicate(
                    format: "label CONTAINS[c] %@",
                    "sidebar"
                ),
                in: app,
                timeout: 5
            )
        else {
            XCTFail("Expected one visible NavigationSplitView sidebar toggle")
            return
        }
        toggle.click()
    }

    @MainActor
    private func uniqueHittableButton(
        matching predicate: NSPredicate,
        in app: XCUIApplication,
        timeout: TimeInterval
    ) -> XCUIElement? {
        let query = app.buttons.matching(predicate)
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                query.allElementsBoundByIndex.filter {
                    $0.exists && $0.isHittable
                }.count == 1
            },
            object: app
        )
        guard
            XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
        else {
            return nil
        }
        return query.allElementsBoundByIndex.first {
            $0.exists && $0.isHittable
        }
    }

    @MainActor
    private func waitForHittable(
        _ element: XCUIElement,
        timeout: TimeInterval
    ) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                element.exists && element.isHittable
            },
            object: element
        )
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    @MainActor
    private func waitForNotHittable(
        _ element: XCUIElement,
        timeout: TimeInterval
    ) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                !element.exists || !element.isHittable
            },
            object: element
        )
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    @MainActor
    private func waitForNoKeyboardFocus(
        in context: XCUIElement,
        app: XCUIApplication,
        timeout: TimeInterval
    ) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                !self.hasKeyboardFocus(in: context, app: app)
            },
            object: context
        )
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    @MainActor
    private func waitForKeyboardFocus(
        in app: XCUIApplication,
        within contexts: [XCUIElement],
        timeout: TimeInterval
    ) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                contexts.contains {
                    self.hasHittableKeyboardFocus(in: $0, app: app)
                }
            },
            object: app
        )
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    @MainActor
    private func hasHittableKeyboardFocus(
        in context: XCUIElement,
        app: XCUIApplication
    ) -> Bool {
        let focusedPredicate = NSPredicate(
            format: "hasKeyboardFocus == true"
        )
        if !context.identifier.isEmpty {
            let focusedRoot = app.descendants(matching: .any)
                .matching(
                    NSPredicate(
                        format: "identifier == %@ AND hasKeyboardFocus == true",
                        context.identifier
                    )
                )
                .firstMatch
            if focusedRoot.exists && focusedRoot.isHittable {
                return true
            }
        }
        return context.descendants(matching: .any)
            .matching(focusedPredicate)
            .allElementsBoundByIndex
            .contains { $0.exists && $0.isHittable }
    }

    @MainActor
    private func hasKeyboardFocus(
        in context: XCUIElement,
        app: XCUIApplication
    ) -> Bool {
        if !context.identifier.isEmpty {
            let focusedRoot = app.descendants(matching: .any)
                .matching(
                    NSPredicate(
                        format: "identifier == %@ AND hasKeyboardFocus == true",
                        context.identifier
                    )
                )
                .firstMatch
            if focusedRoot.exists {
                return true
            }
        }
        return context.descendants(matching: .any)
            .matching(NSPredicate(format: "hasKeyboardFocus == true"))
            .firstMatch.exists
    }
}
