import AppKit
import BiliUI
import SwiftUI

/// 各来源共用的原生卡片网格，按卡片种类 `Kind` 渲染（视频卡片 `NativeVideoGridView`、人物卡片
/// `NativeGridView<NativePersonCardKind>`），用 AppKit 的理由见 ARCHITECTURE「原生 AppKit 集合视图」。
///
/// 调用方是 Feature 的网格包装，所以是 `package`。只渲染调用方给的卡片、尾部状态与回顶请求；
/// 内容、分页与选择的意图归调用方，滚动位置、回顶请求与取图 port 来自 App 窗口的
/// `NativeVideoGridHostContext`。滚动位置经 binding 双向同步，回顶请求经 `scrollReset` 握手确认。
/// 不可激活的卡片（`NativeGridCardPresentation.isActivatable` 为 false）不能被鼠标选中或按下高亮，点击、回车、空格与
/// 读屏按下都不回调 `onSelect`；键盘方向键仍可把选择停在上面。`cardMenu` 是来源按卡片给出的菜单
/// （`NativeVideoCardMenu`），右键与读屏操作共用。`bottomInset` 是末行下方为悬浮控件（收藏夹的页码条）额外留出的
/// 高度，布局与内容高度共用这个值。列数、卡片尺寸与间距取 `Kind.geometry`。
package struct NativeGridView<Kind: NativeGridCardKind>: NSViewRepresentable {
    package typealias Presentation = Kind.Item.Presentation

    let items: [Presentation]
    @Binding var scrollOffsetY: CGFloat
    let accessibilityLabel: String
    let tailState: NativeVideoGridTailState
    let bottomInset: CGFloat
    let decorations: NativeVideoGridDecorations
    @Binding var scrollReset: NativeVideoGridScrollResetState
    let imagePipeline: any NativeVideoImageLoading
    let actions: NativeGridActions<Presentation>
    let retention: NativeVideoGridRetention

    package init(
        items: [Presentation],
        accessibilityLabel: String,
        tailState: NativeVideoGridTailState,
        bottomInset: CGFloat = 0,
        decorations: NativeVideoGridDecorations = .none,
        host: NativeVideoGridHostContext,
        onNearEnd: @escaping () -> Void,
        onSelect: @escaping (String) -> Void,
        cardMenu: @escaping (Presentation) -> NativeVideoCardMenu?
    ) {
        self.items = items
        _scrollOffsetY = host.scrollOffsetY
        self.accessibilityLabel = accessibilityLabel
        self.tailState = tailState
        self.bottomInset = bottomInset
        self.decorations = decorations
        _scrollReset = host.scrollReset
        imagePipeline = host.imageLoader
        retention = host.retention
        actions = NativeGridActions(
            onNearEnd: onNearEnd,
            onSelect: onSelect,
            cardMenu: cardMenu
        )
    }

    /// 网格的唯一 owner：滚动视图与它的 clip view、集合视图、diffable 数据源、通知观察、悬停与滚动／分页状态。
    ///
    /// 不拥有图片管线（由窗口关闭），也不拥有卡片的外观、读屏描述与取图（归 `Kind.Item`）。由窗口保活
    /// （`NativeVideoGridRetainer`）留住时，`dismantleNSView` 调 `detach()`：视图与状态都留着，再次 `makeNSView`
    /// 时 `attachScrollView()` 交回同一个滚动视图。不保活时 `dismantleNSView` 调 `reset()`，保活容器丢弃已摘下的
    /// 网格时也调它，不可逆：先记录并同步最后的滚动位置（置位 `isReset` 后 `persistScrollOffset` 直接返回），再移除
    /// 观察并清空回调。
    /// 之后 `update`、滚动与翻页判断按 `isReset` 返回；已排队的预备区域刷新靠 `window != nil` 兜底。在途差异动画的
    /// 完成回调只撤销 clip view 的动画计数，不回到 Coordinator，拆除后无须作废。
    ///
    /// 集合视图的委托方法（`NSCollectionViewDelegate`）只能写在类的主体里：泛型类的扩展不能有 `@objc` 成员。
    @MainActor
    package final class Coordinator: NSObject, NSCollectionViewDelegate,
        NativeGridRetainableCoordinator
    {
        typealias Presentation = Kind.Item.Presentation

        let scrollView = NativeVideoGridScrollView()
        let clipView = NativeVideoGridClipView()
        let collectionView = NativeVideoCollectionView(geometry: Kind.geometry)
        /// 组合布局：section provider 按容器宽度重算这一节，宽度一变由系统自己失效重排，卡片尺寸从不落后于视口宽度。
        ///
        /// 不用流式布局加 `sizeForItemAt`：流式布局在宽度变化时先按旧卡片尺寸重排，要等网格手动失效才换新尺寸，
        /// 两者之间按旧尺寸排出少一列的错列。provider 另外读 `bottomInset`，它不属于布局环境，变化时由 `update`
        /// 手动失效。
        lazy var layout = NSCollectionViewCompositionalLayout {
            [weak self] _, environment in
            Kind.geometry.layoutSection(
                forWidth: environment.container.effectiveContentSize.width,
                bottomInset: self?.bottomInset ?? 0,
                topInset: self?.decorationHost.topInset ?? 0
            )
        }
        var images: NativeVideoGridHeldImages
        var dataSource: NSCollectionViewDiffableDataSource<Int, String>?
        var contents: NativeCardContents<Presentation>
        var accessibilityLabel: String
        var tailState: NativeVideoGridTailState
        /// 末行下方额外留出的高度，section provider 读它；变化时手动失效布局并重排 document。
        var bottomInset: CGFloat
        /// 顶部附加视图与「返回顶部」；它的 `topInset` 与 `bottomInset` 一样由 section provider 读取。
        let decorationHost = NativeVideoGridDecorationHost()
        /// 以已确认的回顶 ID 起步，每个新的 `requestID` 只消费一次：网格重建后仍会执行未确认的请求。
        var scrollResetGate: NativeVideoGridScrollResetGate
        var nearEndPagination = NearEndPagination<UInt64>(
            tailChangeInsideThreshold: .rearms
        )
        var onScroll: (CGFloat) -> Void
        var onAcknowledgeScrollReset: (UInt64) -> Void
        var actions: NativeGridActions<Presentation>
        var observers = NativeVideoNotificationObservers()
        /// 待应用的逻辑偏移：初次恢复、回顶请求、外部请求，以及整体替换时 `topPin` 保持置顶或锚点卡片已不在
        /// 新内容里（后两者都回到 0）；视口可渲染时应用并清空，非 nil 期间不记录滚动、不判断翻页。
        var pendingRestoreOffsetY: CGFloat?
        /// 回顶真正落地后才经 `onAcknowledgeScrollReset` 确认的请求 ID；非 nil 时忽略外部偏移请求。
        var pendingScrollResetAcknowledgementID: UInt64?
        var retainedScrollOffset: NativeVideoScrollOffsetRetention
        var scrollBindingBridge: NativeVideoScrollBindingBridge
        let hover = NativeVideoHoverTracker()
        /// 最近一次可渲染的视口尺寸；nil 表示当前没有可渲染的排版（初次、视口过窄或已拆除），锚点、恢复与
        /// 翻页判断都等它。
        var lastViewportSize: NSSize?
        /// 内容身份或 `bottomInset` 变了、还没有按当前视口重排 document 时为 true：下一次重排即使视口没变也排一遍并按
        /// 锚点恢复；视口不可渲染时也置位，等它重新可渲染。
        var documentNeedsLayout = true
        /// 用户最后看到的视野首卡，视口尺寸变化与整体替换都按它恢复位置，恢复后不重新捕获：连续宽度
        /// 变化中逐帧重新捕获会让首卡逐行漂移。
        ///
        /// 捕获点：记录到一次滚动（不在视口尺寸过渡或重排 document 中）、应用待恢复偏移、整体替换没能按它恢复，
        /// 以及它缺失或卡片已不在内容里时在重排结束后补捕。纯删除删掉它时由后继接替
        /// （`NativeVideoGridUpdatePlan.retainedAnchor`）。`reset()` 清空。
        var viewportAnchor: NativeVideoGridViewportAnchor?
        /// 不在程序设置偏移、也没有待恢复偏移时，每记录一次 bounds 变化就加一（含用户滚动、重排 document 时
        /// AppKit 的夹取与 `reset()` 时的记录；视口尺寸过渡中的 bounds 变化不记录）；`topPin` 用它判断其间是否又有滚动。
        var scrollGeneration: UInt64 = 0
        var topPin = NativeVideoGridTopPin()
        /// 程序设置偏移期间为 true，让随之而来的 bounds 通知不被记成用户滚动。
        var isApplyingRestoration = false
        var isLiveScrolling = false
        /// 重排 document 期间为 true：其间到来的视口回调不再重排，也不判断翻页。
        var isResizingDocument = false
        var isReset = false
        /// 由 `NativeVideoGridRetainer` 留住时拆除走 `detach()` 而不是 `reset()`。
        ///
        /// 只由保活容器设置，丢弃时清除。
        var isRetained = false
        /// 已建好滚动视图、当前不在 SwiftUI 层级里；`attachScrollView()` 挂回时清除。
        var isDetached = false
        var hasMadeScrollView = false

        init(
            items: [Presentation],
            initialScrollOffsetY: CGFloat,
            accessibilityLabel: String,
            tailState: NativeVideoGridTailState,
            bottomInset: CGFloat,
            decorations: NativeVideoGridDecorations,
            scrollResetRequestID: UInt64,
            acknowledgedScrollResetRequestID: UInt64,
            imagePipeline: any NativeVideoImageLoading,
            onScroll: @escaping (CGFloat) -> Void,
            onAcknowledgeScrollReset: @escaping (UInt64) -> Void,
            actions: NativeGridActions<Presentation>
        ) {
            contents = NativeCardContents(items)
            self.accessibilityLabel = accessibilityLabel
            self.tailState = tailState
            self.bottomInset = bottomInset
            _ = decorationHost.update(decorations)
            scrollResetGate = NativeVideoGridScrollResetGate(
                initialRequestID: acknowledgedScrollResetRequestID
            )
            images = NativeVideoGridHeldImages(pipeline: imagePipeline)
            self.onScroll = onScroll
            self.onAcknowledgeScrollReset = onAcknowledgeScrollReset
            self.actions = actions
            retainedScrollOffset = NativeVideoScrollOffsetRetention(
                initialOffsetY: initialScrollOffsetY
            )
            scrollBindingBridge = NativeVideoScrollBindingBridge(
                initialOffsetY: initialScrollOffsetY
            )
            pendingRestoreOffsetY = retainedScrollOffset.offsetY
            if scrollResetGate.consume(scrollResetRequestID) {
                pendingRestoreOffsetY = 0
                pendingScrollResetAcknowledgementID = scrollResetRequestID
            }
        }

        /// 鼠标选中只接受可激活的卡片；键盘方向键直接设置选择、不经这里，焦点仍可停在不可用卡片上。
        package func collectionView(
            _ collectionView: NSCollectionView,
            shouldSelectItemsAt indexPaths: Set<IndexPath>
        ) -> Set<IndexPath> {
            contents.activatableIndexPaths(in: indexPaths)
        }

        /// 按下高亮只给可激活的卡片，其他高亮状态照常。
        package func collectionView(
            _ collectionView: NSCollectionView,
            shouldChangeItemsAt indexPaths: Set<IndexPath>,
            to highlightState: NSCollectionViewItem.HighlightState
        ) -> Set<IndexPath> {
            highlightState == .forSelection
                ? contents.activatableIndexPaths(in: indexPaths)
                : indexPaths
        }

        package func collectionView(
            _ collectionView: NSCollectionView,
            didEndDisplaying item: NSCollectionViewItem,
            forRepresentedObjectAt indexPath: IndexPath
        ) {
            guard let item = item as? Kind.Item else { return }
            guard collectionView.indexPath(for: item) == nil else { return }
            hover.itemDidEndDisplaying(item)
        }
    }
}

/// 视频卡片网格：首页推荐、热门、搜索、观看历史、稍后再看、收藏夹与 UP 主空间的投稿都用它。
package typealias NativeVideoGridView = NativeGridView<NativeVideoCardKind>
