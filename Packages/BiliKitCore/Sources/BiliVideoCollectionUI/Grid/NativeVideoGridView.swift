import AppKit
import BiliUI
import SwiftUI

/// 首页推荐、热门、搜索、观看历史、稍后再看与收藏夹共用的原生视频网格，用 AppKit 的理由见 ARCHITECTURE「原生 AppKit 集合视图」。
///
/// 调用方是 Browse 与 Library 的网格包装，所以是 `package`。只渲染调用方给的卡片、尾部状态与回顶请求；
/// 内容、分页与选择的意图归调用方，滚动位置、回顶请求与取图 port 来自 App 窗口的
/// `NativeVideoGridHostContext`。滚动位置经 binding 双向同步，回顶请求经 `scrollReset` 握手确认。
/// 不可用卡片（`NativeVideoCardAvailability.unavailable`）不能被鼠标选中或按下高亮，点击、回车、空格与读屏按下都不回调
/// `onSelect`；键盘方向键仍可把选择停在上面。`cardMenu` 是来源按卡片给出的菜单（`NativeVideoCardMenu`），右键与读屏
/// 操作共用。`bottomInset` 是末行下方为悬浮控件（收藏夹的页码条）额外留出的高度，
/// 布局与内容高度共用这个值。
package struct NativeVideoGridView: NSViewRepresentable {
    let items: [NativeVideoCardPresentation]
    @Binding var scrollOffsetY: CGFloat
    let accessibilityLabel: String
    let tailState: NativeVideoGridTailState
    let bottomInset: CGFloat
    @Binding var scrollReset: NativeVideoGridScrollResetState
    let imagePipeline: any NativeVideoImageLoading
    let actions: NativeVideoGridActions

    package init(
        items: [NativeVideoCardPresentation],
        accessibilityLabel: String,
        tailState: NativeVideoGridTailState,
        bottomInset: CGFloat = 0,
        host: NativeVideoGridHostContext,
        onNearEnd: @escaping () -> Void,
        onSelect: @escaping (String) -> Void,
        cardMenu: @escaping (NativeVideoCardPresentation) -> NativeVideoCardMenu?
    ) {
        self.items = items
        _scrollOffsetY = host.scrollOffsetY
        self.accessibilityLabel = accessibilityLabel
        self.tailState = tailState
        self.bottomInset = bottomInset
        _scrollReset = host.scrollReset
        imagePipeline = host.imageLoader
        actions = NativeVideoGridActions(
            onNearEnd: onNearEnd,
            onSelect: onSelect,
            cardMenu: cardMenu
        )
    }

    package func makeCoordinator() -> Coordinator {
        Coordinator(
            items: items,
            initialScrollOffsetY: scrollOffsetY,
            accessibilityLabel: accessibilityLabel,
            tailState: tailState,
            bottomInset: bottomInset,
            scrollResetRequestID: scrollReset.requestID,
            acknowledgedScrollResetRequestID: scrollReset.acknowledgedRequestID,
            imagePipeline: imagePipeline,
            onScroll: { scrollOffsetY = $0 },
            onAcknowledgeScrollReset: {
                scrollReset.acknowledgedRequestID = $0
            },
            actions: actions
        )
    }

    package func makeNSView(context: Context) -> NSScrollView {
        context.coordinator.makeScrollView()
    }

    package func updateNSView(_ view: NSScrollView, context: Context) {
        context.coordinator.update(
            items: items,
            accessibilityLabel: accessibilityLabel,
            tailState: tailState,
            bottomInset: bottomInset,
            scrollResetRequestID: scrollReset.requestID,
            requestedScrollOffsetY: scrollOffsetY,
            onScroll: { scrollOffsetY = $0 },
            onAcknowledgeScrollReset: {
                scrollReset.acknowledgedRequestID = $0
            },
            actions: actions
        )
    }

    package static func dismantleNSView(
        _ view: NSScrollView,
        coordinator: Coordinator
    ) {
        coordinator.reset()
    }

    /// 网格的唯一 owner：滚动视图与它的 clip view、集合视图、diffable 数据源、通知观察、悬停与滚动／分页状态。
    ///
    /// 不拥有图片管线（由窗口关闭）。`dismantleNSView` 调 `reset()`：先记录并同步最后的滚动位置（置位
    /// `isReset` 后 `persistScrollOffset` 直接返回），再移除观察并清空回调。之后 `update`、滚动与翻页判断按
    /// `isReset` 返回；已排队的预备区域刷新靠 `window != nil` 兜底。在途差异动画的完成回调只撤销 clip view 的
    /// 动画计数，不回到 Coordinator，拆除后无须作废。
    @MainActor
    package final class Coordinator: NSObject, NSCollectionViewDelegateFlowLayout {
        private let scrollView = NativeVideoGridScrollView()
        private let clipView = NativeVideoGridClipView()
        private let collectionView = NativeVideoCollectionView()
        private let layout = NSCollectionViewFlowLayout()
        private let imagePipeline: any NativeVideoImageLoading
        private var dataSource: NSCollectionViewDiffableDataSource<Int, String>?
        private var contents: NativeVideoCardContents
        private var accessibilityLabel: String
        private var tailState: NativeVideoGridTailState
        /// 末行下方额外留出的高度；变化时重排 document。
        private var bottomInset: CGFloat
        /// 以已确认的回顶 ID 起步，每个新的 `requestID` 只消费一次：网格重建后仍会执行未确认的请求。
        private var scrollResetGate: NativeVideoGridScrollResetGate
        private var nearEndPagination = NearEndPagination<UInt64>(
            tailChangeInsideThreshold: .rearms
        )
        private var onScroll: (CGFloat) -> Void
        private var onAcknowledgeScrollReset: (UInt64) -> Void
        private var actions: NativeVideoGridActions
        private var observers = NativeVideoNotificationObservers()
        /// 待应用的逻辑偏移：初次恢复、回顶请求、外部请求，以及整体替换时 `topPin` 保持置顶或锚点卡片已不在
        /// 新内容里（后两者都回到 0）；视口可渲染时应用并清空，非 nil 期间不记录滚动、不判断翻页。
        private var pendingRestoreOffsetY: CGFloat?
        /// 回顶真正落地后才经 `onAcknowledgeScrollReset` 确认的请求 ID；非 nil 时忽略外部偏移请求。
        private var pendingScrollResetAcknowledgementID: UInt64?
        private var retainedScrollOffset: NativeVideoScrollOffsetRetention
        private var scrollBindingBridge: NativeVideoScrollBindingBridge
        private let hover = NativeVideoHoverTracker()
        /// 最近一次可渲染的视口尺寸；nil 表示当前没有可渲染的排版（初次、视口过窄或已拆除），锚点、恢复与
        /// 翻页判断都等它。
        private var lastViewportSize: NSSize?
        private var documentLayoutNeedsInvalidation = true
        /// 用户最后看到的视野首卡，视口尺寸变化与整体替换都按它恢复位置，恢复后不重新捕获：连续宽度
        /// 变化中逐帧重新捕获会让首卡逐行漂移。
        ///
        /// 捕获点：记录到一次滚动（不在视口尺寸过渡或重排 document 中）、应用待恢复偏移、整体替换没能按它恢复，
        /// 以及它缺失或卡片已不在内容里时在重排结束后补捕。纯删除删掉它时由后继接替
        /// （`NativeVideoGridUpdatePlan.retainedAnchor`）。`reset()` 清空。
        private var viewportAnchor: NativeVideoGridViewportAnchor?
        /// 不在程序设置偏移、也没有待恢复偏移时，每记录一次 bounds 变化就加一（含用户滚动、重排 document 时
        /// AppKit 的夹取与 `reset()` 时的记录；视口尺寸过渡中的 bounds 变化不记录）；`topPin` 用它判断其间是否又有滚动。
        private var scrollGeneration: UInt64 = 0
        private var topPin = NativeVideoGridTopPin()
        /// 程序设置偏移期间为 true，让随之而来的 bounds 通知不被记成用户滚动。
        private var isApplyingRestoration = false
        private var isLiveScrolling = false
        /// 重排 document 期间为 true：其间到来的视口回调不再重排，也不判断翻页。
        private var isResizingDocument = false
        private var isReset = false

        init(
            items: [NativeVideoCardPresentation],
            initialScrollOffsetY: CGFloat,
            accessibilityLabel: String,
            tailState: NativeVideoGridTailState,
            bottomInset: CGFloat,
            scrollResetRequestID: UInt64,
            acknowledgedScrollResetRequestID: UInt64,
            imagePipeline: any NativeVideoImageLoading,
            onScroll: @escaping (CGFloat) -> Void,
            onAcknowledgeScrollReset: @escaping (UInt64) -> Void,
            actions: NativeVideoGridActions
        ) {
            contents = NativeVideoCardContents(items)
            self.accessibilityLabel = accessibilityLabel
            self.tailState = tailState
            self.bottomInset = bottomInset
            scrollResetGate = NativeVideoGridScrollResetGate(
                initialRequestID: acknowledgedScrollResetRequestID
            )
            self.imagePipeline = imagePipeline
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

        func makeScrollView() -> NSScrollView {
            layout.minimumInteritemSpacing = NativeVideoGridGeometry.horizontalSpacing
            layout.minimumLineSpacing = NativeVideoGridGeometry.verticalSpacing
            layout.sectionInset = sectionInset
            collectionView.collectionViewLayout = layout
            collectionView.delegate = self
            collectionView.isSelectable = true
            collectionView.allowsMultipleSelection = false
            collectionView.backgroundColors = [.clear]
            collectionView.onActivateSelection = { [weak self] id in
                self?.activate(id)
            }
            collectionView.cardMenu = { [weak self] id in
                guard let self, !self.isReset, let card = self.contents[id] else { return nil }
                return self.actions.cardMenu(card)
            }
            collectionView.register(
                NativeVideoCollectionItem.self,
                forItemWithIdentifier: .nativeVideoCard
            )

            dataSource = NativeVideoCardDataSource.make(
                collectionView: collectionView,
                presentation: { [weak self] id in self?.contents[id] },
                configure: { [weak self] item, presentation in
                    self?.configure(item, with: presentation)
                },
                showsKeyboardSelection: { [weak collectionView] in
                    collectionView?.showsKeyboardSelection == true
                }
            )

            // clip view 先于 document 装上：document 装进去时就挂在补建卡片的 clip view 下。
            scrollView.contentView = clipView
            scrollView.documentView = collectionView
            scrollView.hasVerticalScroller = true
            scrollView.autohidesScrollers = true
            scrollView.drawsBackground = false
            scrollView.contentView.postsBoundsChangedNotifications = true
            scrollView.onViewportLayout = { [weak self] in
                // 重排 document 中途的 tile 不嵌套处理，视口在重排中又变了由 `resizeDocument` 自己再排一遍。
                guard let self, !self.isResizingDocument, self.pendingViewportChange.any
                else { return }
                self.resizeDocument()
                self.restorePendingOffsetIfPossible()
                self.viewportDidChange()
            }
            scrollView.onContentInsetsChange = { [weak self] oldInsets, newInsets in
                self?.contentInsetsDidChange(from: oldInsets, to: newInsets)
            }
            collectionView.setAccessibilityLabel(accessibilityLabel)

            observers.observeScrolling(of: scrollView) { [weak self] in self?.didScroll() }
            observers.observe(
                NSScrollView.didEndLiveScrollNotification,
                object: scrollView
            ) { [weak self] in
                self?.isLiveScrolling = false
                self?.persistScrollOffset()
            }
            observers.observe(
                NSScrollView.willStartLiveScrollNotification,
                object: scrollView
            ) { [weak self] in
                self?.isLiveScrolling = true
                self?.nearEndPagination.releaseBackpressure()
            }
            observers.observeAccessibilityDisplayOptions { [weak collectionView] in
                collectionView?.refreshVisibleCardAppearance()
            }

            applySnapshot()
            // 返回时滚动视图还没装进 SwiftUI 的层级；下一轮再排版、恢复位置并判断翻页。
            DispatchQueue.main.async { [weak self] in
                self?.resizeDocument()
                self?.restorePendingOffsetIfPossible()
                self?.viewportDidChange()
            }
            return scrollView
        }

        func update(
            items: [NativeVideoCardPresentation],
            accessibilityLabel: String,
            tailState: NativeVideoGridTailState,
            bottomInset: CGFloat,
            scrollResetRequestID: UInt64,
            requestedScrollOffsetY: CGFloat,
            onScroll: @escaping (CGFloat) -> Void,
            onAcknowledgeScrollReset: @escaping (UInt64) -> Void,
            actions: NativeVideoGridActions
        ) {
            guard !isReset else { return }
            self.onScroll = onScroll
            self.onAcknowledgeScrollReset = onAcknowledgeScrollReset
            self.actions = actions
            self.tailState = tailState
            if self.bottomInset != bottomInset {
                self.bottomInset = bottomInset
                layout.sectionInset = sectionInset
                documentLayoutNeedsInvalidation = true
                resizeDocument()
            }
            // binding 每次都先交给 bridge：滤掉网格刚同步出去的当前值的回声，以及同一轮更新里交回的、
            // 被它替换掉的上一个值（`supersededOffsetY`）。回顶请求优先于外部偏移。
            let requestedExternalOffset = scrollBindingBridge.takeExternalRequest(
                requestedScrollOffsetY
            )
            if scrollResetGate.consume(scrollResetRequestID) {
                pendingRestoreOffsetY = 0
                pendingScrollResetAcknowledgementID = scrollResetRequestID
            } else if pendingScrollResetAcknowledgementID == nil,
                let requestedExternalOffset
            {
                pendingRestoreOffsetY = requestedExternalOffset
            }
            if self.accessibilityLabel != accessibilityLabel {
                self.accessibilityLabel = accessibilityLabel
                collectionView.setAccessibilityLabel(accessibilityLabel)
            }

            let updatedContents = NativeVideoCardContents(items)
            let updatePlan = NativeVideoGridUpdatePlan(
                previousIDs: contents.orderedIDs,
                previousContents: contents.byID,
                updatedIDs: updatedContents.orderedIDs,
                updatedContents: updatedContents.byID
            )
            var restoresAnchor = false
            if updatePlan.restoresViewportAnchor, pendingRestoreOffsetY == nil {
                if topPin.keepsTop(atScrollGeneration: scrollGeneration) {
                    pendingRestoreOffsetY = 0
                } else if let anchor = viewportAnchor {
                    if let retainedAnchor = updatePlan.retainedAnchor(anchor) {
                        viewportAnchor = retainedAnchor
                        restoresAnchor = true
                    } else {
                        pendingRestoreOffsetY = 0
                    }
                }
            }
            contents = updatedContents

            if updatePlan.identityChanged, !updatePlan.isStrictTailAppend {
                // 内容整体替换后，旧手势留下的背压不再适用。
                nearEndPagination.releaseBackpressure()
            }
            if updatePlan.identityChanged {
                documentLayoutNeedsInvalidation = true
                // `apply` 返回时排版已是新内容，差异动画只是呈现；重配、重排 document、恢复位置与翻页判断都在同一轮
                // 里做完，不等约 250ms 后的完成回调，否则其间是“新内容、旧偏移”的中间态，会误判翻页。动画中由此移动
                // 视野时，`NativeVideoGridClipView` 补建新视野的卡片。
                applySnapshot(
                    animatingDifferences: updatePlan.animatesDifferences(
                        isLaidOut: lastViewportSize != nil && collectionView.window != nil,
                        reducesMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                    )
                )
                reconfigureVisibleItems()
                if pendingRestoreOffsetY != nil {
                    resizeDocument(restoringViewport: false)
                    restorePendingOffsetIfPossible()
                } else if restoresAnchor, !isLiveScrolling {
                    resizeDocument()
                } else {
                    // 实时滚动中不按锚点恢复，免得与用户的手势抢位置：卡片已在原偏移下换了位置，锚点作废、重排后
                    // 重新捕获。严格尾部追加不移动已有卡片，锚点照旧。
                    if restoresAnchor { viewportAnchor = nil }
                    resizeDocument(restoringViewport: false)
                }
                viewportDidChange()
            } else if !updatePlan.changedExistingIDs.isEmpty {
                reconfigureVisibleItems(updatePlan.changedExistingIDs)
            }

            if !updatePlan.identityChanged {
                restorePendingOffsetIfPossible()
                viewportDidChange()
            }
        }

        func reset() {
            guard !isReset else { return }
            recordCurrentScrollOffset(requireAttachedWindow: false)
            persistScrollOffset()
            isReset = true
            hover.forgetHoveredItem()
            for item in collectionView.visibleVideoCards { item.invalidate() }
            collectionView.onActivateSelection = nil
            collectionView.cardMenu = nil
            scrollView.onViewportLayout = nil
            scrollView.onContentInsetsChange = nil
            collectionView.delegate = nil
            collectionView.dataSource = nil
            dataSource = nil
            observers.removeAll()
            onScroll = { _ in }
            onAcknowledgeScrollReset = { _ in }
            actions = .inert
            lastViewportSize = nil
            contents = NativeVideoCardContents()
            nearEndPagination.reset()
            viewportAnchor = nil
        }

        /// 带动画时先让 clip view 记一次进行中的动画，在这次 `apply` 的完成回调里撤销。
        private func applySnapshot(animatingDifferences: Bool = false) {
            guard let dataSource else { return }
            guard animatingDifferences else {
                dataSource.apply(contents.makeSnapshot(), animatingDifferences: false)
                return
            }
            clipView.beginAnimatedUpdate()
            dataSource.apply(contents.makeSnapshot(), animatingDifferences: true) {
                [weak clipView] in
                clipView?.endAnimatedUpdate()
            }
        }

        private func reconfigureVisibleItems(_ ids: Set<String>? = nil) {
            for (item, presentation) in contents.visibleCards(in: collectionView, ids: ids) {
                configure(item, with: presentation)
            }
        }

        private func configure(
            _ item: NativeVideoCollectionItem,
            with presentation: NativeVideoCardPresentation
        ) {
            item.configure(
                presentation: presentation,
                imagePipeline: imagePipeline,
                hoverChanged: { [weak self] item, isHovered in
                    self?.item(item, didChangeHover: isHovered)
                },
                activation: { [weak self] selectedID in
                    self?.activate(selectedID, selecting: true)
                }
            )
        }

        /// 网格激活的唯一入口：点击、回车／空格与读屏按下都经这里；不可用或已不在内容里的卡片不回调 `onSelect`。
        ///
        /// 读屏按下不经集合视图的选择，`selecting` 为 true 时先把选择移到这张卡片。
        private func activate(_ id: String, selecting: Bool = false) {
            guard !isReset, contents.isActivatable(id) else { return }
            if selecting, let indexPath = contents.indexPath(of: id) {
                collectionView.selectionIndexPaths = [indexPath]
            }
            actions.onSelect(id)
        }

        /// 集合视图的 section 边距：底边是内容留白加上 `bottomInset`，与 `contentHeight` 同源。
        private var sectionInset: NSEdgeInsets {
            let padding = NativeVideoGridGeometry.contentPadding
            return NSEdgeInsets(
                top: NativeVideoGridGeometry.topContentPadding,
                left: padding,
                bottom: padding + bottomInset,
                right: padding
            )
        }

        /// `restoringViewport` 为 false 时无条件重排 document，且不按 `viewportAnchor` 恢复；锚点缺失或它的卡片已不在
        /// 内容里时，重排后从当前排版补捕。
        ///
        /// 重排改了 document 高度，传统滚动条可能随之出现或消失，视口宽度在重排中又变一次；这时按新视口再排，
        /// 最多 `maximumDocumentLayoutPasses` 遍。
        private func resizeDocument(restoringViewport: Bool = true) {
            guard !isReset, !isResizingDocument else { return }
            isResizingDocument = true
            defer { isResizingDocument = false }
            var passes = 0
            while layoutDocumentForCurrentViewport(restoringViewport: restoringViewport) {
                passes += 1
                guard pendingViewportChange.any else { break }
                guard passes < Self.maximumDocumentLayoutPasses else {
                    scrollView.needsLayout = true
                    break
                }
            }
            if viewportAnchor.map({ contents[$0.id] == nil }) ?? true {
                viewportAnchor = captureViewportAnchor()
            }
        }

        /// 滚动条出现或消失只会让视口宽度再变一次，两遍足以稳定；第二遍后仍在变说明滚动条在两种宽度间来回
        /// （内容约一屏高），留给下一轮 layout，不在一次重排里反复。
        private static let maximumDocumentLayoutPasses = 2

        /// 按当前视口排一遍 document 并按锚点恢复；视口不可渲染或无需重排时返回 false。
        private func layoutDocumentForCurrentViewport(restoringViewport: Bool) -> Bool {
            let viewportSize = scrollView.contentSize
            guard NativeVideoGridGeometry.isRenderableViewport(width: viewportSize.width)
            else {
                lastViewportSize = nil
                documentLayoutNeedsInvalidation = true
                return false
            }
            let width = viewportSize.width
            let change = pendingViewportChange
            let shouldInvalidateLayout =
                !restoringViewport || documentLayoutNeedsInvalidation || change.width
            guard shouldInvalidateLayout || change.height else { return false }

            lastViewportSize = viewportSize
            documentLayoutNeedsInvalidation = false
            let contentHeight = NativeVideoGridGeometry.contentHeight(
                for: width,
                itemCount: contents.orderedIDs.count,
                bottomInset: bottomInset
            )
            collectionView.setFrameSize(
                NSSize(width: width, height: max(viewportSize.height, contentHeight))
            )
            if shouldInvalidateLayout { layout.invalidateLayout() }
            collectionView.layoutSubtreeIfNeeded()
            if restoringViewport { restore(viewportAnchor) }
            return true
        }

        /// 当前视口与最近一次排版（`lastViewportSize`）在宽、高上是否不同（按 `NativeViewportSize`）；还没有排版时都算不同。
        ///
        /// 视口尺寸是否变化只按这一份基准判断：滚动视图每次 tile 与 layout 后都回调，由这里决定要不要重排。
        /// 宽度一变，AppKit 在回调之前就已按新宽度、旧卡片尺寸重排了集合视图；高度一变，它可能已夹取偏移。
        /// 重排之前排版与偏移都是过渡态，其间的 bounds 变化不记录、不捕获锚点。
        private var pendingViewportChange: (width: Bool, height: Bool, any: Bool) {
            let size = scrollView.contentSize
            guard let lastViewportSize else { return (true, true, true) }
            let width = NativeViewportSize.differs(lastViewportSize.width, size.width)
            let height = NativeViewportSize.differs(lastViewportSize.height, size.height)
            return (width, height, width || height)
        }

        private var currentScrollOffsetY: CGFloat {
            NativeVideoScrollCoordinateSpace.logicalOffset(
                physicalOffset: scrollView.contentView.bounds.origin.y,
                leadingInset: scrollView.contentInsets.top
            )
        }

        private var maximumLogicalScrollOffsetY: CGFloat {
            NativeVideoScrollCoordinateSpace.maximumLogicalOffset(
                documentLength: collectionView.frame.height,
                viewportLength: scrollView.contentSize.height,
                leadingInset: scrollView.contentInsets.top,
                trailingInset: scrollView.contentInsets.bottom
            )
        }

        private func didScroll() {
            guard
                !isReset,
                NativeVideoGridGeometry.isRenderableViewport(
                    width: scrollView.contentSize.width
                )
            else { return }
            hover.updateForCurrentPointerLocation(in: collectionView)
            // 视口尺寸过渡中的 bounds 变化不记录、不捕获锚点、不判断翻页，随后的 `onViewportLayout` 按锚点恢复。
            guard !pendingViewportChange.any else { return }
            // 重排 document 时 AppKit 的夹取照常记录，但锚点留给随后的恢复，不从重排中的排版捕获。
            if recordCurrentScrollOffset(requireAttachedWindow: true), !isResizingDocument {
                viewportAnchor = captureViewportAnchor()
            }
            viewportDidChange()
        }

        @discardableResult
        private func recordCurrentScrollOffset(requireAttachedWindow: Bool) -> Bool {
            guard
                !isApplyingRestoration,
                pendingRestoreOffsetY == nil,
                !requireAttachedWindow || scrollView.window != nil,
                NativeVideoGridGeometry.isRenderableViewport(
                    width: scrollView.contentSize.width
                )
            else { return false }
            retainedScrollOffset.record(currentScrollOffsetY)
            scrollGeneration &+= 1
            return true
        }

        private func persistScrollOffset() {
            guard !isReset else { return }
            guard let offsetY = retainedScrollOffset.takePendingPersistence() else {
                return
            }
            synchronizeBinding(to: offsetY)
        }

        private func contentInsetsDidChange(
            from oldInsets: NSEdgeInsets,
            to newInsets: NSEdgeInsets
        ) {
            guard !isReset else { return }
            if pendingRestoreOffsetY != nil {
                restorePendingOffsetIfPossible()
                viewportDidChange()
                return
            }
            let logicalOffset = NativeVideoScrollCoordinateSpace.logicalOffset(
                physicalOffset: scrollView.contentView.bounds.origin.y,
                leadingInset: oldInsets.top
            )
            applyLogicalScrollOffset(logicalOffset)
            retainedScrollOffset.markPersisted(logicalOffset)
        }

        /// 从当前排版读出视野首卡（`NativeVideoCollectionView.firstVisibleItem()`）；视口尺寸过渡中
        /// （`pendingViewportChange`）读不出可信的首卡，返回 nil。
        private func captureViewportAnchor() -> NativeVideoGridViewportAnchor? {
            guard
                !contents.orderedIDs.isEmpty,
                !pendingViewportChange.any,
                NativeVideoGridGeometry.isRenderableViewport(
                    width: collectionView.bounds.width
                ),
                let first = collectionView.firstVisibleItem(),
                let item = first.indexPath?.item,
                contents.orderedIDs.indices.contains(item)
            else { return nil }
            return NativeVideoGridViewportAnchor(
                id: contents.orderedIDs[item],
                offsetFromViewportTop: first.frame.minY - currentScrollOffsetY
            )
        }

        private func restore(_ anchor: NativeVideoGridViewportAnchor?) {
            guard
                let anchor,
                let index = contents.orderedIDs.firstIndex(of: anchor.id),
                let attributes = layout.layoutAttributesForItem(
                    at: IndexPath(item: index, section: 0)
                )
            else { return }
            applyLogicalScrollOffset(attributes.frame.minY - anchor.offsetFromViewportTop)
        }

        private func restorePendingOffsetIfPossible() {
            guard
                !isReset,
                lastViewportSize != nil,
                NativeVideoGridGeometry.isRenderableViewport(
                    width: scrollView.contentSize.width
                ),
                let pendingRestoreOffsetY
            else { return }
            let target = applyLogicalScrollOffset(pendingRestoreOffsetY)
            self.pendingRestoreOffsetY = nil
            viewportAnchor = captureViewportAnchor()
            if target <= 0 {
                topPin.pin(atScrollGeneration: scrollGeneration)
            }
            retainedScrollOffset.markPersisted(target)
            synchronizeBinding(to: target)
            if let acknowledgementID = pendingScrollResetAcknowledgementID {
                pendingScrollResetAcknowledgementID = nil
                onAcknowledgeScrollReset(acknowledgementID)
            }
        }

        /// 把逻辑偏移夹在可滚动范围内后设到 clip view，返回实际设置的逻辑偏移；不改记录的滚动位置，由调用方决定
        /// 是否标记为已同步。
        @discardableResult
        private func applyLogicalScrollOffset(_ target: CGFloat) -> CGFloat {
            let logicalTarget = min(max(0, target), maximumLogicalScrollOffsetY)
            applyPhysicalScrollOffset(
                NativeVideoScrollCoordinateSpace.physicalOffset(
                    logicalOffset: logicalTarget,
                    leadingInset: scrollView.contentInsets.top
                )
            )
            return logicalTarget
        }

        private func synchronizeBinding(to offsetY: CGFloat) {
            scrollBindingBridge.markSynchronized(offsetY)
            onScroll(offsetY)
        }

        private func applyPhysicalScrollOffset(_ target: CGFloat) {
            isApplyingRestoration = true
            scrollView.scrollVertically(toPhysicalOffset: target)
            isApplyingRestoration = false
        }

        /// 视野或内容变化后：先保持封面预加载的余量，再判断是否请求下一页。
        private func viewportDidChange() {
            collectionView.refreshPreparedContentIfNeeded()
            evaluateNearEnd()
        }

        /// 重排 document 或等待恢复偏移时视口还在过渡：条目数已是新的，位置还是旧的，此时不判断翻页。
        private func evaluateNearEnd() {
            guard
                !isReset,
                !isResizingDocument,
                pendingRestoreOffsetY == nil,
                lastViewportSize != nil,
                NativeVideoGridGeometry.isRenderableViewport(
                    width: collectionView.bounds.width
                )
            else { return }
            let isInside =
                tailState.canLoadMore && tailState.tailIdentity != nil
                && NativeVideoGridGeometry.isNearEnd(
                    itemCount: contents.orderedIDs.count,
                    width: collectionView.bounds.width,
                    visibleMaximumY: collectionView.visibleRect.maxY,
                    viewportHeight: collectionView.visibleRect.height,
                    bottomInset: bottomInset
                )
            if nearEndPagination.shouldLoadMore(
                isInsideThreshold: isInside,
                state: tailState,
                isLiveScrolling: isLiveScrolling
            ) {
                actions.onNearEnd()
            }
        }

        private func item(
            _ item: NativeVideoCollectionItem,
            didChangeHover isHovered: Bool
        ) {
            guard !isReset else { return }
            hover.itemDidChangeHover(item, isHovered: isHovered)
        }

        package func collectionView(
            _ collectionView: NSCollectionView,
            layout collectionViewLayout: NSCollectionViewLayout,
            sizeForItemAt indexPath: IndexPath
        ) -> NSSize {
            NativeVideoGridGeometry.itemSize(for: collectionView.bounds.width)
        }

        /// 鼠标选中只接受可进入播放的卡片；键盘方向键直接设置选择、不经这里，焦点仍可停在不可用卡片上。
        package func collectionView(
            _ collectionView: NSCollectionView,
            shouldSelectItemsAt indexPaths: Set<IndexPath>
        ) -> Set<IndexPath> {
            contents.activatableIndexPaths(in: indexPaths)
        }

        /// 按下高亮只给可进入播放的卡片，其他高亮状态照常。
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
            guard let item = item as? NativeVideoCollectionItem else { return }
            guard collectionView.indexPath(for: item) == nil else { return }
            hover.itemDidEndDisplaying(item)
        }
    }
}
