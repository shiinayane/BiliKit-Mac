import AppKit
import BiliUI

/// 网格 Coordinator 的滚动与位置：重排 document、视口锚点、待恢复偏移、binding 同步与近尾翻页判断。
extension NativeGridView.Coordinator {
    /// `restoringViewport` 为 false 时无条件重排 document，且不按 `viewportAnchor` 恢复；锚点缺失或它的卡片已不在
    /// 内容里时，重排后从当前排版补捕。
    ///
    /// 重排改了 document 高度，传统滚动条可能随之出现或消失，视口宽度在重排中又变一次；这时按新视口再排，
    /// 最多 `maximumDocumentLayoutPasses` 遍。
    func resizeDocument(restoringViewport: Bool = true) {
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
    ///
    /// 泛型类型不能有静态存储属性，所以写成计算属性。
    private static var maximumDocumentLayoutPasses: Int { 2 }

    /// 按当前视口排一遍 document 并按锚点恢复；视口不可渲染或无需重排时返回 false。
    private func layoutDocumentForCurrentViewport(restoringViewport: Bool) -> Bool {
        let viewportSize = scrollView.contentSize
        guard Kind.geometry.isRenderableViewport(width: viewportSize.width)
        else {
            lastViewportSize = nil
            documentNeedsLayout = true
            return false
        }
        guard !restoringViewport || documentNeedsLayout || pendingViewportChange.any
        else { return false }

        lastViewportSize = viewportSize
        documentNeedsLayout = false
        // 卡片尺寸由组合布局随宽度自己失效；这里只让集合视图按当前视口排好，document 尺寸也由它按布局的
        // 内容尺寸设定，随后按锚点恢复读到的就是新排版。
        collectionView.layoutSubtreeIfNeeded()
        if restoringViewport { restore(viewportAnchor) }
        return true
    }

    /// 当前视口与最近一次排版（`lastViewportSize`）在宽、高上是否不同（按 `NativeViewportSize`）；还没有排版时都算不同。
    ///
    /// 视口尺寸是否变化只按这一份基准判断：滚动视图每次 tile 与 layout 后都回调，由这里决定要不要重排。
    /// 宽度一变，组合布局在回调之前就已按新宽度重排了集合视图，偏移却还是旧排版下的，视野首卡已经换了；高度
    /// 一变，AppKit 可能已夹取偏移。按锚点恢复之前偏移都是过渡态，其间的 bounds 变化不记录、不捕获锚点。半点
    /// 宽度变化也要算变化（`NativeViewportSize`），否则这一步不按锚点恢复，跨列数分界时视野会跳一行。
    var pendingViewportChange: (width: Bool, height: Bool, any: Bool) {
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

    func didScroll() {
        guard
            !isReset,
            !isDetached,
            Kind.geometry.isRenderableViewport(
                width: scrollView.contentSize.width
            )
        else { return }
        hover.updateForCurrentPointerLocation(in: collectionView)
        decorationHost.updateScrollToTopVisibility(logicalOffset: currentScrollOffsetY)
        // 视口尺寸过渡中的 bounds 变化不记录、不捕获锚点、不判断翻页，随后的 `onViewportLayout` 按锚点恢复。
        guard !pendingViewportChange.any else { return }
        // 重排 document 时 AppKit 的夹取照常记录，但锚点留给随后的恢复，不从重排中的排版捕获。
        if recordCurrentScrollOffset(requireAttachedWindow: true), !isResizingDocument {
            viewportAnchor = captureViewportAnchor()
        }
        viewportDidChange()
    }

    @discardableResult
    func recordCurrentScrollOffset(requireAttachedWindow: Bool) -> Bool {
        guard
            !isApplyingRestoration,
            pendingRestoreOffsetY == nil,
            !requireAttachedWindow || scrollView.window != nil,
            Kind.geometry.isRenderableViewport(
                width: scrollView.contentSize.width
            )
        else { return false }
        retainedScrollOffset.record(currentScrollOffsetY)
        scrollGeneration &+= 1
        return true
    }

    /// 「返回顶部」按钮：像用户滚动一样带动画滚到顶部（减弱动态效果时直接跳），途中的位置照常按滚动记录，落定后同步回
    /// binding。
    func scrollToTopFromButton() {
        guard !isReset, !isDetached else { return }
        scrollView.scrollVertically(
            toPhysicalOffset: NativeVideoScrollCoordinateSpace.physicalOffset(
                logicalOffset: 0,
                leadingInset: scrollView.contentInsets.top
            ),
            animated: true,
            completion: { [weak self] in self?.persistScrollOffset() }
        )
    }

    func persistScrollOffset() {
        guard !isReset else { return }
        guard let offsetY = retainedScrollOffset.takePendingPersistence() else {
            return
        }
        synchronizeBinding(to: offsetY)
    }

    func contentInsetsDidChange(
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
            Kind.geometry.isRenderableViewport(
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

    func restorePendingOffsetIfPossible() {
        guard
            !isReset,
            lastViewportSize != nil,
            Kind.geometry.isRenderableViewport(
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
    func viewportDidChange() {
        collectionView.refreshPreparedContentIfNeeded()
        evaluateNearEnd()
    }

    /// 重排 document 或等待恢复偏移时视口还在过渡：条目数已是新的，位置还是旧的，此时不判断翻页。
    private func evaluateNearEnd() {
        guard
            !isReset,
            !isDetached,
            !isResizingDocument,
            pendingRestoreOffsetY == nil,
            lastViewportSize != nil,
            Kind.geometry.isRenderableViewport(
                width: collectionView.bounds.width
            )
        else { return }
        let isInside =
            tailState.canLoadMore && tailState.tailIdentity != nil
            && Kind.geometry.isNearEnd(
                itemCount: contents.orderedIDs.count,
                width: collectionView.bounds.width,
                visibleMaximumY: collectionView.visibleRect.maxY,
                viewportHeight: collectionView.visibleRect.height,
                extraHeight: bottomInset + decorationHost.topInset
            )
        if nearEndPagination.shouldLoadMore(
            isInsideThreshold: isInside,
            state: tailState,
            isLiveScrolling: isLiveScrolling
        ) {
            actions.onNearEnd()
        }
    }
}
