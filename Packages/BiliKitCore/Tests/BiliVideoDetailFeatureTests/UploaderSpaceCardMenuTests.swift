import AppKit
import BiliModels
import BiliUI
import BiliVideoCollectionUI
import Foundation
import SwiftUI
import Testing

@testable import BiliVideoDetailFeature

/// UP 主空间的投稿行用视频卡片同一份菜单（组成与禁用规则由 BiliVideoCollectionUITests 的 `NativeVideoCardMenuTests`
/// 固定），按 BVID 打开该视频的网页地址，BVID 不合法时没有菜单；右键弹出时画上下文描边、关闭后撤销，Control-点按只弹
/// 菜单不进入播放，拆除后不再提供菜单。
@MainActor
struct UploaderSpaceCardMenuTests {
    @Test
    func rowMenuOpensTheVideoWebPage() throws {
        var opened: [URL] = []
        let menu = try #require(
            UploaderSpaceSidebarView.cardMenu(
                for: Self.row("BV1SpaceRow"),
                openURL: OpenURLAction { url in
                    opened.append(url)
                    return .handled
                },
                writing: .unavailable
            )
        )

        try #require(menu.items.first { $0.title == VideoCardMenuText.openInBrowser }).action()
        #expect(opened.map(\.absoluteString) == ["https://www.bilibili.com/video/BV1SpaceRow"])
    }

    @Test
    func rowWithoutAValidBVIDHasNoMenu() {
        #expect(
            UploaderSpaceSidebarView.cardMenu(
                for: Self.row("BV1 spaced"),
                openURL: OpenURLAction { _ in .handled },
                writing: nil
            ) == nil
        )
    }

    @Test
    func rightClickOpensTheRowMenuAndRingFollowsOpenAndClose() throws {
        var requested: [String] = []
        let list = Self.list(cardMenu: { row in
            requested.append(row.bvid)
            return UploaderSpaceSidebarView.cardMenu(
                for: row,
                openURL: OpenURLAction { _ in .handled },
                writing: .unavailable
            )
        })
        defer { list.controller.tearDown() }
        let (collectionView, row) = try Self.firstRow(in: list)
        let event = try Self.event(.rightMouseDown, [], on: row, in: collectionView)

        let menu = try #require(collectionView.menu(for: event))
        #expect(requested == ["BV1SpaceRow"])
        #expect(menu.items.filter { !$0.isSeparatorItem }.count == 4)
        #expect(row.layer?.borderWidth == 0)

        collectionView.willOpenMenu(menu, with: event)
        #expect((row.layer?.borderWidth ?? 0) > 0)
        collectionView.didCloseMenu(menu, with: event)
        #expect(row.layer?.borderWidth == 0)
    }

    @Test
    func controlClickAsksForTheMenuWithoutActivating() throws {
        var requested: [String] = []
        var selections: [String] = []
        let list = Self.list(
            cardMenu: { row in
                requested.append(row.bvid)
                return nil
            },
            selectVideo: { selections.append($0) }
        )
        defer { list.controller.tearDown() }
        let (collectionView, row) = try Self.firstRow(in: list)

        row.mouseDown(with: try Self.event(.leftMouseDown, .control, on: row, in: collectionView))
        row.mouseUp(with: try Self.event(.leftMouseUp, .control, on: row, in: collectionView))

        #expect(requested == ["BV1SpaceRow"])
        #expect(selections.isEmpty)
    }

    @Test
    func tearDownStopsOfferingMenus() throws {
        var requested: [String] = []
        let list = Self.list(cardMenu: { row in
            requested.append(row.bvid)
            return nil
        })
        let (collectionView, row) = try Self.firstRow(in: list)

        list.controller.tearDown()
        #expect(
            collectionView.menu(
                for: try Self.event(.rightMouseDown, [], on: row, in: collectionView)
            ) == nil
        )
        #expect(requested.isEmpty)
    }

    private static func row(_ bvid: String) -> UploaderVideoRowPresentation {
        UploaderVideoRowPresentation(video: .testFixture(bvid: bvid))
    }

    private static func list(
        cardMenu: @escaping (UploaderVideoRowPresentation) -> NativeVideoCardMenu?,
        selectVideo: @escaping (String) -> Void = { _ in }
    ) -> UploaderSpaceListFixture {
        UploaderSpaceListFixture(
            rows: [row("BV1SpaceRow")],
            actions: UploaderSpaceListActions(
                selectOrder: { _ in },
                selectVideo: selectVideo,
                cardMenu: cardMenu
            )
        )
    }

    private static func firstRow(
        in list: UploaderSpaceListFixture
    ) throws -> (NSCollectionView, UploaderSpaceVideoRowView) {
        let collectionView = try #require(
            list.controller.scrollView.documentView as? NSCollectionView
        )
        let item = try #require(collectionView.item(at: IndexPath(item: 0, section: 1)))
        let row = try #require(item.view as? UploaderSpaceVideoRowView)
        return (collectionView, row)
    }

    private static func event(
        _ type: NSEvent.EventType,
        _ modifiers: NSEvent.ModifierFlags,
        on row: NSView,
        in collectionView: NSCollectionView
    ) throws -> NSEvent {
        let window = try #require(collectionView.window)
        return try #require(
            NSEvent.mouseEvent(
                with: type,
                location: row.convert(NSPoint(x: row.bounds.midX, y: row.bounds.midY), to: nil),
                modifierFlags: modifiers,
                timestamp: 0,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: 1
            )
        )
    }
}
