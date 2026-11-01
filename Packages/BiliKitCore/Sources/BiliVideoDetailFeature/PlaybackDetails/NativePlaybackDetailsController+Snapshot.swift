import AppKit
import BiliApplication
import BiliModels
import BiliVideoCollectionUI

/// 快照应用与行高：按更新策略选择整体快照、追加评论或只重载变化的行，完成后恢复视口意图；行高按条目身份、宽度桶与内容 revision 缓存。
extension NativePlaybackDetailsController {
    /// 把当前呈现应用到集合视图。
    ///
    /// 顺序有要求：先取消精测与分页、在数据变化之前捕获锚点，再应用；整体替换与追加在数据源完成回调里、只重载
    /// 在当场完成更新，完成时按代次确认仍是最新快照，再执行待定的视口意图或恢复锚点。
    func applySnapshot(
        resetToTop: Bool,
        scrollToComments: Bool,
        preservesCommentPaginationPosition: Bool,
        changedItemIDs: Set<NativePlaybackDetailsItemID>
    ) {
        guard let dataSource else { return }
        let currentSnapshot = dataSource.snapshot()
        let currentSections = currentSnapshot.sectionIdentifiers.map {
            NativePlaybackDetailsSnapshotSection(
                id: $0,
                items: currentSnapshot.itemIdentifiers(inSection: $0)
            )
        }
        let nextSections = presentation.snapshotSections
        let strategy = NativePlaybackDetailsCollectionUpdatePolicy.resolve(
            current: currentSections,
            next: nextSections,
            changedItemIDs: changedItemIDs,
            hasSnapshotInFlight: snapshots.applicationsInFlight > 0
        )
        guard strategy != .none else {
            pagination.cancel()
            if !presentation.overlay.blocksContent {
                scheduleNextCommentsPageIfNeeded()
            }
            return
        }
        cancelRefinement()
        pagination.cancel()
        let anchor =
            resetToTop
            ? nil
            : captureAnchor(
                allowsBottomFollowing: !preservesCommentPaginationPosition
            )
        if resetToTop {
            pendingResetToTop = true
            pendingScrollToComments = false
        } else if scrollToComments, !pendingResetToTop {
            pendingScrollToComments = true
        }
        itemIDs = presentation.itemIDs
        if strategy == .reloadChangedItems {
            snapshots.invalidate()
            updateLayoutEntries(invalidating: changedItemIDs)
            let reloadedItemIDs = changedItemIDs.subtracting(
                reconfigureVisibleItemsInPlace(in: changedItemIDs)
            )
            let indexPaths = Set(
                reloadedItemIDs.compactMap { dataSource.indexPath(for: $0) }
            )
            if !indexPaths.isEmpty {
                collectionView.reloadItems(at: indexPaths)
            }
            completeCollectionUpdate(anchor: anchor)
            return
        }
        var snapshot = NSDiffableDataSourceSnapshot<
            NativePlaybackDetailsSectionID,
            NativePlaybackDetailsItemID
        >()
        for section in presentation.sections {
            snapshot.appendSections([section.id])
            snapshot.appendItems(section.items, toSection: section.id)
        }
        if !changedItemIDs.isEmpty {
            let existing = Set(currentSnapshot.itemIdentifiers)
            let reloadable = itemIDs.filter {
                existing.contains($0) && changedItemIDs.contains($0)
            }
            if !reloadable.isEmpty {
                snapshot.reloadItems(reloadable)
            }
        }
        let generation = snapshots.beginApplication()
        let updatesLayoutBeforeSnapshot = strategy == .appendComments
        if updatesLayoutBeforeSnapshot {
            updateLayoutEntries(invalidating: changedItemIDs)
            collectionView.layoutSubtreeIfNeeded()
        }
        let completion = { [weak self] in
            guard let self else { return }
            self.snapshots.finishApplication()
            guard !self.isTornDown else { return }
            guard self.snapshots.generation == generation else {
                if self.snapshots.applicationsInFlight == 0 {
                    self.scheduleNextCommentsPageIfNeeded()
                }
                return
            }
            if !updatesLayoutBeforeSnapshot {
                self.updateLayoutEntries(invalidating: changedItemIDs)
            }
            self.completeCollectionUpdate(anchor: anchor)
        }
        if strategy == .appendComments {
            // 追加时要按差异插入：不做差异动画的 apply 会让集合视图整体重载，可见行全部重建、阅读位置跳动。
            // 放在时长 0、关闭隐式动画的动画组里，插入即时完成，没有可见动画。
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0
                context.allowsImplicitAnimation = false
                dataSource.apply(
                    snapshot,
                    animatingDifferences: true,
                    completion: completion
                )
            }
        } else {
            dataSource.apply(
                snapshot,
                animatingDifferences: false,
                completion: completion
            )
        }
    }

    private func completeCollectionUpdate(anchor: Anchor?) {
        collectionView.layoutSubtreeIfNeeded()
        synchronizeDocumentFrame()
        applyPendingViewportIntent(fallbackAnchor: anchor)
        scheduleRefinement()
        updateTopButton()
        scheduleNextCommentsPageIfNeeded()
    }

    private func updateLayoutEntries(
        invalidating changedItemIDs: Set<NativePlaybackDetailsItemID> = []
    ) {
        guard presentation.content != nil else {
            layout.update(entries: [])
            return
        }
        let entries = presentation.sections.enumerated().flatMap {
            sectionIndex,
            section in
            section.items.enumerated().map { itemIndex, itemID in
                NativePlaybackDetailsLayout.Entry(
                    indexPath: IndexPath(item: itemIndex, section: sectionIndex),
                    itemID: itemID
                )
            }
        }
        layout.update(entries: entries, invalidating: changedItemIDs)
    }

    /// 条目高度：按条目身份、宽度桶（半点精度）与内容 revision 查缓存，未命中才测量。
    func cachedHeight(
        for itemID: NativePlaybackDetailsItemID,
        width: CGFloat
    ) -> CGFloat {
        guard let content = presentation.content else { return 1 }
        let key = NativePlaybackDetailsHeightCacheKey(
            itemID: itemID,
            widthBucket: Int((width * 2).rounded()),
            revision: revision(for: itemID, content: content)
        )
        if let value = heightCache.value(for: key) { return value }
        let value = height(for: itemID, content: content, width: width)
        heightCache.insert(value, for: key)
        return value
    }

    private func revision(
        for itemID: NativePlaybackDetailsItemID,
        content: NativePlaybackDetailsContent
    ) -> Int {
        var hasher = Hasher()
        hasher.combine(itemID)
        switch itemID {
        case .uploader:
            hasher.combine(String(reflecting: content.uploader))
        case .summary:
            hasher.combine(content.summary)
            hasher.combine(summaryExpanded)
        case .selection:
            hasher.combine(String(reflecting: content.selection))
            hasher.combine(browsedSectionID)
        case .commentsHeader:
            hasher.combine(content.comments.sort)
            hasher.combine(content.comments.totalCount)
            hasher.combine(content.comments.sortIsEnabled)
        case .commentsState(_, let kind):
            hasher.combine(kind)
        case .commentThread:
            hasher.combine(commentThreadsByItemID[itemID]?.revision ?? 0)
            hasher.combine(commentRenderRevisions[itemID] ?? 0)
        case .commentsFooter:
            hasher.combine(content.comments.footer)
        }
        return hasher.finalize()
    }

    func height(
        for itemID: NativePlaybackDetailsItemID,
        content: NativePlaybackDetailsContent,
        width: CGFloat
    ) -> CGFloat {
        switch itemID {
        case .uploader:
            return NativePlaybackDetailsItemMeasurement.uploader(content.uploader, width: width)
        case .summary:
            return NativePlaybackDetailsItemMeasurement.summary(
                content.summary,
                width: width,
                expanded: summaryExpanded
            )
        case .selection:
            return NativePlaybackDetailsItemMeasurement.selection(
                content.selection,
                width: width,
                browsedSectionID: browsedSectionID
            )
        case .commentsHeader:
            return NativePlaybackCommentsItemMeasurement.headerHeight
        case .commentsState(_, let kind):
            return NativePlaybackCommentsItemMeasurement.state(kind, width: width)
        case .commentThread:
            guard let thread = commentThreadsByItemID[itemID] else { return 1 }
            return NativePlaybackCommentsItemMeasurement.thread(
                thread,
                width: width,
                textRenderer: commentTextRenderer
            )
        case .commentsFooter:
            return NativePlaybackCommentsItemMeasurement.footer(content.comments.footer)
        }
    }

    /// 详情区自己的界面状态变化（展开简介、切换浏览的分区）只重载这一行，并保持阅读位置。
    func mutateItem(
        _ itemID: NativePlaybackDetailsItemID,
        mutation: () -> Void
    ) {
        guard itemIDs.contains(itemID), let dataSource else { return }
        cancelRefinement()
        pagination.cancel()
        let anchor = captureAnchor()
        mutation()
        updateLayoutEntries(invalidating: [itemID])
        var snapshot = dataSource.snapshot()
        if snapshot.itemIdentifiers.contains(itemID) {
            snapshot.reloadItems([itemID])
        }
        let generation = snapshots.beginApplication()
        dataSource.apply(snapshot, animatingDifferences: false) { [weak self] in
            guard let self else { return }
            self.snapshots.finishApplication()
            guard !self.isTornDown else { return }
            guard self.snapshots.generation == generation else {
                if self.snapshots.applicationsInFlight == 0 {
                    self.scheduleNextCommentsPageIfNeeded()
                }
                return
            }
            self.collectionView.layoutSubtreeIfNeeded()
            self.synchronizeDocumentFrame()
            self.applyPendingViewportIntent(fallbackAnchor: anchor)
            self.scheduleRefinement()
            self.scheduleNextCommentsPageIfNeeded()
        }
    }

    /// 评论正文的表情或链接图标加载失败、改回原文后行高可能变化：递增这一行的排版 revision 让它重新测量，
    /// 原地重新布局并恢复锚点。
    func commentTextLayoutDidChange(
        for itemID: NativePlaybackDetailsItemID
    ) {
        guard !isTornDown, itemIDs.contains(itemID) else { return }
        cancelRefinement()
        pagination.cancel()
        let anchor = captureAnchor()
        commentRenderRevisions[itemID, default: 0] &+= 1
        updateLayoutEntries(invalidating: [itemID])
        if let indexPath = dataSource?.indexPath(for: itemID) {
            collectionView.item(at: indexPath)?.view.needsLayout = true
        }
        collectionView.layoutSubtreeIfNeeded()
        synchronizeDocumentFrame()
        if let anchor { restore(anchor) }
        scheduleRefinement()
        updateTopButton()
        scheduleNextCommentsPageIfNeeded()
    }
}
