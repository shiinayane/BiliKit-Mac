import Foundation
import XCTest

final class BiliKitMacUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testConfirmedAccountIdentityAppearsInStableSidebarAccountSlot() {
        let app = launchFixture(
            arguments: [
                "-ui-testing",
                "-ui-testing-account-identity",
            ]
        )
        let account = element("sidebar.account", in: app)

        XCTAssertTrue(waitForHittable(account, timeout: 5))
        XCTAssertEqual(account.label, "Fixture Account")
        XCTAssertFalse(app.buttons["登录"].exists)
    }

    @MainActor
    func testPlaybackRoundTripInOneWindow() throws {
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
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 2))
        let expandedSize = CGSize(width: 1_320, height: 820)
        resizeWindow(window, to: expandedSize)
        XCTAssertTrue(
            waitForWindowSize(
                window,
                size: expandedSize,
                accuracy: 6,
                timeout: 5
            )
        )

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
        let timeline = element("local-avplayer.timeline", in: app)
        let initialTimeline = try waitForTimeline(
            timeline,
            item: "fixture-video-1",
            minimumMilliseconds: 100
        )
        let playbackSidebar = element("sidebar.playback-context", in: app)
        XCTAssertTrue(playbackSidebar.waitForExistence(timeout: 5))
        let summary = element("sidebar.playback-summary", in: app)
        XCTAssertTrue(summary.waitForExistence(timeout: 5))
        let summaryToggle = app.disclosureTriangles["简介"]
        XCTAssertTrue(waitForHittable(summaryToggle, timeout: 5))
        summaryToggle.click()
        XCTAssertTrue(
            element("sidebar.playback-summary.text", in: app)
                .waitForNonExistence(timeout: 5)
        )
        let parts = element("sidebar.playback-parts", in: app)
        XCTAssertTrue(parts.waitForExistence(timeout: 5))
        let selectedPart = element("sidebar.playback-part.1", in: app)
        let unselectedPart = element("sidebar.playback-part.3", in: app)
        XCTAssertTrue(selectedPart.waitForExistence(timeout: 5))
        XCTAssertTrue(unselectedPart.waitForExistence(timeout: 5))
        XCTAssertTrue(selectedPart.isSelected)
        XCTAssertFalse(unselectedPart.isSelected)
        XCTAssertTrue(app.buttons["sidebar.playback-part.1"].exists)
        XCTAssertTrue(app.buttons["sidebar.playback-part.3"].exists)
        let commentsUnavailable = element(
            "sidebar.playback-comments-unavailable",
            in: app
        )
        XCTAssertTrue(commentsUnavailable.waitForExistence(timeout: 5))
        XCTAssertFalse(element("playback.parts.rail", in: app).exists)
        XCTAssertFalse(element("playback.part.1", in: app).exists)
        XCTAssertTrue(navigationSidebar.waitForNonExistence(timeout: 5))
        XCTAssertTrue(
            element("playback.status.playing", in: app)
                .waitForExistence(timeout: 5)
        )
        toggleSystemSidebar(in: app)
        XCTAssertTrue(
            waitForNotHittable(
                app.disclosureTriangles["分 P（7）"],
                timeout: 5
            )
        )
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
        XCTAssertTrue(
            waitForHittable(
                app.disclosureTriangles["分 P（7）"],
                timeout: 5
            )
        )
        XCTAssertTrue(waitForHittable(unselectedPart, timeout: 5))
        unselectedPart.click()
        let switchedTimeline = try waitForTimeline(
            timeline,
            item: "fixture-video-1",
            minimumMilliseconds: 100,
            minimumGeneration:
                try XCTUnwrap(Int(initialTimeline["generation"] ?? "")) + 1
        )
        XCTAssertEqual(
            switchedTimeline["playerIdentity"],
            initialTimeline["playerIdentity"]
        )
        XCTAssertNotEqual(
            switchedTimeline["itemIdentity"],
            initialTimeline["itemIdentity"]
        )
        XCTAssertEqual(switchedTimeline["lastStopped"], "fixture-video-1")
        XCTAssertTrue(
            element("sidebar.playback-part.3", in: app).isSelected
        )
        XCTAssertFalse(
            element("sidebar.playback-part.1", in: app).isSelected
        )
        let compactSize = CGSize(width: 1_080, height: 680)
        resizeWindow(window, to: compactSize)
        XCTAssertTrue(
            waitForWindowSize(
                window,
                size: compactSize,
                accuracy: 6,
                timeout: 5
            )
        )
        let resizedTimeline = try waitForTimeline(
            timeline,
            item: "fixture-video-1",
            minimumMilliseconds:
                try timelineMilliseconds(switchedTimeline) + 100
        )
        XCTAssertEqual(
            resizedTimeline["playerIdentity"],
            initialTimeline["playerIdentity"]
        )
        XCTAssertEqual(
            resizedTimeline["itemIdentity"],
            switchedTimeline["itemIdentity"]
        )
        XCTAssertEqual(
            resizedTimeline["generation"],
            switchedTimeline["generation"]
        )

        clickSystemBack(in: app)

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
    func testProductionPartSelectionReplacesLocalPlayerItemAndCleansOnBack()
        throws
    {
        let app = launchFixture(arguments: ["-ui-testing"])
        let video = element("feed.item.fixture-video-1", in: app)
        XCTAssertTrue(waitForHittable(video, timeout: 5))
        video.click()

        let timeline = element("local-avplayer.timeline", in: app)
        let first = try waitForTimeline(
            timeline,
            item: "fixture-video-1",
            minimumMilliseconds: 100
        )
        let firstGeneration = try XCTUnwrap(Int(first["generation"] ?? ""))
        let playerIdentity = try XCTUnwrap(first["playerIdentity"])
        let firstItemIdentity = try XCTUnwrap(first["itemIdentity"])

        let firstPart = element("sidebar.playback-part.1", in: app)
        let partsList = element("sidebar.playback-parts.list", in: app)
        let seventhPart = element("sidebar.playback-part.7", in: app)
        XCTAssertTrue(firstPart.waitForExistence(timeout: 5))
        XCTAssertTrue(partsList.waitForExistence(timeout: 5))
        XCTAssertTrue(firstPart.isSelected)
        XCTAssertTrue(seventhPart.exists)
        XCTAssertFalse(seventhPart.isHittable)
        XCTAssertTrue(
            scrollUntilHittable(
                seventhPart,
                in: partsList,
                timeout: 5
            )
        )
        XCTAssertFalse(seventhPart.isSelected)
        seventhPart.click()

        let replacement = try waitForTimeline(
            timeline,
            item: "fixture-video-1",
            minimumMilliseconds: 100,
            minimumGeneration: firstGeneration + 1
        )
        XCTAssertEqual(replacement["playerIdentity"], playerIdentity)
        XCTAssertNotEqual(replacement["itemIdentity"], firstItemIdentity)
        XCTAssertEqual(replacement["lastStopped"], "fixture-video-1")
        XCTAssertTrue(
            element("sidebar.playback-part.7", in: app).isSelected
        )
        XCTAssertFalse(
            element("sidebar.playback-part.1", in: app).isSelected
        )

        let partsToggle = app.disclosureTriangles["分 P（7）"]
        XCTAssertTrue(waitForHittable(partsToggle, timeout: 5))
        partsToggle.click()
        XCTAssertTrue(waitForNotHittable(partsList, timeout: 5))
        partsToggle.click()
        XCTAssertTrue(partsList.waitForExistence(timeout: 5))
        XCTAssertTrue(
            waitForVisible(
                element("sidebar.playback-part.7", in: app),
                in: partsList,
                timeout: 5
            )
        )
        let restoredTimeline = try waitForTimeline(
            timeline,
            item: "fixture-video-1",
            minimumMilliseconds: try timelineMilliseconds(replacement) + 100
        )
        XCTAssertEqual(restoredTimeline["playerIdentity"], playerIdentity)
        XCTAssertEqual(
            restoredTimeline["itemIdentity"],
            replacement["itemIdentity"]
        )
        XCTAssertEqual(
            restoredTimeline["generation"],
            replacement["generation"]
        )

        clickSystemBack(in: app)
        XCTAssertTrue(
            waitForProbe(timeline, timeout: 5) { fields in
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
    func testUploaderSignatureButtonExpandsWithinSidebarAndCollapses() {
        let app = launchFixture(arguments: ["-ui-testing"])
        let video = element("feed.item.fixture-video-1", in: app)
        XCTAssertTrue(waitForHittable(video, timeout: 5))
        video.click()

        let sidebar = element("sidebar.playback-context", in: app)
        let signature = app.buttons[
            "sidebar.playback-uploader.signature"
        ]
        XCTAssertTrue(sidebar.waitForExistence(timeout: 5))
        XCTAssertTrue(waitForHittable(signature, timeout: 5))
        XCTAssertEqual(signature.label, "UP 主签名")
        XCTAssertTrue(accessibilityText(of: signature).hasPrefix("已收起，"))
        let collapsedFrame = signature.frame

        signature.click()

        XCTAssertTrue(
            waitForAccessibilityText(
                signature,
                beginningWith: "已展开，",
                timeout: 5
            )
        )
        XCTAssertGreaterThan(signature.frame.height, collapsedFrame.height)
        XCTAssertGreaterThanOrEqual(signature.frame.minX, sidebar.frame.minX)
        XCTAssertLessThanOrEqual(signature.frame.maxX, sidebar.frame.maxX)

        signature.click()

        XCTAssertTrue(
            waitForAccessibilityText(
                signature,
                beginningWith: "已收起，",
                timeout: 5
            )
        )
        XCTAssertEqual(signature.frame.height, collapsedFrame.height, accuracy: 1)
    }

    @MainActor
    func testPlaybackSidebarHidesEmptySummaryAndSinglePart() {
        let app = launchFixture(arguments: [
            "-ui-testing",
            "-ui-testing-single-part-empty-summary",
        ])
        let video = element("feed.item.fixture-video-1", in: app)
        XCTAssertTrue(video.waitForExistence(timeout: 5))
        video.click()

        XCTAssertTrue(
            element("sidebar.playback-context", in: app)
                .waitForExistence(timeout: 5)
        )
        XCTAssertFalse(element("sidebar.playback-summary", in: app).exists)
        XCTAssertFalse(element("sidebar.playback-parts", in: app).exists)
        XCTAssertFalse(element("sidebar.playback-part.1", in: app).exists)
        XCTAssertTrue(
            element("sidebar.playback-comments-unavailable", in: app)
                .waitForExistence(timeout: 5)
        )

        clickSystemBack(in: app)
        XCTAssertTrue(
            element("playback.status.stopped", in: app)
                .waitForExistence(timeout: 5)
        )
    }

    @MainActor
    func testContextualNavigatorReturnsEachSourceAndRestoresSearchDraft()
        throws
    {
        let app = launchFixture(arguments: [
            "-ui-testing",
            "-ui-testing-contextual-navigator",
        ])
        let requestProbe = element("fixture.source-requests", in: app)

        let popularMarker = element(
            "feed.item.fixture-popular-marker",
            in: app
        )
        let popularGrid = element("feed.grid", in: app)
        XCTAssertTrue(popularGrid.waitForExistence(timeout: 5))
        XCTAssertTrue(
            scrollUntilHittable(
                popularMarker,
                in: popularGrid,
                maximumScrolls: 12
            )
        )
        let popularRequests = try XCTUnwrap(
            probeFields(from: requestProbe)["popular"]
        )
        popularMarker.click()
        XCTAssertTrue(
            element("playback.destination", in: app)
                .waitForExistence(timeout: 5)
        )
        clickSystemBack(in: app)
        XCTAssertTrue(element("feed.grid", in: app).waitForExistence(timeout: 5))
        XCTAssertTrue(waitForHittable(popularMarker, timeout: 5))
        XCTAssertEqual(
            probeFields(from: requestProbe)["popular"],
            popularRequests
        )

        let searchSource = element("sidebar.search", in: app)
        XCTAssertTrue(waitForHittable(searchSource, timeout: 5))
        searchSource.click()
        let searchField = app.searchFields.firstMatch
        XCTAssertTrue(waitForHittable(searchField, timeout: 5))
        searchField.click()
        let searchDraft = "12345"
        searchField.typeText(searchDraft)
        searchField.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(
            waitForProbe(requestProbe, timeout: 5) { fields in
                fields["search"] == "1"
            }
        )
        let searchMarker = element(
            "search.item.fixture-search-marker",
            in: app
        )
        let searchResults = app.scrollViews["search.results"]
        XCTAssertTrue(searchResults.waitForExistence(timeout: 5))
        XCTAssertTrue(
            scrollUntilHittable(
                searchMarker,
                in: searchResults,
                maximumScrolls: 12
            )
        )
        let searchRequests = try XCTUnwrap(
            probeFields(from: requestProbe)["search"]
        )
        searchMarker.click()
        XCTAssertTrue(
            element("sidebar.contextual-fixture", in: app)
                .waitForExistence(timeout: 5)
        )
        clickSystemBack(in: app)
        XCTAssertTrue(
            element("search.results", in: app).waitForExistence(timeout: 5)
        )
        XCTAssertTrue(waitForHittable(searchMarker, timeout: 5))
        XCTAssertEqual(
            probeFields(from: requestProbe)["search"],
            searchRequests
        )
        XCTAssertTrue(
            waitForAccessibilityText(
                app.searchFields.firstMatch,
                equalTo: searchDraft,
                timeout: 5
            )
        )

        let historySource = element("sidebar.history", in: app)
        XCTAssertTrue(waitForHittable(historySource, timeout: 5))
        historySource.click()
        let historyMarker = element(
            "history.item.fixture-history-marker",
            in: app
        )
        let historyList = element("history.list", in: app)
        XCTAssertTrue(historyList.waitForExistence(timeout: 5))
        XCTAssertTrue(
            scrollUntilHittable(
                historyMarker,
                in: historyList,
                maximumScrolls: 12
            )
        )
        let historyRequests = try XCTUnwrap(
            probeFields(from: requestProbe)["history"]
        )
        historyMarker.click()
        XCTAssertTrue(
            element("sidebar.contextual-fixture", in: app)
                .waitForExistence(timeout: 5)
        )
        clickSystemBack(in: app)
        XCTAssertTrue(
            element("history.list", in: app).waitForExistence(timeout: 5)
        )
        XCTAssertTrue(waitForHittable(historyMarker, timeout: 5))
        XCTAssertEqual(
            probeFields(from: requestProbe)["history"],
            historyRequests
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
            waitForAccessibilityText(
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
        let initialSize = CGSize(width: 1_320, height: 820)
        resizeWindow(window, to: initialSize)
        XCTAssertTrue(
            waitForWindowSize(
                window,
                size: initialSize,
                accuracy: 6,
                timeout: 5
            )
        )

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
            waitForAccessibilityText(
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
        let stableTimeline = try waitForTimeline(
            timeline,
            item: "fixture-video-B",
            minimumMilliseconds: 100
        )
        let stablePlayerIdentity = stableTimeline["playerIdentity"]
        let stableItemIdentity = stableTimeline["itemIdentity"]
        let stableGeneration = stableTimeline["generation"]

        let compactSize = CGSize(width: 1_080, height: 680)
        resizeWindow(window, to: compactSize)
        XCTAssertTrue(
            waitForWindowSize(
                window,
                size: compactSize,
                accuracy: 6,
                timeout: 5
            )
        )
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
            let buttons = systemNavigationToolbarButtons(
                expectedCount: 2,
                in: app,
                timeout: 5
            )
        else {
            XCTFail("Expected one visible system Back button")
            return
        }
        buttons[1].click()
    }

    @MainActor
    private func waitForTimeline(
        _ element: XCUIElement,
        item: String,
        minimumMilliseconds: Int,
        minimumGeneration: Int? = nil
    ) throws -> [String: String] {
        XCTAssertTrue(element.waitForExistence(timeout: 5))
        XCTAssertTrue(
            waitForProbe(element, timeout: 10) { fields in
                fields["item"] == item
                    && fields["status"] == "playing"
                    && (Int(fields["timeMillis"] ?? "") ?? 0)
                        >= minimumMilliseconds
                    && minimumGeneration.map {
                        (Int(fields["generation"] ?? "") ?? 0) >= $0
                    } ?? true
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
        let value = accessibilityText(of: element)
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
        for _ in 0..<3 {
            let frame = window.frame
            guard
                abs(frame.width - size.width) > 1
                    || abs(frame.height - size.height) > 1
            else {
                return
            }
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
    }

    @MainActor
    private func waitForWindowSize(
        _ window: XCUIElement,
        size: CGSize,
        accuracy: CGFloat,
        timeout: TimeInterval
    ) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                abs(window.frame.width - size.width) <= accuracy
                    && abs(window.frame.height - size.height) <= accuracy
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
        let expectedCount = element("playback.destination", in: app).exists ? 2 : 1
        guard
            let buttons = systemNavigationToolbarButtons(
                expectedCount: expectedCount,
                in: app,
                timeout: 5
            )
        else {
            XCTFail("Expected one visible NavigationSplitView sidebar toggle")
            return
        }
        buttons[0].click()
    }

    @MainActor
    private func systemNavigationToolbarButtons(
        expectedCount: Int,
        in app: XCUIApplication,
        timeout: TimeInterval
    ) -> [XCUIElement]? {
        let query = app.windows.firstMatch.toolbars.firstMatch.buttons
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                query.allElementsBoundByIndex.filter {
                    $0.exists && $0.isHittable
                }.count == expectedCount
            },
            object: app
        )
        guard
            XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
        else {
            return nil
        }
        return query.allElementsBoundByIndex.filter {
            $0.exists && $0.isHittable
        }.sorted {
            $0.frame.minX < $1.frame.minX
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
    private func waitForAccessibilityText(
        _ element: XCUIElement,
        equalTo expectedText: String,
        timeout: TimeInterval
    ) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                self.accessibilityText(of: element) == expectedText
            },
            object: element
        )
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    @MainActor
    private func waitForAccessibilityText(
        _ element: XCUIElement,
        beginningWith expectedPrefix: String,
        timeout: TimeInterval
    ) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                self.accessibilityText(of: element).hasPrefix(expectedPrefix)
            },
            object: element
        )
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    @MainActor
    private func accessibilityText(of element: XCUIElement) -> String {
        if let value = element.value as? String, !value.isEmpty {
            return value
        }
        return element.label
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
    private func scrollUntilHittable(
        _ element: XCUIElement,
        in container: XCUIElement,
        timeout: TimeInterval
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        var scrollCount = 0
        while Date() < deadline, scrollCount < 12 {
            if element.exists && element.isHittable {
                return true
            }
            let delta = -max(container.frame.height * 0.75, 60)
            container.scroll(byDeltaX: 0, deltaY: delta)
            scrollCount += 1
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
    private func waitForVisible(
        _ element: XCUIElement,
        in container: XCUIElement,
        timeout: TimeInterval
    ) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                guard element.exists, container.exists else { return false }
                let intersection = element.frame.intersection(container.frame)
                return !intersection.isNull
                    && intersection.height >= element.frame.height * 0.8
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
