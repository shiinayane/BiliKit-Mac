import AppKit
import SwiftUI
import Testing

@testable import BiliVideoCollectionUI

/// 保活的网格切走再切回时原样挂回：还是同一个滚动视图与集合视图，首张可见卡片与它到视野顶部的距离不变，离开期间
/// 视口宽度变了也一样；在 SwiftUI 里被拆除再出现时，卡片不重新取已经显示过的封面；窗口保活只复用同一内容最新的、
/// 已摘下的网格，丢弃后不再复用。
@Suite(.serialized, .timeLimit(.minutes(1)))
@MainActor
struct NativeVideoGridRetentionTests {
    @Test(arguments: [NSScroller.Style.overlay, .legacy], [nil, 1_120] as [CGFloat?])
    func detachedGridComesBackWithTheSameViewsAndFirstVisibleCard(
        scrollerStyle: NSScroller.Style,
        widthOnReturn: CGFloat?
    ) async throws {
        let grid = try await GridHarness(scrollerStyle: scrollerStyle)
        grid.scroll(toLogicalOffset: 6_000)
        let original = try #require(grid.firstVisibleCard())
        let originalScrollView = try #require(grid.collectionView.enclosingScrollView)

        grid.detach()
        let returned = try await grid.reattach(width: widthOnReturn)

        #expect(returned === originalScrollView)
        #expect(returned.documentView === grid.collectionView)
        let card = try #require(grid.card(original.id))
        #expect(
            abs(card.offsetFromViewportTop - original.offsetFromViewportTop) <= 1,
            "首卡 \(original.id) 原距离 \(original.offsetFromViewportTop)，现距离 \(card.offsetFromViewportTop)；\(grid.diagnostics)"
        )
    }

    /// 挂回后卡片不重新取已经显示过的封面。
    ///
    /// 替身没有缓存命中：窗口图片缓存可能已被别的来源挤掉（见 ARCHITECTURE「原生 AppKit 集合视图」），挂回后任何一张
    /// 重新请求加载，在真实 App 里都是先闪占位、重新下载。离开期间遇到内存压力时只释放留住的图：网格与位置照留，卡片
    /// 重新取图。
    @Test(arguments: [false, true])
    func gridSwitchedAwayInSwiftUIComesBackWithItsCovers(
        memoryPressureWhileAway: Bool
    ) async throws {
        let ids = (0..<300).map { "BV\($0)" }
        let image = try #require(Self.makeImage())
        let loader = StubCardImageLoader(
            loaded: Dictionary(
                uniqueKeysWithValues: ids.map {
                    (Self.coverURL($0), NativeVideoCardImage(image: image, fadesIn: true))
                }
            )
        )
        let source = SwitchableGridSource()
        let retainer = NativeVideoGridRetainer()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_000, height: 800),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = NSHostingView(
            rootView: SwitchableGridRoot(
                source: source,
                items: ids.map(Self.presentation),
                host: NativeVideoGridHostContext(
                    scrollOffsetY: Binding(get: { source.offsetY }, set: { source.offsetY = $0 }),
                    scrollReset: Binding(get: { source.reset }, set: { source.reset = $0 }),
                    imageLoader: loader,
                    retention: NativeVideoGridRetention(
                        retainer: retainer,
                        key: "home",
                        contentIdentity: nil
                    )
                )
            )
        )
        defer {
            retainer.discardAll()
            window.contentView = nil
        }
        let scrollView = try #require(await Self.waitForGrid(in: window))
        let collectionView = try #require(scrollView.documentView as? NativeVideoCollectionView)
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: 3_000))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        window.contentView?.layoutSubtreeIfNeeded()
        #expect(
            await Self.waitUntil {
                (collectionView.firstVisibleItem()?.indexPath?.item ?? 0) > 0
                    && Self.showsCovers(collectionView)
            }
        )
        let original = try #require(collectionView.firstVisibleItem()?.indexPath)
        let requestsBeforeSwitch = loader.loadRequestCount

        source.showsGrid = false
        #expect(await Self.waitUntil { scrollView.window == nil })
        if memoryPressureWhileAway { retainer.releaseHeldImages() }
        source.showsGrid = true
        let returned = try #require(await Self.waitForGrid(in: window))

        #expect(returned === scrollView)
        #expect(collectionView.firstVisibleItem()?.indexPath == original)
        if memoryPressureWhileAway {
            #expect(await Self.waitUntil { Self.showsCovers(collectionView) })
            #expect(loader.loadRequestCount > requestsBeforeSwitch)
        } else {
            #expect(Self.showsCovers(collectionView))
            #expect(loader.loadRequestCount == requestsBeforeSwitch)
        }
    }

    /// 同一来源、同一内容身份、已摘下的网格才复用；同时有两个实例时留下新的；换内容身份或丢弃后不再复用。
    @Test
    func retainerReusesOnlyTheLatestDetachedGridOfTheSameContent() {
        let retainer = NativeVideoGridRetainer()
        func lookup(_ folder: Int64?) -> NativeVideoGridView.Coordinator {
            let retention = NativeVideoGridRetention(
                retainer: retainer,
                key: "favorites",
                contentIdentity: folder
            )
            return retainer.coordinator(for: retention, make: Self.makeCoordinator)
        }
        let first = lookup(1)
        _ = first.attachScrollView()

        // 仍挂着时同一来源再要一个：另建，不把同一个滚动视图挂到两处；之后留下的是新的这个。
        let concurrent = lookup(1)
        #expect(concurrent !== first)
        _ = concurrent.attachScrollView()
        first.detach()
        concurrent.detach()
        #expect(lookup(1) === concurrent)

        let otherFolder = lookup(2)
        #expect(otherFolder !== concurrent)
        _ = otherFolder.attachScrollView()
        otherFolder.detach()
        #expect(lookup(2) === otherFolder)

        retainer.discardAll()
        #expect(lookup(2) !== otherFolder)
    }

    private static func coverURL(_ id: String) -> URL {
        URL(string: "https://i0.hdslb.com/bfs/archive/\(id).jpg")!
    }

    private static func presentation(_ id: String) -> NativeVideoCardPresentation {
        NativeVideoCardPresentation(
            id: id,
            title: "视频 \(id)",
            coverURL: coverURL(id),
            avatarURL: nil,
            showsAvatar: false,
            footerLeadingText: "UP",
            accessibilityLabel: "视频 \(id)"
        )
    }

    /// 实例化的卡片都已显示封面。
    private static func showsCovers(_ collectionView: NSCollectionView) -> Bool {
        let cards = collectionView.visibleVideoCards
        return !cards.isEmpty && cards.allSatisfy { !$0.displayedImages.isEmpty }
    }

    /// 网格挂进窗口、排出卡片，且挂载时排到下一轮的排版与恢复已经跑完。
    private static func waitForGrid(in window: NSWindow) async -> NSScrollView? {
        var found: NSScrollView?
        guard
            await waitUntil({
                found = window.contentView.flatMap(gridScrollView(in:))
                let collectionView = found?.documentView as? NSCollectionView
                return collectionView.map { !$0.visibleItems().isEmpty } ?? false
            })
        else { return nil }
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        return found
    }

    private static func gridScrollView(in view: NSView) -> NSScrollView? {
        if let scrollView = view as? NativeVideoGridScrollView { return scrollView }
        return view.subviews.lazy.compactMap(gridScrollView(in:)).first
    }

    /// 让出主线程直到条件成立；时长只作超时。
    private static func waitUntil(_ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while true {
            if condition() { return true }
            guard ContinuousClock.now < deadline else { return false }
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
        }
    }

    private static func makeImage() -> CGImage? {
        CGContext(
            data: nil,
            width: 2,
            height: 2,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )?.makeImage()
    }

    private static func makeCoordinator() -> NativeVideoGridView.Coordinator {
        NativeVideoGridView.Coordinator(
            items: GridHarness.presentations(for: ["BV1", "BV2"]),
            initialScrollOffsetY: 0,
            accessibilityLabel: "网格",
            tailState: GridHarness.tailState(1),
            bottomInset: 0,
            scrollResetRequestID: 0,
            acknowledgedScrollResetRequestID: 0,
            imagePipeline: StubCardImageLoader(),
            onScroll: { _ in },
            onAcknowledgeScrollReset: { _ in },
            actions: .inert
        )
    }
}

/// 像侧栏切换来源一样让网格离开、回到 SwiftUI 层级。
@MainActor
@Observable
private final class SwitchableGridSource {
    var showsGrid = true
    var offsetY: CGFloat = 0
    var reset = NativeVideoGridScrollResetState()
}

private struct SwitchableGridRoot: View {
    let source: SwitchableGridSource
    let items: [NativeVideoCardPresentation]
    let host: NativeVideoGridHostContext

    var body: some View {
        if source.showsGrid {
            NativeVideoGridView(
                items: items,
                accessibilityLabel: "网格",
                tailState: GridHarness.tailState(1),
                host: host,
                onNearEnd: {},
                onSelect: { _ in },
                cardMenu: { _ in nil }
            )
        } else {
            Color.clear
        }
    }
}
