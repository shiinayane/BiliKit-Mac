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
    func testContextualNavigatorReturnsEachSourceAndRestoresSearchDraft() {
        let app = launchFixture(arguments: [
            "-ui-testing",
            "-ui-testing-contextual-navigator",
        ])

        let popularItem = element("feed.item.fixture-video-A", in: app)
        XCTAssertTrue(waitForHittable(popularItem, timeout: 5))
        popularItem.click()
        XCTAssertTrue(
            element("playback.destination", in: app)
                .waitForExistence(timeout: 5)
        )
        clickSystemBack(in: app)
        XCTAssertTrue(element("feed.grid", in: app).waitForExistence(timeout: 5))

        let searchSource = element("sidebar.search", in: app)
        XCTAssertTrue(waitForHittable(searchSource, timeout: 5))
        searchSource.click()
        let searchField = app.searchFields.firstMatch
        XCTAssertTrue(waitForHittable(searchField, timeout: 5))
        searchField.click()
        searchField.typeText("fixture draft")
        searchField.typeKey(.return, modifierFlags: [])
        let searchItem = element("search.item.fixture-search-A", in: app)
        XCTAssertTrue(waitForHittable(searchItem, timeout: 5))
        searchItem.click()
        XCTAssertTrue(
            element("sidebar.contextual-fixture", in: app)
                .waitForExistence(timeout: 5)
        )
        clickSystemBack(in: app)
        XCTAssertTrue(
            element("search.results", in: app).waitForExistence(timeout: 5)
        )
        XCTAssertTrue(
            (app.searchFields.firstMatch.value as? String)?
                .contains("fixture draft") == true
        )

        let historySource = element("sidebar.history", in: app)
        XCTAssertTrue(waitForHittable(historySource, timeout: 5))
        historySource.click()
        let historyItem = element("history.item.fixture-history-A", in: app)
        XCTAssertTrue(waitForHittable(historyItem, timeout: 5))
        historyItem.click()
        XCTAssertTrue(
            element("sidebar.contextual-fixture", in: app)
                .waitForExistence(timeout: 5)
        )
        clickSystemBack(in: app)
        XCTAssertTrue(
            element("history.list", in: app).waitForExistence(timeout: 5)
        )
    }

    @MainActor
    func testContextualReplacementUsesRealLocalPlayerAndCleansOnBack() throws {
        let app = launchFixture(arguments: [
            "-ui-testing",
            "-ui-testing-contextual-navigator",
        ])
        let popularItem = element("feed.item.fixture-video-A", in: app)
        XCTAssertTrue(waitForHittable(popularItem, timeout: 5))
        popularItem.click()

        let timeline = element("local-avplayer.timeline", in: app)
        let first = try waitForTimeline(
            timeline,
            item: "fixture-video-A",
            minimumMilliseconds: 100
        )
        let playerIdentity = try XCTUnwrap(first["playerIdentity"])
        let firstItemIdentity = try XCTUnwrap(first["itemIdentity"])
        let firstGeneration = try XCTUnwrap(Int(first["generation"] ?? ""))

        let partTwo = element("fixture.part.2", in: app)
        XCTAssertTrue(waitForHittable(partTwo, timeout: 5))
        partTwo.click()
        XCTAssertTrue(
            waitForLabel(
                element("fixture.selected-part", in: app),
                equalTo: "Selected P2",
                timeout: 5
            )
        )
        let afterPart = try waitForTimeline(
            timeline,
            item: "fixture-video-A",
            minimumMilliseconds: try timelineMilliseconds(first) + 100
        )
        XCTAssertEqual(afterPart["generation"], first["generation"])
        XCTAssertEqual(afterPart["itemIdentity"], firstItemIdentity)

        toggleSystemSidebar(in: app)
        XCTAssertTrue(
            waitForNotHittable(
                element("sidebar.contextual-fixture", in: app),
                timeout: 5
            )
        )
        let afterHide = try waitForTimeline(
            timeline,
            item: "fixture-video-A",
            minimumMilliseconds: try timelineMilliseconds(afterPart) + 100
        )
        XCTAssertEqual(afterHide["playerIdentity"], playerIdentity)
        XCTAssertEqual(afterHide["itemIdentity"], firstItemIdentity)
        XCTAssertEqual(afterHide["generation"], first["generation"])
        toggleSystemSidebar(in: app)
        XCTAssertTrue(
            waitForHittable(
                element("sidebar.contextual-fixture", in: app),
                timeout: 5
            )
        )

        let sidebar = element("sidebar.contextual-fixture", in: app)
        let recommendationB = element(
            "fixture.recommendation.fixture-video-B",
            in: app
        )
        XCTAssertTrue(
            scrollUntilHittable(recommendationB, in: sidebar, maximumScrolls: 8)
        )
        recommendationB.click()
        let replacement = try waitForTimeline(
            timeline,
            item: "fixture-video-B",
            minimumMilliseconds: 100
        )
        XCTAssertEqual(replacement["playerIdentity"], playerIdentity)
        XCTAssertGreaterThan(
            try XCTUnwrap(Int(replacement["generation"] ?? "")),
            firstGeneration
        )
        XCTAssertEqual(replacement["lastStopped"], "fixture-video-A")
        XCTAssertEqual(replacement["observerCount"], "1")

        let recommendationC = element(
            "fixture.recommendation.fixture-video-C",
            in: app
        )
        XCTAssertTrue(
            scrollUntilHittable(recommendationC, in: sidebar, maximumScrolls: 8)
        )
        recommendationC.click()
        let final = try waitForTimeline(
            timeline,
            item: "fixture-video-C",
            minimumMilliseconds: 100
        )
        XCTAssertEqual(final["playerIdentity"], playerIdentity)
        XCTAssertGreaterThan(
            try XCTUnwrap(Int(final["generation"] ?? "")),
            try XCTUnwrap(Int(replacement["generation"] ?? ""))
        )
        XCTAssertTrue(
            scrollUntilHittable(
                element("fixture.recommendation.end", in: app),
                in: sidebar,
                maximumScrolls: 8
            )
        )

        clickSystemBack(in: app)
        XCTAssertTrue(
            waitForProbe(timeline, timeout: 5) { fields in
                fields["item"] == "none"
                    && fields["status"] == "stopped"
                    && fields["observerCount"] == "0"
                    && fields["installed"] == "0"
            }
        )
        XCTAssertTrue(element("feed.grid", in: app).exists)
        XCTAssertFalse(element("playback.destination", in: app).exists)

        XCTAssertTrue(waitForHittable(popularItem, timeout: 5))
        popularItem.click()
        _ = try waitForTimeline(
            timeline,
            item: "fixture-video-A",
            minimumMilliseconds: 100
        )
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(waitForWindowCount(0, in: app, timeout: 5))
        app.typeKey("n", modifierFlags: .command)
        XCTAssertTrue(waitForWindowCount(1, in: app, timeout: 5))
        let reopenedTimeline = element("local-avplayer.timeline", in: app)
        XCTAssertTrue(
            waitForProbe(reopenedTimeline, timeout: 5) { fields in
                fields["item"] == "none"
                    && fields["observerCount"] == "0"
                    && fields["installed"] == "0"
                    && fields["activeItems"] == "0"
                    && fields["activeObservers"] == "0"
                    && fields["activeMediaDirectories"] == "0"
            }
        )
    }

    @MainActor
    func testContextualSidebarScrollIdentityAcrossPartBVIDAndWindowSizes()
        throws
    {
        let app = launchFixture(arguments: [
            "-ui-testing",
            "-ui-testing-contextual-navigator",
            "-ui-testing-large-text",
        ])
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        XCTAssertEqual(window.frame.width, 1_320, accuracy: 4)

        let popularItem = element("feed.item.fixture-video-A", in: app)
        XCTAssertTrue(waitForHittable(popularItem, timeout: 5))
        popularItem.click()
        let sidebar = element("sidebar.contextual-fixture", in: app)
        let mixedComment = element("fixture.comment.mixed", in: app)
        let nestedReply = element("fixture.comment.nested-reply", in: app)
        XCTAssertTrue(sidebar.waitForExistence(timeout: 5))
        XCTAssertTrue(mixedComment.waitForExistence(timeout: 5))
        XCTAssertTrue(nestedReply.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(nestedReply.frame.minX, mixedComment.frame.minX)

        sidebar.scroll(byDeltaX: 0, deltaY: -600)
        let lastComment = element("fixture.comment.last", in: app)
        XCTAssertTrue(waitForHittable(lastComment, timeout: 5))
        let partTwo = element("fixture.part.2", in: app)
        XCTAssertTrue(waitForHittable(partTwo, timeout: 5))
        partTwo.click()
        XCTAssertTrue(waitForHittable(lastComment, timeout: 5))

        let recommendationB = element(
            "fixture.recommendation.fixture-video-B",
            in: app
        )
        XCTAssertTrue(waitForHittable(recommendationB, timeout: 5))
        recommendationB.click()
        XCTAssertTrue(
            waitForLabel(
                element("fixture.playback-identity", in: app),
                equalTo: "fixture-video-B",
                timeout: 5
            )
        )
        XCTAssertTrue(
            waitForHittable(
                element("fixture.comment.primary", in: app),
                timeout: 5
            )
        )

        let timeline = element("local-avplayer.timeline", in: app)
        var stableTimeline = try waitForTimeline(
            timeline,
            item: "fixture-video-B",
            minimumMilliseconds: 100
        )
        let stablePlayerIdentity = stableTimeline["playerIdentity"]
        let stableItemIdentity = stableTimeline["itemIdentity"]
        let stableGeneration = stableTimeline["generation"]

        for size in [
            CGSize(width: 1_080, height: 680),
            CGSize(width: 860, height: 620),
        ] {
            resizeWindow(window, to: size)
            XCTAssertTrue(
                waitForWindowWidth(
                    window,
                    width: size.width,
                    accuracy: 6,
                    timeout: 5
                )
            )
            XCTAssertTrue(element("player.host", in: app).exists)
            XCTAssertTrue(sidebar.exists)
            let advancedTimeline = try waitForTimeline(
                timeline,
                item: "fixture-video-B",
                minimumMilliseconds:
                    try timelineMilliseconds(stableTimeline) + 100
            )
            XCTAssertEqual(
                advancedTimeline["playerIdentity"],
                stablePlayerIdentity
            )
            XCTAssertEqual(advancedTimeline["itemIdentity"], stableItemIdentity)
            XCTAssertEqual(advancedTimeline["generation"], stableGeneration)
            stableTimeline = advancedTimeline
        }

        clickSystemBack(in: app)
        XCTAssertTrue(
            waitForProbe(timeline, timeout: 5) { fields in
                fields["item"] == "none"
                    && fields["observerCount"] == "0"
                    && fields["installed"] == "0"
            }
        )
    }

    @MainActor
    private func launchFixture(arguments: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments =
            arguments + [
                "-AppleLanguages", "(en)",
                "-AppleLocale", "en_US",
            ]
        app.launch()
        if !app.windows.firstMatch.waitForExistence(timeout: 2) {
            app.activate()
            app.typeKey("n", modifierFlags: .command)
        }
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 2))
        XCTAssertTrue(
            element("feed.grid", in: app).waitForExistence(timeout: 5)
        )
        XCTAssertTrue(
            element("sidebar.navigation", in: app)
                .waitForExistence(timeout: 5)
        )
        return app
    }

    @MainActor
    private func clickSystemBack(in app: XCUIApplication) {
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
    }

    @MainActor
    private func waitForTimeline(
        _ element: XCUIElement,
        item: String,
        minimumMilliseconds: Int
    ) throws -> [String: String] {
        XCTAssertTrue(element.waitForExistence(timeout: 5))
        XCTAssertTrue(
            waitForProbe(element, timeout: 10) { fields in
                fields["item"] == item
                    && fields["status"] == "playing"
                    && (Int(fields["timeMillis"] ?? "") ?? 0)
                        >= minimumMilliseconds
            }
        )
        return probeFields(from: element)
    }

    @MainActor
    private func waitForProbe(
        _ element: XCUIElement,
        timeout: TimeInterval,
        matching predicate: @escaping ([String: String]) -> Bool
    ) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                predicate(self.probeFields(from: element))
            },
            object: element
        )
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    @MainActor
    private func probeFields(from element: XCUIElement) -> [String: String] {
        let accessibilityValue = element.value as? String
        let value =
            if let accessibilityValue, !accessibilityValue.isEmpty {
                accessibilityValue
            } else {
                element.label
            }
        return Dictionary(
            uniqueKeysWithValues: value.split(separator: ";").compactMap {
                field in
                let pair = field.split(separator: "=", maxSplits: 1)
                guard pair.count == 2 else { return nil }
                return (String(pair[0]), String(pair[1]))
            }
        )
    }

    private func timelineMilliseconds(
        _ fields: [String: String]
    ) throws -> Int {
        try XCTUnwrap(Int(fields["timeMillis"] ?? ""))
    }

    @MainActor
    private func resizeWindow(_ window: XCUIElement, to size: CGSize) {
        let frame = window.frame
        let handle = window.coordinate(
            withNormalizedOffset: CGVector(dx: 0.998, dy: 0.998)
        )
        handle.press(
            forDuration: 0.1,
            thenDragTo: handle.withOffset(
                CGVector(
                    dx: size.width - frame.width,
                    dy: size.height - frame.height
                )
            )
        )
    }

    @MainActor
    private func waitForWindowWidth(
        _ window: XCUIElement,
        width: CGFloat,
        accuracy: CGFloat,
        timeout: TimeInterval
    ) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                abs(window.frame.width - width) <= accuracy
            },
            object: window
        )
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    @MainActor
    private func waitForWindowCount(
        _ count: Int,
        in app: XCUIApplication,
        timeout: TimeInterval
    ) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                app.windows.count == count
            },
            object: app
        )
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
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
    private func waitForLabel(
        _ element: XCUIElement,
        equalTo label: String,
        timeout: TimeInterval
    ) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", label),
            object: element
        )
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    @MainActor
    private func scrollUntilHittable(
        _ element: XCUIElement,
        in container: XCUIElement,
        maximumScrolls: Int
    ) -> Bool {
        for _ in 0...maximumScrolls {
            if element.exists && element.isHittable {
                return true
            }
            container.scroll(byDeltaX: 0, deltaY: -360)
        }
        return element.exists && element.isHittable
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
