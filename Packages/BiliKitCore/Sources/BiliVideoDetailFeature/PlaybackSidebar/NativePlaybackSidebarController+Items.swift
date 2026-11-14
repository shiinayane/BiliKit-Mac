import AppKit
import BiliApplication
import BiliModels
import BiliVideoCollectionUI

/// 单元格的创建与配置：按条目身份取出呈现，接上动作回调；可见的 UP 主行与楼中楼原地更新。
extension NativePlaybackSidebarController {
    private func configureUploader(
        _ item: NativePlaybackSidebarUploaderItem,
        content: VideoUploaderHeaderContent
    ) {
        item.configure(
            content: content,
            imagePipeline: imagePipeline,
            onOpenSpace: actions.openUploaderSpace == nil
                ? nil : { [weak self] in self?.releasingFocus { $0.actions.openUploaderSpace?() } },
            onSetFollowing: { [weak self] in self?.actions.setFollowing?($0) }
        )
    }

    /// 可见的 UP 主行与楼中楼原地更新、不整项重载，返回已处理的项；其余变化的项由调用方重载。
    ///
    /// 重载会换掉视图，就没有旧画面可接着淡入：名片到达（见 `NativePlaybackUploaderProfileReveal`）与楼中楼
    /// 换内容（见 `NativePlaybackCommentRepliesPanelView`）都靠同一实例原地重配。行高变化由调用方随后的布局更新带上。
    func reconfigureVisibleItemsInPlace(
        in changedItemIDs: Set<NativePlaybackSidebarItemID>
    ) -> Set<NativePlaybackSidebarItemID> {
        guard let content = presentation.content else { return [] }
        var handled: Set<NativePlaybackSidebarItemID> = []
        for itemID in changedItemIDs {
            guard let indexPath = dataSource?.indexPath(for: itemID),
                let item = collectionView.item(at: indexPath)
            else { continue }
            switch (itemID, item) {
            case (.uploader(let bvid), let item as NativePlaybackSidebarUploaderItem)
            where bvid == content.bvid:
                configureUploader(item, content: content.uploader)
                handled.insert(itemID)
            case (.commentThread(_, let rootID), let item as NativePlaybackCommentThreadItem):
                guard let thread = commentThreadsByItemID[itemID] else { continue }
                configureCommentThread(item, itemID: itemID, rootID: rootID, presentation: thread)
                handled.insert(itemID)
            default:
                continue
            }
        }
        return handled
    }

    private func configureCommentThread(
        _ item: NativePlaybackCommentThreadItem,
        itemID: NativePlaybackSidebarItemID,
        rootID: CommentID,
        presentation thread: NativePlaybackCommentThreadPresentation
    ) {
        item.configure(
            presentation: thread,
            textRenderer: commentTextRenderer,
            avatarLoader: commentAvatarLoader,
            pictureLoader: commentPictureLoader,
            onTextLayoutChange: { [weak self] in
                self?.commentTextLayoutDidChange(for: itemID)
            },
            onExpand: { [weak self] in self?.actions.expandReplies(rootID) },
            onCollapse: { [weak self] in
                self?.prepareThreadAlignment(itemID, edge: .root)
                self?.actions.collapseReplies(rootID)
            },
            onShowPage: { [weak self] page in
                self?.prepareThreadAlignment(itemID, edge: .repliesPanel)
                self?.actions.showReplyPage(rootID, page)
            },
            onRetry: { [weak self] in self?.actions.retryReplies(rootID) },
            onShowDialog: { [weak self] reply in
                self?.prepareThreadAlignment(itemID, edge: .repliesPanel)
                self?.actions.showDialog(rootID, reply)
            },
            onLoadMoreDialog: { [weak self] in self?.actions.loadMoreDialog(rootID) },
            onCloseDialog: { [weak self] in
                self?.prepareThreadAlignment(itemID, edge: .repliesPanel)
                self?.actions.closeDialog(rootID)
            },
            onOpenLink: { [weak self] target in
                self?.releasingFocus { $0.actions.openCommentLink(target) }
            },
            onOpenPictures: { [weak self] in
                self?.actions.openCommentPictures($0)
            },
            onOpenAuthorSpace: actions.openCommentAuthorSpace == nil
                ? nil
                : { [weak self] author in
                    self?.releasingFocus { $0.actions.openCommentAuthorSpace?(author) }
                },
            rowActions: actions.reactToComment.map { react in
                NativePlaybackCommentRowActions(
                    availability: thread.writeAvailability,
                    react: react,
                    reply: { [weak self] in self?.actions.replyToComment?($0) }
                )
            }
        )
    }

    func makeItem(
        collectionView: NSCollectionView,
        indexPath: IndexPath,
        itemID: NativePlaybackSidebarItemID
    ) -> NSCollectionViewItem? {
        guard let content = presentation.content else { return nil }
        switch itemID {
        case .uploader:
            guard
                let item = collectionView.makeItem(
                    withIdentifier: NativePlaybackSidebarUploaderItem.reuseIdentifier,
                    for: indexPath
                ) as? NativePlaybackSidebarUploaderItem
            else { return nil }
            configureUploader(item, content: content.uploader)
            return item
        case .summary:
            guard
                let item = collectionView.makeItem(
                    withIdentifier: NativePlaybackSidebarSummaryItem.reuseIdentifier,
                    for: indexPath
                ) as? NativePlaybackSidebarSummaryItem
            else { return nil }
            item.configure(
                summary: content.summary,
                links: content.summaryLinks,
                timestampLimitSeconds: content.timestampLimitSeconds,
                expanded: summaryExpanded,
                onToggle: { [weak self] in self?.toggleSummary() },
                onOpenLink: { [weak self] target in
                    self?.releasingFocus { $0.actions.openCommentLink(target) }
                }
            )
            return item
        case .selection:
            guard
                let item = collectionView.makeItem(
                    withIdentifier: NativePlaybackSidebarSelectionItem.reuseIdentifier,
                    for: indexPath
                ) as? NativePlaybackSidebarSelectionItem
            else { return nil }
            item.configure(
                projection: content.selection,
                browsedSectionID: browsedSectionID,
                onSelectSection: { [weak self] in self?.browseSection($0) },
                onSelectEpisode: { [weak self] in self?.actions.selectEpisode($0) },
                onSelectPage: { [weak self] cid in
                    guard self?.presentation.content?.bvid == content.bvid else { return }
                    self?.actions.selectPage(content.bvid, cid)
                },
                onRetryPages: { [weak self] in self?.actions.retryPages() }
            )
            return item
        case .commentsHeader:
            guard
                let item = collectionView.makeItem(
                    withIdentifier: NativePlaybackCommentsHeaderItem.reuseIdentifier,
                    for: indexPath
                ) as? NativePlaybackCommentsHeaderItem
            else { return nil }
            item.configure(
                presentation: content.comments,
                onSelectSort: { [weak self] in self?.actions.selectCommentSort($0) }
            )
            return item
        case .commentsState(_, let kind):
            guard
                let item = collectionView.makeItem(
                    withIdentifier: NativePlaybackCommentsStateItem.reuseIdentifier,
                    for: indexPath
                ) as? NativePlaybackCommentsStateItem
            else { return nil }
            item.configure(
                kind: kind,
                onRetry: { [weak self] in self?.actions.retryComments() }
            )
            return item
        case .commentThread(_, let rootID):
            guard
                let thread = commentThreadsByItemID[itemID],
                let item = collectionView.makeItem(
                    withIdentifier: NativePlaybackCommentThreadItem.reuseIdentifier,
                    for: indexPath
                ) as? NativePlaybackCommentThreadItem
            else { return nil }
            configureCommentThread(item, itemID: itemID, rootID: rootID, presentation: thread)
            return item
        case .commentsFooter:
            guard
                let item = collectionView.makeItem(
                    withIdentifier: NativePlaybackCommentsFooterItem.reuseIdentifier,
                    for: indexPath
                ) as? NativePlaybackCommentsFooterItem
            else { return nil }
            item.configure(
                footer: content.comments.footer,
                onRetry: { [weak self] in self?.actions.retryComments() },
                onLoadMore: { [weak self] in self?.actions.loadNextComments() }
            )
            return item
        }
    }
}
