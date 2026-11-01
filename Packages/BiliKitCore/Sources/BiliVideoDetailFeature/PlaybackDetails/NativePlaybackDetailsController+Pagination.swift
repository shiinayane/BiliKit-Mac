import AppKit
import BiliApplication
import BiliModels
import BiliVideoCollectionUI

/// 评论近尾分页：页脚进入视野且不在快照应用中时请求下一页，每个尾部只请求一次。
extension NativePlaybackDetailsController {
    /// 快照全部应用完、没有在途判断时，等一轮 main actor 后判断是否请求下一页。
    ///
    /// 等一轮是让本轮布局与可见项更新完；Task 捕获快照代次，期间有新快照或拆除就放弃。是否请求由
    /// `NearEndPagination` 按页脚是否在视野内、尾部身份与实时滚动决定，页脚为可加载时才调用 `loadNextComments`。
    func scheduleNextCommentsPageIfNeeded() {
        guard !isTornDown, snapshots.applicationsInFlight == 0,
            !pagination.isScheduled
        else { return }
        let generation = snapshots.generation
        pagination.schedule { [weak self] in
            guard let self, !self.isTornDown,
                self.snapshots.applicationsInFlight == 0,
                self.snapshots.generation == generation
            else { return }
            guard
                self.commentsPagination.shouldLoadMore(
                    isInsideThreshold: self.commentsFooterIsVisible,
                    state: self.commentsPaginationTailState,
                    isLiveScrolling: self.isLiveScrolling
                ), self.presentation.content?.comments.footer == .loadMore
            else { return }
            self.actions.loadNextComments()
        }
    }

    private var commentsPaginationTailState:
        NearEndTailState<NativePlaybackCommentsPaginationIdentity>
    {
        guard let comments = presentation.content?.comments,
            let subject = comments.subject
        else { return .end }
        let identity = NativePlaybackCommentsPaginationIdentity(
            subject: subject,
            lastRootID: comments.threads.last?.thread.id
        )
        switch comments.footer {
        case .loadMore:
            return .init(canLoadMore: true, tailIdentity: identity, isLoading: false)
        case .loading:
            return .init(canLoadMore: true, tailIdentity: identity, isLoading: true)
        case .failed, .stopped, .end:
            return .init(canLoadMore: false, tailIdentity: identity, isLoading: false)
        }
    }

    private var commentsFooterIsVisible: Bool {
        guard
            let footerID = itemIDs.first(where: {
                if case .commentsFooter = $0 { return true }
                return false
            }),
            let footerPath = dataSource?.indexPath(for: footerID),
            collectionView.indexPathsForVisibleItems().contains(footerPath),
            let attributes = layout.layoutAttributesForItem(at: footerPath)
        else { return false }
        return attributes.frame.intersects(rootView.scrollView.documentVisibleRect)
    }
}
