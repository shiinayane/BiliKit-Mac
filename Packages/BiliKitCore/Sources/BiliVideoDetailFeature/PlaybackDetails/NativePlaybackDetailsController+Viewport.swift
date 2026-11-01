import AppKit
import BiliApplication
import BiliModels
import BiliVideoCollectionUI

/// 视口：语义锚点的捕获与恢复、宽度变化后的分批精测、回到顶部与跳到评论区。
extension NativePlaybackDetailsController {
    func viewportSizeDidChange(_ size: CGSize) {
        guard !isTornDown, size.width > 0,
            abs(size.width - measuredViewportWidth) > 0.5
        else { return }
        cancelRefinement()
        let anchor = captureAnchor()
        measuredViewportWidth = size.width
        collectionView.frame.size.width = size.width
        layout.invalidateLayout()
        collectionView.layoutSubtreeIfNeeded()
        synchronizeDocumentFrame()
        if let anchor {
            restore(anchor)
        }
        scheduleRefinement()
    }

    /// 语义锚点：视野内最靠上的条目及其顶边到视口顶边的距离，或者视口贴底。
    ///
    /// 布局变化（追加、改宽度、精测）前捕获，变化后按条目的新位置恢复，阅读位置不随上方内容的高度变化跳动。
    struct Anchor {
        let itemID: NativePlaybackDetailsItemID
        let relativeY: CGFloat
        let wasPinnedToBottom: Bool
    }

    func captureAnchor(
        allowsBottomFollowing: Bool = true
    ) -> Anchor? {
        collectionView.layoutSubtreeIfNeeded()
        let viewport = rootView.scrollView.documentVisibleRect
        let wasPinnedToBottom =
            allowsBottomFollowing
            && NativePlaybackDetailsAnchorPolicy.isBottomPinned(
                contentHeight: layout.collectionViewContentSize.height,
                viewport: viewport
            )
        return collectionView.indexPathsForVisibleItems()
            .compactMap { indexPath -> (NativePlaybackDetailsItemID, NSRect)? in
                guard let itemID = dataSource?.itemIdentifier(for: indexPath),
                    let attributes = layout.layoutAttributesForItem(at: indexPath),
                    attributes.frame.intersects(viewport)
                else { return nil }
                return (itemID, attributes.frame)
            }
            .sorted { $0.1.minY < $1.1.minY }
            .first
            .map {
                Anchor(
                    itemID: $0.0,
                    relativeY: $0.1.minY - viewport.minY,
                    wasPinnedToBottom: wasPinnedToBottom
                )
            }
    }

    func restore(_ anchor: Anchor) {
        if anchor.wasPinnedToBottom {
            scrollToBottom()
            return
        }
        guard let indexPath = dataSource?.indexPath(for: anchor.itemID),
            let attributes = layout.layoutAttributesForItem(at: indexPath)
        else { return }
        let physicalOffset = attributes.frame.minY - anchor.relativeY
        scroll(
            to: NativeVideoScrollCoordinateSpace.logicalOffset(
                physicalOffset: physicalOffset,
                leadingInset: rootView.scrollView.contentInsets.top
            )
        )
    }

    func synchronizeDocumentFrame() {
        let size = NSSize(
            width: rootView.scrollView.contentSize.width,
            height: max(
                rootView.scrollView.contentSize.height,
                layout.collectionViewContentSize.height
            )
        )
        guard collectionView.frame.size != size else { return }
        collectionView.setFrameSize(size)
    }

    private func scrollToTop() {
        scroll(to: 0)
    }

    private func scrollToBottom() {
        scroll(to: layout.collectionViewContentSize.height)
    }

    func cancelRefinement() {
        refinement.cancel()
    }

    /// 按批精测估算行高，每批之后恢复锚点并让出 main actor，长评论列表的重测不会一次卡住界面。
    ///
    /// 优先精测锚点所在的行；代次不再相等（被取消或重新安排）、拆除或没有待精测的行时停止。
    func scheduleRefinement() {
        guard !isTornDown, !layout.pendingRefinementIndexes.isEmpty else {
            return
        }
        refinement.start { [weak self] in
            guard let self, !self.isTornDown,
                !self.layout.pendingRefinementIndexes.isEmpty
            else { return false }
            let anchor = self.captureAnchor()
            guard
                self.layout.refineNextBatch(
                    maximumCount: NativePlaybackDetailsLayout.refinementBatchSize,
                    prioritizing: anchor?.itemID
                )
            else { return false }
            self.collectionView.layoutSubtreeIfNeeded()
            self.synchronizeDocumentFrame()
            if let anchor { self.restore(anchor) }
            return true
        }
    }

    private func scrollToCommentsHeader() {
        guard
            let itemID = itemIDs.first(where: {
                if case .commentsHeader = $0 { return true }
                return false
            }), let indexPath = dataSource?.indexPath(for: itemID),
            let attributes = layout.layoutAttributesForItem(at: indexPath)
        else { return }
        scroll(to: attributes.frame.minY)
    }

    func applyPendingViewportIntent(fallbackAnchor: Anchor?) {
        let threadAlignment = pendingThreadAlignment
        if pendingResetToTop {
            pendingThreadAlignment = nil
            pendingResetToTop = false
            pendingScrollToComments = false
            scrollToTop()
        } else if pendingScrollToComments {
            pendingThreadAlignment = nil
            pendingScrollToComments = false
            scrollToCommentsHeader()
        } else if let threadAlignment, let y = scrollTarget(threadAlignment) {
            if !isLoadingReplies(threadAlignment.itemID) { pendingThreadAlignment = nil }
            scroll(to: y)
        } else {
            pendingThreadAlignment = nil
            if let fallbackAnchor { restore(fallbackAnchor) }
        }
    }

    /// 楼中楼翻页、进出对话或收起前调用，记下这一楼之后要停在哪里，直到这一楼加载完成。
    ///
    /// 要对齐的边（翻页与进出对话时是回复面板顶边，收起时是根评论顶边）此刻已在可见区上方，就把它顶到可见区顶部；
    /// 否则让这一楼顶边停在原来离可见区顶部的位置。不这样做时，语义锚点保持的是可见区里最靠上的条目：在一页回复的底部翻页，
    /// 会停在新一页同样深的位置；这一楼排在最后、视口贴底时，回复到达又会按贴底规则滚到新内容的末尾。意图保留到这一楼
    /// 不再加载（中间的加载态与之后的回复到达都按它定位），用户开始拖动滚动时作废。
    func prepareThreadAlignment(
        _ itemID: NativePlaybackDetailsItemID,
        edge: NativePlaybackDetailsThreadAlignment.Edge
    ) {
        collectionView.layoutSubtreeIfNeeded()
        guard let itemTop = itemTop(itemID),
            let edgeY = edgeY(itemID, edge: edge, itemTop: itemTop)
        else {
            pendingThreadAlignment = nil
            return
        }
        let visibleTop =
            rootView.scrollView.documentVisibleRect.minY
            + max(0, rootView.scrollView.contentInsets.top)
        pendingThreadAlignment = NativePlaybackDetailsThreadAlignment(
            itemID: itemID,
            target: edgeY < visibleTop
                ? .edgeToTop(edge) : .keepItemTop(offsetFromVisibleTop: itemTop - visibleTop)
        )
    }

    /// 执行意图时要滚到的逻辑偏移；这一楼已不在列表里时为 nil。
    private func scrollTarget(_ alignment: NativePlaybackDetailsThreadAlignment) -> CGFloat? {
        guard let itemTop = itemTop(alignment.itemID) else { return nil }
        switch alignment.target {
        case .edgeToTop(let edge):
            return edgeY(alignment.itemID, edge: edge, itemTop: itemTop)
        case .keepItemTop(let offset):
            return itemTop - offset
        }
    }

    private func itemTop(_ itemID: NativePlaybackDetailsItemID) -> CGFloat? {
        guard let indexPath = dataSource?.indexPath(for: itemID),
            let attributes = layout.layoutAttributesForItem(at: indexPath)
        else { return nil }
        return attributes.frame.minY
    }

    /// 对齐边在文档里的纵坐标。
    private func edgeY(
        _ itemID: NativePlaybackDetailsItemID,
        edge: NativePlaybackDetailsThreadAlignment.Edge,
        itemTop: CGFloat
    ) -> CGFloat? {
        switch edge {
        case .root:
            return itemTop
        case .repliesPanel:
            guard let thread = commentThreadsByItemID[itemID],
                let indexPath = dataSource?.indexPath(for: itemID),
                let width = layout.layoutAttributesForItem(at: indexPath)?.frame.width
            else { return nil }
            return itemTop
                + NativePlaybackCommentsItemMeasurement.repliesPanelTop(
                    thread,
                    width: width,
                    textRenderer: commentTextRenderer
                )
        }
    }

    /// 这一楼还有在途的楼中楼翻页或对话请求。
    private func isLoadingReplies(_ itemID: NativePlaybackDetailsItemID) -> Bool {
        guard let state = commentThreadsByItemID[itemID]?.replyState else { return false }
        return state.isLoading || state.dialog?.isLoading == true
    }

    func updateTopButton() {
        rootView.scrollView.updateTopButtonVisibility(
            isBlocked: presentation.overlay.blocksContent
        )
    }

    /// “返回顶部”回到详情区最上面（UP 主信息），而不只是评论区。
    @objc func scrollToTopFromButton() {
        scroll(to: 0, animated: true)
    }

    /// 只有用户点“返回顶部”时 `animated` 为 true；其余程序内部定位直接跳转。
    func scroll(to y: CGFloat, animated: Bool = false) {
        synchronizeDocumentFrame()
        let maximumY = NativeVideoScrollCoordinateSpace.maximumLogicalOffset(
            documentLength: layout.collectionViewContentSize.height,
            viewportLength: rootView.scrollView.contentSize.height,
            leadingInset: rootView.scrollView.contentInsets.top,
            trailingInset: rootView.scrollView.contentInsets.bottom
        )
        let logicalTarget = min(max(0, y), maximumY)
        rootView.scrollView.scrollVertically(
            toPhysicalOffset: NativeVideoScrollCoordinateSpace.physicalOffset(
                logicalOffset: logicalTarget,
                leadingInset: rootView.scrollView.contentInsets.top
            ),
            animated: animated
        )
    }

    func viewportDidScroll() {
        updateTopButton()
        scheduleNextCommentsPageIfNeeded()
    }
}

/// 楼中楼翻页、进出对话或收起后这一楼要停的位置，由 `prepareThreadAlignment` 记下。
struct NativePlaybackDetailsThreadAlignment: Equatable {
    enum Edge: Equatable {
        /// 根评论顶边：收起之后。
        case root
        /// 回复面板顶边（“共 N 条回复”或「返回全部回复」一行）：翻页与进出对话之后。
        case repliesPanel
    }

    enum Target: Equatable {
        /// 把对齐边顶到可见区顶部（动作前它已在可见区上方）。
        case edgeToTop(Edge)
        /// 这一楼顶边保持离可见区顶部这么远（动作前对齐边仍可见）。
        case keepItemTop(offsetFromVisibleTop: CGFloat)
    }

    let itemID: NativePlaybackDetailsItemID
    let target: Target
}
