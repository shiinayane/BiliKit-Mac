import AppKit
import BiliUI
import SwiftUI
import Testing

@testable import BiliVideoCollectionUI

/// 卡片菜单：右键菜单、读屏自定义操作与 ⌘⌫ 出自同一份描述。
///
/// 写操作一组在前、链接一组在后，组间有分隔线；「拷贝链接」「在浏览器中打开」「添加到稍后再看」与「收藏到…」只给可进入
/// 播放的卡片，「从稍后再看移除」与收藏夹页的「从此收藏夹移除」也给不可用卡片并带 ⌘⌫；不满足写入门槛时
/// 写操作项在菜单里禁用、不进入读屏操作；读屏操作执行时按卡片 ID 重新核对；没有项时不弹菜单；Control-点按走右键同一条
/// 菜单路径，不激活卡片。来源自己的写操作项排在写操作一组末尾；子菜单在 `NSMenu` 里展开为一级子菜单，在读屏操作里
/// 展开为带父项名字的各个子项，子项都不可用时父项也不可用。
struct NativeVideoCardMenuTests {
    private static let webPage = URL(string: "https://www.bilibili.com/video/BV1Menu")

    @Test @MainActor
    func submenuIsNestedInTheMenuAndFlattenedForVoiceOver() throws {
        var chosen: [String] = []
        let children = ["a", "b"].map { id in
            NativeVideoCardMenu.Item(id: id, title: id.uppercased(), systemImage: "circle") {
                chosen.append(id)
            }
        }
        let menu = try #require(
            NativeVideoCardMenu.video(
                videoID: "BV1Menu",
                isActivatable: true,
                webPageURL: Self.webPage,
                openURL: OpenURLAction { _ in .handled },
                writing: nil,
                watchLater: .add,
                additionalWriteItems: [
                    NativeVideoCardMenu.Item(
                        id: "parent",
                        title: "Parent",
                        systemImage: "circle",
                        submenu: children
                    )
                ]
            )
        )

        #expect(
            menu.sections.map { $0.map(\.title) } == [
                ["Parent"], [VideoCardMenuText.copyLink, VideoCardMenuText.openInBrowser]
            ]
        )
        let parent = try #require(menu.makeMenu().items.first)
        #expect(parent.submenu?.items.map(\.title) == ["A", "B"])
        #expect(parent.submenu?.autoenablesItems == false)
        #expect(
            menu.actionableItems.prefix(2).map(\.title) == [
                VideoCardMenuText.submenuActionTitle(parent: "Parent", child: "A"),
                VideoCardMenuText.submenuActionTitle(parent: "Parent", child: "B")
            ]
        )
        try #require(menu.enabledItem(id: "b")).action()
        #expect(chosen == ["b"])
        #expect(menu.enabledItem(id: "parent") == nil)

        let disabled = NativeVideoCardMenu.Item(
            id: "parent",
            title: "Parent",
            systemImage: "circle",
            submenu: [
                NativeVideoCardMenu.Item(
                    id: "a",
                    title: "A",
                    systemImage: "circle",
                    isEnabled: false
                ) {}
            ]
        )
        #expect(!disabled.isEnabled)
    }

    @Test @MainActor
    func playableCardOffersWriteGroupThenLinks() throws {
        var opened: [URL] = []
        var added: [String] = []
        var chosen: [String] = []
        let menu = try #require(
            NativeVideoCardMenu.video(
                videoID: "BV1Menu",
                isActivatable: true,
                webPageURL: Self.webPage,
                openURL: OpenURLAction { url in
                    opened.append(url)
                    return .handled
                },
                writing: Self.writing(
                    isAvailable: true,
                    added: { added.append($0) },
                    chosen: { chosen.append($0) }
                ),
                watchLater: .add
            )
        )

        #expect(
            menu.sections.map { $0.map(\.title) } == [
                [VideoCardMenuText.addToWatchLater, VideoCardMenuText.addToFavorites],
                [VideoCardMenuText.copyLink, VideoCardMenuText.openInBrowser]
            ]
        )
        #expect(menu.items.map(\.systemImage) == ["text.badge.plus", "star", "link", "globe"])
        menu.items[0].action()
        menu.items[1].action()
        menu.items[3].action()
        #expect(added == ["BV1Menu"])
        #expect(chosen == ["BV1Menu"])
        #expect(opened == [try #require(Self.webPage)])

        let nsMenu = menu.makeMenu()
        #expect(!nsMenu.autoenablesItems)
        #expect(nsMenu.items.map(\.isSeparatorItem) == [false, false, true, false, false])
    }

    /// 收藏夹页给出的移除排在写操作一组末尾并带 ⌘⌫；卡片 ID 不是 BVID（没有网页）的失效视频只剩这一项。
    @Test @MainActor
    func favoriteFolderRemovalEndsTheWriteGroupAndCoversCardsWithoutAWebPage() throws {
        let removals = RemovalCount()
        let remove: @MainActor @Sendable () -> Void = { removals.value += 1 }
        let openURL = OpenURLAction { _ in .handled }
        let writing = Self.writing(isAvailable: true)

        let playable = try #require(
            NativeVideoCardMenu.video(
                videoID: "BV1Menu",
                isActivatable: true,
                webPageURL: Self.webPage,
                openURL: openURL,
                writing: writing,
                watchLater: .add,
                removeFromFavoriteFolder: remove
            )
        )
        #expect(
            playable.sections.first?.map(\.title) == [
                VideoCardMenuText.addToWatchLater,
                VideoCardMenuText.addToFavorites,
                VideoCardMenuText.removeFromFavoriteFolder
            ]
        )
        playable.enabledItem(for: .commandDelete)?.action()
        #expect(removals.value == 1)

        let withoutWebPage = try #require(
            NativeVideoCardMenu.video(
                videoID: "fav-2-170001",
                isActivatable: false,
                webPageURL: nil,
                openURL: openURL,
                writing: writing,
                watchLater: .add,
                removeFromFavoriteFolder: remove
            )
        )
        #expect(withoutWebPage.items.map(\.title) == [VideoCardMenuText.removeFromFavoriteFolder])
        withoutWebPage.enabledItem(for: .commandDelete)?.action()
        #expect(removals.value == 2)
    }

    /// 稍后再看页：失效等不可用卡片只有「从稍后再看移除」（带 ⌘⌫），可播放卡片另有链接；其他来源的不可用卡片没有菜单。
    @Test @MainActor
    func watchLaterRemovalAlsoCoversUnavailableCards() throws {
        let openURL = OpenURLAction { _ in .handled }
        let writing = Self.writing(isAvailable: true)
        let unavailable = Self.card(id: "BV1Gone", availability: .unavailable(badge: "已失效"))

        let removal = try #require(
            NativeVideoCardMenu.video(
                videoID: unavailable.id,
                isActivatable: unavailable.isActivatable,
                webPageURL: Self.webPage,
                openURL: openURL,
                writing: writing,
                watchLater: .remove
            )
        )
        #expect(removal.items.map(\.title) == [VideoCardMenuText.removeFromWatchLater])
        #expect(removal.items[0].keyEquivalent == .commandDelete)
        #expect(removal.enabledItem(for: .commandDelete) != nil)
        let menuItem = try #require(removal.makeMenu().items.first)
        #expect(menuItem.keyEquivalent == "\u{8}")
        #expect(menuItem.keyEquivalentModifierMask == .command)

        #expect(
            NativeVideoCardMenu.video(
                videoID: unavailable.id,
                isActivatable: unavailable.isActivatable,
                webPageURL: Self.webPage,
                openURL: openURL,
                writing: writing,
                watchLater: .add
            ) == nil
        )
    }

    @Test @MainActor
    func cardsWithoutAWebPageOrWriteEntryHaveOnlyWhatTheyQualifyFor() throws {
        let openURL = OpenURLAction { _ in .handled }
        let playable = Self.card(id: "BV1Menu", availability: .available)

        #expect(
            NativeVideoCardMenu.video(
                videoID: playable.id,
                isActivatable: playable.isActivatable,
                webPageURL: nil,
                openURL: openURL,
                writing: Self.writing(isAvailable: true),
                watchLater: .add
            ) == nil
        )
        let withoutWriting = try #require(
            NativeVideoCardMenu.video(
                videoID: playable.id,
                isActivatable: playable.isActivatable,
                webPageURL: Self.webPage,
                openURL: openURL,
                writing: nil,
                watchLater: .remove
            )
        )
        #expect(
            withoutWriting.items.map(\.title)
                == [VideoCardMenuText.copyLink, VideoCardMenuText.openInBrowser]
        )
        #expect(NativeVideoCardMenu(sections: [[], []]) == nil)
    }

    /// 不满足门槛时写操作项仍显示但禁用（AppKit 不会自动重新启用），没有可执行的 ⌘⌫ 项。
    @Test @MainActor
    func unavailableWritingShowsDisabledItems() throws {
        var removed: [String] = []
        let menu = try #require(
            NativeVideoCardMenu.video(
                videoID: "BV1Menu",
                isActivatable: true,
                webPageURL: Self.webPage,
                openURL: OpenURLAction { _ in .handled },
                writing: Self.writing(isAvailable: false, removed: { removed.append($0) }),
                watchLater: .remove
            )
        )

        let nsMenu = menu.makeMenu()
        nsMenu.update()
        #expect(
            nsMenu.items.filter { !$0.isSeparatorItem }.map(\.isEnabled) == [
                false, false, true, true
            ]
        )
        #expect(menu.enabledItem(for: .commandDelete) == nil)
        #expect(removed.isEmpty)
    }

    @Test @MainActor
    func menuItemsPerformTheirActions() throws {
        var performed: [String] = []
        let titles = ["第一项", "第二项", "第三项"]
        let menu = try #require(
            NativeVideoCardMenu(
                sections: [
                    titles.map { title in
                        NativeVideoCardMenu.Item(id: title, title: title, systemImage: "star") {
                            performed.append(title)
                        }
                    }
                ]
            )
        )

        let nsMenu = menu.makeMenu()
        #expect(nsMenu.items.map(\.title) == titles)
        for menuItem in nsMenu.items {
            let target = try #require(menuItem.target as? NSObject)
            _ = target.perform(menuItem.action, with: menuItem)
        }
        #expect(performed == titles)
    }

    /// 网格卡片的读屏操作取自注入的 `cardMenu`：标题与顺序同菜单里可用的项；禁用项不进入操作；执行时按卡片 ID 与此刻的
    /// 描述重新核对；网格拆除后卡片不再有操作。
    @Test(.timeLimit(.minutes(1))) @MainActor
    func gridCardsExposeEnabledMenuItemsAsAccessibilityActions() async throws {
        var opened: [URL] = []
        var isWritingAvailable = false
        let openURL = OpenURLAction { url in
            opened.append(url)
            return .handled
        }
        let grid = try await GridFixture(
            cards: [
                Self.card(id: "BV1Menu0", availability: .available),
                Self.card(id: "BV1Menu1", availability: .unavailable(badge: "已失效"))
            ],
            cardMenu: { card in
                NativeVideoCardMenu.video(
                    videoID: card.id,
                    isActivatable: card.isActivatable,
                    webPageURL: URL(string: "https://www.bilibili.com/video/\(card.id)"),
                    openURL: openURL,
                    writing: Self.writing(isAvailable: isWritingAvailable),
                    watchLater: .add
                )
            }
        )
        defer { grid.tearDown() }
        let available = try grid.cardView("BV1Menu0")
        let unavailable = try grid.cardView("BV1Menu1")

        let actions = try #require(available.accessibilityCustomActions())
        #expect(
            actions.map(\.name) == [VideoCardMenuText.copyLink, VideoCardMenuText.openInBrowser]
        )
        #expect(actions[1].handler?() == true)
        #expect(opened.map(\.absoluteString) == ["https://www.bilibili.com/video/BV1Menu0"])
        #expect(unavailable.accessibilityCustomActions() == nil)
        #expect(!unavailable.isAccessibilityEnabled())

        isWritingAvailable = true
        let writeActions = try #require(available.accessibilityCustomActions())
        #expect(writeActions.first?.name == VideoCardMenuText.addToWatchLater)
        // 查询之后门槛变化：执行时按此刻的描述核对，禁用的项不再执行。
        isWritingAvailable = false
        #expect(writeActions.first?.handler?() == false)

        grid.coordinator.reset()
        #expect(available.accessibilityCustomActions() == nil)
    }

    /// 稍后再看页的失效卡片：读屏仍可用并列出「从稍后再看移除」，执行即移除；按下仍不进入播放；⌘⌫ 对选中卡片执行同一项。
    @Test(.timeLimit(.minutes(1))) @MainActor
    func unavailableWatchLaterCardsStayRemovableBySpeechAndKeyboard() async throws {
        var removed: [String] = []
        var selections: [String] = []
        var isWritingAvailable = true
        let grid = try await GridFixture(
            cards: [Self.card(id: "BV1Gone", availability: .unavailable(badge: "已失效"))],
            onSelect: { selections.append($0) },
            cardMenu: { card in
                NativeVideoCardMenu.video(
                    videoID: card.id,
                    isActivatable: card.isActivatable,
                    webPageURL: URL(string: "https://www.bilibili.com/video/\(card.id)"),
                    openURL: OpenURLAction { _ in .handled },
                    writing: Self.writing(
                        isAvailable: isWritingAvailable,
                        removed: { removed.append($0) }
                    ),
                    watchLater: .remove
                )
            }
        )
        defer { grid.tearDown() }
        let card = try grid.cardView("BV1Gone")

        #expect(card.isAccessibilityEnabled())
        #expect(!card.accessibilityPerformPress())
        let actions = try #require(card.accessibilityCustomActions())
        #expect(actions.map(\.name) == [VideoCardMenuText.removeFromWatchLater])
        #expect(actions[0].handler?() == true)
        #expect(removed == ["BV1Gone"])

        grid.collectionView.selectItems(at: [IndexPath(item: 0, section: 0)], scrollPosition: [])
        grid.collectionView.keyDown(with: try Self.commandDelete(in: grid.window))
        #expect(removed == ["BV1Gone", "BV1Gone"])

        isWritingAvailable = false
        grid.collectionView.keyDown(with: try Self.commandDelete(in: grid.window))
        #expect(removed == ["BV1Gone", "BV1Gone"])
        #expect(selections.isEmpty)
    }

    /// 打开卡片菜单的两个非右键入口。
    enum MenuEntry: String, CaseIterable {
        /// Control-点按沿响应链到达网格的 `mouseDown`。
        case controlClick
        /// 读屏「显示菜单」。
        case accessibilityShowMenu
    }

    /// Control-点按与读屏「显示菜单」都转进右键路径，由 `menu(for:)` 按位置向来源取这张卡片的菜单，且不激活卡片。
    ///
    /// 包测试进程里不能弹出真实菜单：菜单跟踪循环之后，AppKit 的事件线程会不断停掉主 run loop，Swift 并发的主执行器
    /// 随之 `exit(0)`。所以右键路径取菜单时来源返回 nil，AppKit 不弹菜单；读屏入口先确认有菜单才排队，来源只在这次
    /// 确认时给出菜单。
    @Test(.timeLimit(.minutes(1)), arguments: MenuEntry.allCases) @MainActor
    func entriesRouteToTheRightClickMenuWithoutActivating(entry: MenuEntry) async throws {
        var requestedIDs: [String] = []
        var selections: [String] = []
        let grid = try await GridFixture(
            cards: [Self.card(id: "BV1Menu0", availability: .available)],
            onSelect: { selections.append($0) },
            cardMenu: { card in
                requestedIDs.append(card.id)
                guard entry == .accessibilityShowMenu, requestedIDs.count == 1 else {
                    return nil
                }
                return NativeVideoCardMenu(
                    sections: [
                        [NativeVideoCardMenu.Item(id: "item", title: "菜单项", systemImage: "link") {}]
                    ]
                )
            }
        )
        defer { grid.tearDown() }
        let card = try grid.cardView("BV1Menu0")

        switch entry {
        case .controlClick:
            grid.collectionView.mouseDown(with: try grid.event(.leftMouseDown, .control, on: card))
        case .accessibilityShowMenu:
            #expect(card.accessibilityPerformShowMenu())
            // 读屏入口推到下一轮主队列才走右键路径；等第二次取菜单，超时由 time limit 兜底。
            while requestedIDs.count < 2 {
                await withCheckedContinuation { continuation in
                    DispatchQueue.main.async { continuation.resume() }
                }
            }
        }

        #expect(requestedIDs == (entry == .controlClick ? ["BV1Menu0"] : ["BV1Menu0", "BV1Menu0"]))
        #expect(selections.isEmpty)
        #expect(grid.collectionView.selectionIndexPaths.isEmpty)
    }

    /// 右键路径给出的就是来源的菜单（含禁用状态）；上下文描边只由 `willOpenMenu` 画、`didCloseMenu` 撤。
    @Test(.timeLimit(.minutes(1))) @MainActor
    func rightClickMenuIsTheSourceMenuAndRingFollowsOpenAndClose() async throws {
        let grid = try await GridFixture(
            cards: [Self.card(id: "BV1Menu0", availability: .available)],
            cardMenu: { card in
                NativeVideoCardMenu.video(
                    videoID: card.id,
                    isActivatable: card.isActivatable,
                    webPageURL: URL(string: "https://www.bilibili.com/video/\(card.id)"),
                    openURL: OpenURLAction { _ in .handled },
                    writing: Self.writing(isAvailable: false),
                    watchLater: .add
                )
            }
        )
        defer { grid.tearDown() }
        let card = try grid.cardView("BV1Menu0")
        let event = try grid.event(.rightMouseDown, [], on: card)

        let menu = try #require(grid.collectionView.menu(for: event))
        #expect(
            menu.items.filter { !$0.isSeparatorItem }.map(\.title)
                == [
                    VideoCardMenuText.addToWatchLater,
                    VideoCardMenuText.addToFavorites,
                    VideoCardMenuText.copyLink,
                    VideoCardMenuText.openInBrowser
                ]
        )
        #expect(menu.items.first?.isEnabled == false)
        #expect(card.layer?.borderWidth == 0)

        grid.collectionView.willOpenMenu(menu, with: event)
        #expect((card.layer?.borderWidth ?? 0) > 0)

        grid.collectionView.didCloseMenu(menu, with: event)
        #expect(card.layer?.borderWidth == 0)
    }

    @MainActor
    private static func writing(
        isAvailable: Bool,
        added: @escaping (String) -> Void = { _ in },
        removed: @escaping (String) -> Void = { _ in },
        chosen: @escaping (String) -> Void = { _ in }
    ) -> VideoCardAccountWriting {
        nonisolated(unsafe) let added = added
        nonisolated(unsafe) let removed = removed
        nonisolated(unsafe) let chosen = chosen
        return VideoCardAccountWriting(
            isAvailable: { isAvailable },
            addToWatchLater: { added($0) },
            removeFromWatchLater: { removed($0) },
            chooseFavoriteFolders: { chosen($0) },
            removeFromFavoriteFolder: { _ in },
            dislikeRecommendation: { _ in },
            cancelRecommendationDislike: { _ in }
        )
    }

    @MainActor
    private static func commandDelete(in window: NSWindow) throws -> NSEvent {
        // 窗口属性只能在主线程读；`#require` 的展开不继承主线程隔离，先取出再交给它。
        let windowNumber = window.windowNumber
        return try #require(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: .command,
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: windowNumber,
                context: nil,
                characters: "\u{7f}",
                charactersIgnoringModifiers: "\u{7f}",
                isARepeat: false,
                keyCode: 51
            )
        )
    }

    private static func card(
        id: String,
        availability: NativeVideoCardAvailability
    ) -> NativeVideoCardPresentation {
        NativeVideoCardPresentation(
            id: id,
            title: "手写卡片",
            coverURL: nil,
            avatarURL: nil,
            showsAvatar: false,
            footerLeadingText: "作者",
            accessibilityLabel: "手写卡片",
            availability: availability
        )
    }
}

/// 在无边框窗口里排好的网格，按 ID 取卡片视图；测试结束时 `tearDown` 拆除。
@MainActor
private struct GridFixture {
    let coordinator: NativeVideoGridView.Coordinator
    let window: NSWindow
    let collectionView: NSCollectionView

    init(
        cards: [NativeVideoCardPresentation],
        onSelect: @escaping (String) -> Void = { _ in },
        cardMenu: @escaping (NativeVideoCardPresentation) -> NativeVideoCardMenu?
    ) async throws {
        coordinator = NativeVideoGridView.Coordinator(
            items: cards,
            initialScrollOffsetY: 0,
            accessibilityLabel: "网格",
            tailState: .end,
            bottomInset: 0,
            scrollResetRequestID: 0,
            acknowledgedScrollResetRequestID: 0,
            imagePipeline: StubCardImageLoader(),
            onScroll: { _ in },
            onAcknowledgeScrollReset: { _ in },
            actions: NativeVideoGridActions(
                onNearEnd: {},
                onSelect: onSelect,
                cardMenu: cardMenu
            )
        )
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let scrollView = coordinator.makeScrollView()
        window.contentView = scrollView
        // makeScrollView 把首次排版排到下一轮主队列；等它跑完再取卡片。
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        scrollView.layoutSubtreeIfNeeded()
        collectionView = try #require(scrollView.documentView as? NSCollectionView)
    }

    func cardView(_ id: String) throws -> NSView {
        let item = try #require(
            collectionView.visibleItems()
                .compactMap { $0 as? NativeVideoCollectionItem }
                .first { $0.representedVideoID == id }
        )
        return item.view
    }

    /// 落在 `view` 中心的鼠标事件。
    func event(
        _ type: NSEvent.EventType,
        _ modifierFlags: NSEvent.ModifierFlags,
        on view: NSView
    ) throws -> NSEvent {
        // 视图与窗口属性只能在主线程读；`#require` 的展开不继承主线程隔离，先取出再交给它。
        let location = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        let windowNumber = window.windowNumber
        return try #require(
            NSEvent.mouseEvent(
                with: type,
                location: location,
                modifierFlags: modifierFlags,
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: 1
            )
        )
    }

    func tearDown() {
        coordinator.reset()
        window.contentView = NSView()
    }
}

/// 收藏夹移除动作被执行的次数；动作在主线程调用。
@MainActor
private final class RemovalCount {
    var value = 0
}
