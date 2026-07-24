//
//  BiliKitMacUITests.swift
//  BiliKitMacUITests
//
//  Created by shiinayane on 2026/07/21.
//

import XCTest

final class BiliKitMacUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testFixtureCoreKeyboardAndRecoveryPath() throws {
        let app = launchFixture(arguments: ["-ui-testing"])

        let feedGrid = element("feed.grid", in: app)
        XCTAssertTrue(feedGrid.waitForExistence(timeout: 5))

        element("sidebar.search", in: app).click()
        let searchField = element("search.field", in: app)
        XCTAssertTrue(searchField.waitForExistence(timeout: 5))
        searchField.click()
        searchField.typeText("示例")
        searchField.typeKey(.return, modifierFlags: [])

        XCTAssertTrue(
            element("search.results", in: app)
                .waitForExistence(timeout: 5)
        )
        let searchResult = element("search.item.fixture-search-1", in: app)
        XCTAssertTrue(searchResult.waitForExistence(timeout: 5))
        searchResult.click()
        XCTAssertTrue(
            element("playback.layout.wide", in: app)
                .waitForExistence(timeout: 5)
        )

        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(
            element("search.results", in: app)
                .waitForExistence(timeout: 5)
        )

        element("sidebar.history", in: app).click()
        XCTAssertTrue(
            element("history.signed-out", in: app)
                .waitForExistence(timeout: 5)
        )

        element("sidebar.account", in: app).click()
        XCTAssertTrue(
            element("auth.start", in: app)
                .waitForExistence(timeout: 5)
        )
    }

    @MainActor
    func testCompactDarkAccessibilityDisplayPair() throws {
        let app = launchFixture(arguments: [
            "-ui-testing",
            "-ui-testing-compact",
            "-ui-testing-dark",
            "-ui-testing-large-text",
        ])

        XCTAssertTrue(
            element("feed.grid", in: app)
                .waitForExistence(timeout: 5)
        )
        XCTAssertTrue(
            element("feed.item.fixture-video-1", in: app)
                .waitForExistence(timeout: 5)
        )

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        XCTAssertEqual(window.frame.width, 1_080, accuracy: 4)
        XCTAssertLessThan(window.frame.height, 740)

        let attachment = XCTAttachment(screenshot: window.screenshot())
        attachment.name = "Fixture Compact Dark Accessibility"
        attachment.lifetime = .keepAlways
        add(attachment)

        element("feed.item.fixture-video-1", in: app).click()
        XCTAssertTrue(
            element("playback.layout.compact", in: app)
                .waitForExistence(timeout: 5)
        )
        app.scrollViews["playback.layout.compact"]
            .coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .scroll(byDeltaX: 0, deltaY: -420)
        let partsDisclosure = app.disclosureTriangles["分 P"]
        partsDisclosure
            .coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.5))
            .click()
        for (index, title, duration) in [
            (1, "示例章节一", "20:05"),
            (2, "示例章节二", "23:20"),
            (3, "示例章节三", "26:40"),
        ] {
            let part = element("playback.part.\(index)", in: app)
            XCTAssertTrue(part.waitForExistence(timeout: 5))
            XCTAssertEqual(
                part.label,
                "第 \(index) 分 P，\(title)，\(duration)"
            )
            XCTAssertEqual(part.isSelected, index == 1)
        }
    }

    @MainActor
    private func launchFixture(arguments: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = arguments
        app.launch()
        if !app.windows.firstMatch.waitForExistence(timeout: 2) {
            app.activate()
            app.typeKey("n", modifierFlags: .command)
        }
        return app
    }

    @MainActor
    private func element(
        _ identifier: String,
        in app: XCUIApplication
    ) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }
}
