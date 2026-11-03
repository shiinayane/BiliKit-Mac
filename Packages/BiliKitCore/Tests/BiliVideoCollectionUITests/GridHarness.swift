import AppKit
import Testing

@testable import BiliVideoCollectionUI

/// 带工具栏（顶部 contentInsets）的真实窗口里驱动网格 Coordinator；视口尺寸直接设到滚动视图上，经窗口布局同步送达。
///
/// 本测试 target 里驱动真实网格的 Suite 共用这一份。窗口不上屏、不进入 AppKit 事件循环。
@MainActor
final class GridHarness {
    struct VisibleCard: Equatable {
        let id: String
        let offsetFromViewportTop: CGFloat
    }

    static let defaultHeight: CGFloat = 700
    private static let windowSize = NSSize(width: 1_200, height: 1_100)

    private(set) var ids = (0..<300).map { "BV\($0)" }
    private(set) var nearEndRequests = 0
    /// 每次换内容都换尾标，让每一页都可以请求下一页。
    private var tailIdentity: UInt64 = 1
    private let coordinator: NativeVideoGridView.Coordinator
    private let window: NSWindow
    private let scrollView: NSScrollView
    private let collectionView: NSCollectionView

    init(width: CGFloat = 800, scrollerStyle: NSScroller.Style) async throws {
        window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.windowSize),
            styleMask: [.titled, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.toolbar = NSToolbar(identifier: "GridHarness")
        let coordinator = NativeVideoGridView.Coordinator(
            items: Self.presentations(for: ids),
            initialScrollOffsetY: 0,
            accessibilityLabel: "网格",
            tailState: Self.tailState(tailIdentity),
            bottomInset: 0,
            scrollResetRequestID: 0,
            acknowledgedScrollResetRequestID: 0,
            imagePipeline: StubCardImageLoader(),
            onScroll: { _ in },
            onAcknowledgeScrollReset: { _ in },
            actions: NativeVideoGridActions(
                onNearEnd: {},
                onSelect: { _ in },
                cardMenu: { _ in nil }
            )
        )
        self.coordinator = coordinator
        scrollView = coordinator.makeScrollView()
        let contentView = try #require(window.contentView)
        contentView.addSubview(scrollView)
        collectionView = try #require(scrollView.documentView as? NSCollectionView)
        // 先换上计数的翻页回调，再排版，首次排版的翻页判断也算在内。
        replaceItems(with: ids)
        setViewport(width: width, height: Self.defaultHeight)
        // makeScrollView 把首次排版与恢复排到下一轮主队列；等它跑完再开始操作。
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        // 滚动条样式最后才设，且只重新 tile、不再 layout：系统切换样式或传统滚动条随内容出现时就是这样，视口宽度在
        // layout 之外改变（CI 默认传统滚动条）。样式由测试指定，不取运行机器的偏好。
        scrollView.scrollerStyle = scrollerStyle
        scrollView.tile()
    }

    isolated deinit {
        coordinator.reset()
        window.contentView = nil
    }

    var maximumLogicalOffset: CGFloat {
        NativeVideoScrollCoordinateSpace.maximumLogicalOffset(
            documentLength: collectionView.frame.height,
            viewportLength: scrollView.contentSize.height,
            leadingInset: scrollView.contentInsets.top,
            trailingInset: scrollView.contentInsets.bottom
        )
    }

    /// 像用户滚动一样直接移动 clip view，网格经 bounds 通知记录；随后的布局让集合视图为新视野准备卡片。
    func scroll(toLogicalOffset offsetY: CGFloat) {
        scrollView.scrollVertically(
            toPhysicalOffset: NativeVideoScrollCoordinateSpace.physicalOffset(
                logicalOffset: offsetY,
                leadingInset: scrollView.contentInsets.top
            )
        )
        window.contentView?.layoutSubtreeIfNeeded()
    }

    /// 滚动视图贴着窗口顶边（工具栏之下），只改它自己的尺寸。
    func setViewport(width: CGFloat? = nil, height: CGFloat? = nil) {
        let size = NSSize(
            width: width ?? scrollView.frame.width,
            height: height ?? scrollView.frame.height
        )
        scrollView.frame = NSRect(
            x: 0,
            y: Self.windowSize.height - size.height,
            width: size.width,
            height: size.height
        )
        window.contentView?.layoutSubtreeIfNeeded()
    }

    /// 像来源刷新或翻页一样整体换内容（含严格尾部追加），并换上新尾标。
    func replaceItems(with ids: [String]) {
        self.ids = ids
        tailIdentity += 1
        coordinator.update(
            items: Self.presentations(for: ids),
            accessibilityLabel: "网格",
            tailState: Self.tailState(tailIdentity),
            bottomInset: 0,
            scrollResetRequestID: 0,
            requestedScrollOffsetY: 0,
            onScroll: { _ in },
            onAcknowledgeScrollReset: { _ in },
            actions: NativeVideoGridActions(
                onNearEnd: { [weak self] in self?.nearEndRequests += 1 },
                onSelect: { _ in },
                cardMenu: { _ in nil }
            )
        )
        window.contentView?.layoutSubtreeIfNeeded()
    }

    /// 与视野相交的最上一行里序号最小的卡片（独立于网格自己的取法）。
    func firstVisibleCard() -> VisibleCard? {
        let visible = collectionView.visibleRect
        return ids.indices
            .compactMap { item -> (Int, NSRect)? in
                guard
                    let frame = collectionView.collectionViewLayout?
                        .layoutAttributesForItem(at: IndexPath(item: item, section: 0))?.frame,
                    frame.intersects(visible)
                else { return nil }
                return (item, frame)
            }
            .min { ($0.1.minY, $0.0) < ($1.1.minY, $1.0) }
            .flatMap { card(ids[$0.0]) }
    }

    /// 首行卡片数：顶边与第一张卡片相同的卡片个数。
    func firstRowCardCount() -> Int {
        let minYs = ids.indices.prefix(8).compactMap {
            collectionView.collectionViewLayout?
                .layoutAttributesForItem(at: IndexPath(item: $0, section: 0))?.frame.minY
        }
        guard let first = minYs.first else { return 0 }
        return minYs.prefix { $0 == first }.count
    }

    /// 失败时帮助判断运行环境：缩放、滚动条样式、视口与 document 尺寸、首行张数。
    var diagnostics: String {
        let firstRow = ids.indices.prefix(8).compactMap {
            collectionView.collectionViewLayout?
                .layoutAttributesForItem(at: IndexPath(item: $0, section: 0))?.frame.minY
        }
        return "scale=\(window.backingScaleFactor) scroller=\(scrollView.scrollerStyle.rawValue)"
            + " frame=\(scrollView.frame.size) content=\(scrollView.contentSize)"
            + " insets=\(scrollView.contentInsets.top) document=\(collectionView.frame.size)"
            + " origin=\(scrollView.contentView.bounds.origin.y) firstRowsMinY=\(firstRow)"
    }

    /// 像从稍后再看移除卡片一样，只去掉这些位置上的卡片。
    func removeItems(at indices: [Int]) {
        let removed = Set(indices.map { ids[$0] })
        replaceItems(with: ids.filter { !removed.contains($0) })
    }

    /// 差异动画是否还在进行（完成回调尚未到）。
    var isAnimatingUpdate: Bool {
        (scrollView.contentView as? NativeVideoGridClipView)?.isAnimatingUpdate ?? false
    }

    var logicalOffset: CGFloat {
        NativeVideoScrollCoordinateSpace.logicalOffset(
            physicalOffset: scrollView.contentView.bounds.origin.y,
            leadingInset: scrollView.contentInsets.top
        )
    }

    /// 排版认为与视野相交的卡片数，与其中集合视图真正创建出来、在视图层级里的卡片数。
    func visibleCardCounts() -> (expected: Int, realized: Int) {
        let visible = collectionView.visibleRect
        let expected =
            (collectionView.collectionViewLayout?.layoutAttributesForElements(in: visible) ?? [])
            .filter { $0.representedElementCategory == .item && $0.frame.intersects(visible) }
            .count
        let realized = collectionView.visibleItems()
            .filter {
                $0.view.superview != nil && !$0.view.isHidden && $0.view.frame.intersects(visible)
            }
            .count
        return (expected, realized)
    }

    /// 卡片顶边到视口逻辑顶边（工具栏下沿）的距离。
    func card(_ id: String) -> VisibleCard? {
        guard
            let item = ids.firstIndex(of: id),
            let frame = collectionView.collectionViewLayout?
                .layoutAttributesForItem(at: IndexPath(item: item, section: 0))?.frame
        else { return nil }
        return VisibleCard(id: id, offsetFromViewportTop: frame.minY - logicalOffset)
    }

    private static func presentations(for ids: [String]) -> [NativeVideoCardPresentation] {
        ids.map { id in
            NativeVideoCardPresentation(
                id: id,
                title: "视频 \(id)",
                coverURL: nil,
                avatarURL: nil,
                showsAvatar: false,
                footerLeadingText: "UP",
                accessibilityLabel: "视频 \(id)"
            )
        }
    }

    private static func tailState(_ identity: UInt64) -> NativeVideoGridTailState {
        NativeVideoGridTailState(canLoadMore: true, tailIdentity: identity, isLoading: false)
    }
}
