import AppKit
import BiliVideoCollectionUI
import Foundation
import Testing

@testable import BiliVideoDetailFeature

/// 相关推荐横排按页滚动并露出下一张，任何滚动条样式下都不为滚动条让出卡片高度，视口通知推迟到布局之后；加载骨架按
/// 可见宽度铺满；拆除时清掉横排里的第一响应者，键盘激活按稳定 ID 找卡片、不依赖可见项实例；换视频时整体替换并作废旧的封面请求；被遮挡时不给卡片菜单。
struct NativeVideoShelfTests {
    @Test
    @MainActor
    func pagingGeometryPreservesPeekAndNarrowWindowCapacity() {
        #expect(NativeVideoShelfGeometry.pageCapacity(viewportWidth: 784) == 3)
        #expect(NativeVideoShelfGeometry.pageCapacity(viewportWidth: 260) == 1)
        #expect(NativeVideoShelfGeometry.offset(for: 3) == 720)
        #expect(NativeVideoShelfGeometry.nearestIndex(offset: 370, itemCount: 8) == 2)
        #expect(NativeVideoShelfGeometry.documentWidth(itemCount: 0) == 0)
        #expect(NativeVideoShelfGeometry.documentWidth(itemCount: 3) == 784)
    }

    @Test(arguments: [
        // 三张完整卡片之外还露出第四张的一截：翻页只算完整的 3 张，骨架画 4 张。
        (width: CGFloat(784), count: 4),
        // 第四张的右缘恰好落在可见右缘。
        (width: 984, count: 4),
        (width: 1_200, count: 5),
        (width: 2_560, count: 11),
        // 窄窗口、零宽与非有限宽度至少画一张。
        (width: 260, count: 1),
        (width: 0, count: 1),
        (width: .infinity, count: 1),
        (width: .nan, count: 1)
    ])
    @MainActor
    func loadingSkeletonFillsTheVisibleWidth(_ sample: (width: CGFloat, count: Int)) {
        #expect(
            NativeVideoShelfGeometry.placeholderCount(viewportWidth: sample.width) == sample.count
        )
    }

    @Test(arguments: [NSScroller.Style.legacy, .overlay])
    @MainActor
    func scrollerNeverTakesRowHeight(_ scrollerStyle: NSScroller.Style) {
        let items = (0..<12).map { index in
            NativeVideoCardPresentation(
                id: "BV-\(index)",
                title: "相关推荐 \(index)",
                coverURL: nil,
                avatarURL: nil,
                showsAvatar: false,
                footerLeadingText: "作者",
                accessibilityLabel: "相关推荐 \(index)"
            )
        }
        let coordinator = NativeVideoShelfView.Coordinator(
            contentIdentity: "BV-parent",
            items: items,
            imagePipeline: NativeVideoShelfPendingImageLoader(),
            reduceMotion: true,
            isInteractionEnabled: true,
            onSelect: { _ in },
            cardMenu: { _ in nil }
        )
        let scrollView = coordinator.makeScrollView()
        scrollView.scrollerStyle = scrollerStyle
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 300),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = scrollView
        defer {
            coordinator.reset()
            window.contentView = NSView()
        }
        // 集合视图只在内容比视口宽时、布局与每次滚动中去打开外层的横向滚动条，所以要真实内容排版并滚动之后再看。
        scrollView.layoutSubtreeIfNeeded()
        scrollView.scrollHorizontally(to: NativeVideoShelfGeometry.stride, animated: false)
        scrollView.layoutSubtreeIfNeeded()

        #expect(Self.logicalOffset(of: scrollView) > 0)
        #expect(!scrollView.hasHorizontalScroller)
        #expect(scrollView.contentView.frame.height == scrollView.bounds.height)
    }

    @Test(.timeLimit(.minutes(1)))
    @MainActor
    func viewportAndInsetNotificationsAreDeferredBeyondTheCurrentLayoutPass() async {
        let scrollView = NativeVideoShelfScrollView(
            frame: NSRect(x: 0, y: 0, width: 900, height: 232)
        )
        scrollView.install(collectionView: NSCollectionView())
        let (notifications, continuation) = AsyncStream<Void>.makeStream()
        var notificationCount = 0
        scrollView.onViewportLayout = {
            notificationCount += 1
            continuation.yield()
        }
        var iterator = notifications.makeAsyncIterator()

        scrollView.layoutSubtreeIfNeeded()

        #expect(notificationCount == 0)
        _ = await iterator.next()
        #expect(notificationCount == 1)

        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(
            top: 0,
            left: 120,
            bottom: 0,
            right: 0
        )
        scrollView.layout()

        #expect(notificationCount == 1)
        _ = await iterator.next()
        continuation.finish()
        #expect(notificationCount == 2)
        scrollView.reset()
    }

    @Test
    @MainActor
    func teardownClearsAnyFirstResponderInsideTheShelf() {
        let scrollView = NativeVideoShelfScrollView()
        let focusView = NativeVideoShelfFocusViewForTesting()
        scrollView.addSubview(focusView)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 300),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = scrollView

        #expect(window.makeFirstResponder(focusView))
        #expect(window.firstResponder === focusView)

        scrollView.clearFirstResponderIfNeeded()

        #expect(window.firstResponder !== focusView)
        window.contentView = NSView()
    }

    @Test
    @MainActor
    func keyboardActivationResolvesStableIDWithoutVisibleItemInstance() {
        let selected = NativeVideoShelfCollectionView.selectedItemID(
            selectionIndexPaths: [IndexPath(item: 7, section: 0)],
            itemIDAtIndex: { index in index == 7 ? "BV-stable" : nil }
        )

        #expect(selected == "BV-stable")
    }

    /// 父视频变了即使 ID 序列相同也整体替换：旧卡片的在途封面请求被取消，横排回到起点后重新配置可见卡片。
    @Test(.timeLimit(.minutes(1)))
    @MainActor
    func parentVideoChangeReplacesContentEvenWithTheSameIDs() async {
        let loader = NativeVideoShelfPendingImageLoader()
        var events = loader.events.makeAsyncIterator()
        let items = (0..<12).map { index in
            NativeVideoCardPresentation(
                id: "BV-\(index)",
                title: "相关推荐 \(index)",
                coverURL: URL(string: "https://i0.hdslb.com/bfs/archive/\(index).jpg"),
                avatarURL: nil,
                showsAvatar: false,
                footerLeadingText: "作者",
                accessibilityLabel: "相关推荐 \(index)"
            )
        }
        let coordinator = NativeVideoShelfView.Coordinator(
            contentIdentity: "BV-parent-a",
            items: items,
            imagePipeline: loader,
            reduceMotion: true,
            isInteractionEnabled: true,
            onSelect: { _ in },
            cardMenu: { _ in nil }
        )
        let scrollView = coordinator.makeScrollView()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 300),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = scrollView
        defer {
            coordinator.reset()
            window.contentView = NSView()
        }
        scrollView.layoutSubtreeIfNeeded()

        // 首张开始加载的封面属于视野内的卡片；只滚动半张卡片的距离，它仍在视野内。
        guard case .started(let visibleCoverURL)? = await events.next() else {
            Issue.record("横排没有为可见卡片发起封面请求")
            return
        }
        scrollView.scrollHorizontally(to: NativeVideoShelfGeometry.stride / 2, animated: false)
        #expect(Self.logicalOffset(of: scrollView) > 0)

        coordinator.update(
            contentIdentity: "BV-parent-b",
            items: items,
            reduceMotion: true,
            isInteractionEnabled: true,
            onSelect: { _ in },
            cardMenu: { _ in nil }
        )

        // 快照完成后重配可见卡片会为同一张封面重新发起请求；先要看到旧请求被取消。
        var cancelledVisibleCover = false
        while let event = await events.next() {
            if event == .cancelled(visibleCoverURL) { cancelledVisibleCover = true }
            if cancelledVisibleCover, event == .started(visibleCoverURL) { break }
        }
        #expect(cancelledVisibleCover)
        #expect(Self.logicalOffset(of: scrollView) == 0)
    }

    /// 被遮挡（交互关闭）的横排不给卡片菜单，右键与读屏操作都取不到；恢复交互后照常给出。
    @Test(.timeLimit(.minutes(1)))
    @MainActor
    func occludedShelfOffersNoCardMenu() async throws {
        let items = (0..<3).map { index in
            NativeVideoCardPresentation(
                id: "BV1Menu\(index)",
                title: "相关推荐 \(index)",
                coverURL: nil,
                avatarURL: nil,
                showsAvatar: false,
                footerLeadingText: "作者",
                accessibilityLabel: "相关推荐 \(index)"
            )
        }
        var requestedIDs: [String] = []
        let cardMenu: (NativeVideoCardPresentation) -> NativeVideoCardMenu? = { card in
            requestedIDs.append(card.id)
            return NativeVideoCardMenu(
                sections: [
                    [NativeVideoCardMenu.Item(id: "item", title: "菜单项", systemImage: "link") {}]
                ]
            )
        }
        let coordinator = NativeVideoShelfView.Coordinator(
            contentIdentity: "BV-parent",
            items: items,
            imagePipeline: NativeVideoShelfPendingImageLoader(),
            reduceMotion: true,
            isInteractionEnabled: false,
            onSelect: { _ in },
            cardMenu: cardMenu
        )
        let scrollView = coordinator.makeScrollView()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 300),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = scrollView
        defer {
            coordinator.reset()
            window.contentView = NSView()
        }
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        scrollView.layoutSubtreeIfNeeded()
        let collectionView = try #require(
            scrollView.documentView as? NativeVideoCardCollectionView
        )
        let card = try #require(
            collectionView.visibleItems().first { $0.representedObject as? String == "BV1Menu0" }?
                .view
        )

        #expect(collectionView.cardMenu?("BV1Menu0") == nil)
        #expect(card.accessibilityCustomActions()?.isEmpty ?? true)
        #expect(requestedIDs.isEmpty)

        coordinator.update(
            contentIdentity: "BV-parent",
            items: items,
            reduceMotion: true,
            isInteractionEnabled: true,
            onSelect: { _ in },
            cardMenu: cardMenu
        )

        #expect(collectionView.cardMenu?("BV1Menu0") != nil)
        #expect(card.accessibilityCustomActions()?.map(\.name) == ["菜单项"])
    }

    @MainActor
    private static func logicalOffset(of scrollView: NSScrollView) -> CGFloat {
        NativeVideoScrollCoordinateSpace.logicalOffset(
            physicalOffset: scrollView.contentView.bounds.origin.x,
            leadingInset: scrollView.contentInsets.left
        )
    }
}

/// 永不完成的取图替身：每次加载记一条“开始”，被取消时记一条“取消”，用来观察卡片的在途请求。
private final class NativeVideoShelfPendingImageLoader: NativeVideoImageLoading {
    enum Event: Equatable {
        case started(URL)
        case cancelled(URL)
    }

    let events: AsyncStream<Event>
    private let continuation: AsyncStream<Event>.Continuation

    init() {
        (events, continuation) = AsyncStream.makeStream()
    }

    func cachedImage(for url: URL, kind: NativeVideoCardImageKind) -> CGImage? {
        nil
    }

    func image(for url: URL, kind: NativeVideoCardImageKind) async -> NativeVideoCardImage? {
        continuation.yield(.started(url))
        await withTaskCancellationHandler {
            // 只为挂起到被取消，时长不参与判断。
            try? await Task.sleep(for: .seconds(3_600))
        } onCancel: {
            continuation.yield(.cancelled(url))
        }
        return nil
    }
}

@MainActor
private final class NativeVideoShelfFocusViewForTesting: NSView {
    override var acceptsFirstResponder: Bool { true }
}
