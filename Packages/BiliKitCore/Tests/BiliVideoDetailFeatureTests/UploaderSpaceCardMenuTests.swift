import AppKit
import BiliModels
import BiliUI
import BiliVideoCollectionUI
import Foundation
import SwiftUI
import Testing

@testable import BiliVideoDetailFeature

/// UP 主空间的投稿行与视频卡片有同一份卡片菜单：「添加到稍后再看」「收藏到…」（不满足写入门槛时禁用）与「拷贝链接」
/// 「在浏览器中打开」；右键弹出时画上下文描边、关闭后撤销，Control-点按只弹菜单不进入播放。
@MainActor
struct UploaderSpaceCardMenuTests {
    @Test
    func rowMenuMatchesTheVideoCardMenu() throws {
        var opened: [URL] = []
        let menu = try #require(
            UploaderSpaceSidebarView.cardMenu(
                for: Self.row("BV1SpaceRow"),
                openURL: OpenURLAction { url in
                    opened.append(url)
                    return .handled
                },
                writing: Self.writing
            )
        )

        #expect(
            menu.items.map(\.title)
                == [
                    VideoCardMenuText.addToWatchLater,
                    VideoCardMenuText.addToFavorites,
                    VideoCardMenuText.copyLink,
                    VideoCardMenuText.openInBrowser
                ]
        )
        #expect(menu.items.map(\.isEnabled) == [false, false, true, true])
        menu.items[3].action()
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
                writing: Self.writing
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

    private struct ListFixture {
        let controller: UploaderSpaceListController
        let window: NSWindow
    }

    private static let writing = VideoCardAccountWriting(
        isAvailable: { false },
        addToWatchLater: { _ in },
        removeFromWatchLater: { _ in },
        chooseFavoriteFolders: { _ in },
        removeFromFavoriteFolder: { _ in },
        dislikeRecommendation: { _ in },
        cancelRecommendationDislike: { _ in }
    )

    private static func row(_ bvid: String) -> UploaderVideoRowPresentation {
        UploaderVideoRowPresentation(
            video: UploaderVideo(
                bvid: bvid,
                title: "投稿",
                coverURL: nil,
                durationSeconds: 60,
                viewCount: 1,
                danmakuCount: 0,
                publishedAt: Date(timeIntervalSince1970: 1_700_000_000),
                isCollaboration: false
            )
        )
    }

    private static func list(
        cardMenu: @escaping (UploaderVideoRowPresentation) -> NativeVideoCardMenu?,
        selectVideo: @escaping (String) -> Void = { _ in }
    ) -> ListFixture {
        let controller = UploaderSpaceListController(imagePipeline: StubVideoDetailImageLoader())
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 600),
            styleMask: [.borderless],
            backing: .buffered,
            defer: true
        )
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 600))
        window.contentView = container
        controller.scrollView.frame = container.bounds
        container.addSubview(controller.scrollView)
        controller.update(
            content: UploaderSpaceListContent(
                header: UploaderSpaceHeaderContent(
                    name: "UP 主",
                    avatarURL: nil,
                    totalCount: nil,
                    order: .newest
                ),
                rows: [row("BV1SpaceRow")],
                currentBVID: nil,
                pageIdentity: .init(ownerID: 1, order: .newest, page: 1),
                reservesPagerSpace: false
            ),
            actions: UploaderSpaceListActions(
                close: {},
                selectOrder: { _ in },
                selectVideo: selectVideo,
                cardMenu: cardMenu
            )
        )
        container.layoutSubtreeIfNeeded()
        return ListFixture(controller: controller, window: window)
    }

    private static func firstRow(
        in list: ListFixture
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
