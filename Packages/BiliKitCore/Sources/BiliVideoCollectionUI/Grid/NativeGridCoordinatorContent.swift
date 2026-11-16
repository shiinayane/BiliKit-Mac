import AppKit

/// 网格 Coordinator 的内容：按差异计划应用快照、重配可见卡片与激活入口。
extension NativeGridView.Coordinator {
    func update(
        items: [Presentation],
        accessibilityLabel: String,
        tailState: NativeVideoGridTailState,
        bottomInset: CGFloat,
        decorations: NativeVideoGridDecorations,
        scrollResetRequestID: UInt64,
        requestedScrollOffsetY: CGFloat,
        onScroll: @escaping (CGFloat) -> Void,
        onAcknowledgeScrollReset: @escaping (UInt64) -> Void,
        actions: NativeGridActions<Presentation>
    ) {
        guard !isReset else { return }
        self.onScroll = onScroll
        self.onAcknowledgeScrollReset = onAcknowledgeScrollReset
        self.actions = actions
        self.tailState = tailState
        let topInsetChanged = decorationHost.update(decorations)
        if self.bottomInset != bottomInset || topInsetChanged {
            self.bottomInset = bottomInset
            layout.invalidateLayout()
            documentNeedsLayout = true
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

        let updatedContents = NativeCardContents(items)
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
            documentNeedsLayout = true
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

    /// 带动画时先让 clip view 记一次进行中的动画，在这次 `apply` 的完成回调里撤销。
    func applySnapshot(animatingDifferences: Bool = false) {
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
        let visibleCards = contents.visibleCards(of: Kind.Item.self, in: collectionView, ids: ids)
        for (item, presentation) in visibleCards {
            configure(item, with: presentation)
        }
    }

    func configure(
        _ item: Kind.Item,
        with presentation: Presentation
    ) {
        item.configure(
            presentation: presentation,
            imagePipeline: images,
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
    func activate(_ id: String, selecting: Bool = false) {
        guard !isReset, contents.isActivatable(id) else { return }
        if selecting, let indexPath = contents.indexPath(of: id) {
            collectionView.selectionIndexPaths = [indexPath]
        }
        actions.onSelect(id)
    }

    private func item(
        _ item: Kind.Item,
        didChangeHover isHovered: Bool
    ) {
        guard !isReset else { return }
        hover.itemDidChangeHover(item, isHovered: isHovered)
    }
}
