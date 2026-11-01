import AppKit
import BiliApplication
import BiliModels
import BiliVideoCollectionUI

/// 播放页详情区的 `NSCollectionView` 协调器：拥有 diffable 数据源、行高缓存、评论分页与滚动状态。
///
/// 窗口级图片管线与评论资源 resolver 由宿主注入，管线的关闭不归这里；评论数据、排序与分页请求归
/// `PlaybackCommentsViewModel`，这里只把呈现落到集合视图并在近尾时调用 `loadNextComments`。职责按文件拆开：
/// 单元格（`+Items`）、快照与行高（`+Snapshot`）、视口与锚点（`+Viewport`）、遮挡与焦点（`+Focus`）、
/// 评论近尾分页（`+Pagination`）。
///
/// 只在主线程使用（`@MainActor`）。`tearDown` 由 `NativePlaybackDetailsView` 在视图拆除时调用一次：先递增
/// 快照代次并取消精测与分页 Task，再交出焦点、移除 observer、释放可见项资源，最后丢掉数据源与 document view；
/// 之后的 `update` 与回调都直接返回。用 AppKit 的理由见 ARCHITECTURE「原生 AppKit 集合视图」。
@MainActor
final class NativePlaybackDetailsController: NSObject, NSCollectionViewDelegate {
    let rootView = NativePlaybackDetailsRootView()
    let collectionView = NSCollectionView()
    let layout = NativePlaybackDetailsLayout()
    /// 行高缓存：只在主线程使用；换视频不清空（身份已不同），拆除时清空。
    let heightCache = CostBoundedLRUCache<NativePlaybackDetailsHeightCacheKey, CGFloat>(
        limits: .sidebarRowHeights
    )
    let imagePipeline: any VideoDetailImageLoading
    private let commentAssetURLResolver: CommentAssetURLResolver
    lazy var commentTextRenderer = NativePlaybackCommentTextRenderer(
        imagePipeline: imagePipeline,
        resolveURL: commentAssetURLResolver
    )
    lazy var commentAvatarLoader = NativePlaybackCommentAvatarLoader(
        imagePipeline: imagePipeline,
        resolveURL: commentAssetURLResolver
    )
    lazy var commentPictureLoader = NativePlaybackCommentPictureLoader(
        imagePipeline: imagePipeline,
        resolveURL: commentAssetURLResolver
    )
    private(set) var dataSource:
        NSCollectionViewDiffableDataSource<
            NativePlaybackDetailsSectionID,
            NativePlaybackDetailsItemID
        >?
    private(set) var presentation = NativePlaybackDetailsPresentation(
        content: nil,
        overlay: .unavailable(
            title: VideoDetailFeatureStrings.localized("没有播放上下文"),
            message: VideoDetailFeatureStrings.localized("返回来源页并重新选择视频。")
        )
    )
    private(set) var actions = NativePlaybackDetailsActions(
        selectEpisode: { _ in },
        selectPage: { _, _ in },
        retryPages: {},
        selectCommentSort: { _ in },
        retryComments: {},
        loadNextComments: {},
        expandReplies: { _ in },
        collapseReplies: { _ in },
        showReplyPage: { _, _ in },
        showDialog: { _, _ in },
        loadMoreDialog: { _ in },
        closeDialog: { _ in },
        retryReplies: { _ in },
        openCommentLink: { _ in },
        openCommentPictures: { _ in }
    )
    var itemIDs: [NativePlaybackDetailsItemID] = []
    private(set) var commentThreadsByItemID:
        [NativePlaybackDetailsItemID: NativePlaybackCommentThreadPresentation] = [:]
    /// 评论正文重新排版的次数：表情或链接图标加载失败、改回原文时递增（成功到达只在固定尺寸的附件里换图，
    /// 行高不变）；并入行高缓存的 revision，让这一行重新测量。
    var commentRenderRevisions: [NativePlaybackDetailsItemID: UInt64] = [:]
    /// 简介是否展开：详情区自己的界面状态，不进 ViewModel；换视频时复位。
    private(set) var summaryExpanded = false
    /// 正在浏览的合集分区：用户可以翻看别的分区而不切换视频；换视频、所选选集变化或该分区不再存在时，
    /// 回到所选选集所在的分区，没有所选时取第一个（见 `reconcileBrowsedSection`）。
    private(set) var browsedSectionID: VideoCollectionSectionIdentity?
    /// 上次协调浏览分区时的所选选集；选集变化才把浏览分区拉回所选分区，否则保留用户的浏览。
    private var lastSelectedEpisodeID: VideoCollectionEpisodeIdentity?
    /// 上次按它重新布局的视口宽度；变化不足 0.5pt 的尺寸通知忽略，避免重复失效布局。
    var measuredViewportWidth: CGFloat = 0
    /// 快照的代次与在途数（含义见 `NativePlaybackDetailsSnapshotTracker`）。
    let snapshots = NativePlaybackDetailsSnapshotTracker()
    /// 分批精测行高；本控制器拥有，`cancelRefinement` 与 `tearDown` 取消。
    let refinement = NativePlaybackDetailsRefinementScheduler()
    /// 评论分页判断；快照更新、条目原地变化与 `tearDown` 时取消。
    let pagination = NativePlaybackDetailsPaginationScheduler()
    /// 评论近尾分页的布防状态：同一尾部只请求一次，离开阈值后才重新布防（阈值比一页评论矮，见
    /// `NearEndPagination.TailChangeInsideThreshold.requiresExit`）。
    var commentsPagination = NearEndPagination<NativePlaybackCommentsPaginationIdentity>(
        tailChangeInsideThreshold: .requiresExit
    )
    private(set) var isLiveScrolling = false
    /// 换视频（回到顶部）与换排序（跳到评论区）的视口意图：快照应用完成后才执行，回到顶部优先。
    var pendingResetToTop = false
    var pendingScrollToComments = false
    /// 楼中楼翻页、进出对话或收起时记下的定位意图，见 `prepareThreadAlignment`。
    ///
    /// 每次快照应用完成时执行，这一楼不再加载后清掉；回到顶部与跳到评论区优先并清掉它，用户开始拖动滚动时作废。
    var pendingThreadAlignment: NativePlaybackDetailsThreadAlignment?
    /// 滚动与实时滚动的通知观察；`tearDown` 时移除。
    private var observers = NativeVideoNotificationObservers()
    private(set) var isTornDown = false

    init(
        commentAssetURLResolver: @escaping CommentAssetURLResolver,
        imagePipeline: any VideoDetailImageLoading
    ) {
        self.commentAssetURLResolver = commentAssetURLResolver
        self.imagePipeline = imagePipeline
        super.init()
        configureCollectionView()
        rootView.scrollView.topButton.target = self
        rootView.scrollView.topButton.action = #selector(scrollToTopFromButton)
        rootView.scrollView.contentView.postsBoundsChangedNotifications = true
        observers.observeScrolling(of: rootView.scrollView) { [weak self] in
            self?.viewportDidScroll()
        }
        observers.observe(
            NSScrollView.willStartLiveScrollNotification,
            object: rootView.scrollView
        ) { [weak self] in
            self?.isLiveScrolling = true
            self?.pendingThreadAlignment = nil
            self?.commentsPagination.releaseBackpressure()
            self?.scheduleNextCommentsPageIfNeeded()
        }
        observers.observe(
            NSScrollView.didEndLiveScrollNotification,
            object: rootView.scrollView
        ) { [weak self] in
            self?.isLiveScrolling = false
        }
        rootView.viewportSizeDidChange = { [weak self] size in
            self?.viewportSizeDidChange(size)
        }
        rootView.scrollView.onContentInsetsChange = { [weak self] oldInsets, newInsets in
            guard let self, !self.isTornDown else { return }
            self.rootView.scrollView.preserveLogicalVerticalOffset(from: oldInsets, to: newInsets)
        }
    }

    func update(
        presentation: NativePlaybackDetailsPresentation,
        actions: NativePlaybackDetailsActions
    ) {
        guard !isTornDown else { return }
        self.actions = actions
        let previousPresentation = self.presentation
        let previousBVID = previousPresentation.content?.bvid
        let nextBVID = presentation.content?.bvid
        let changesIdentity = NativePlaybackDetailsIdentityPolicy.resetsToTop(
            previousBVID: previousBVID,
            nextBVID: nextBVID
        )
        let changesCommentSort =
            previousPresentation.content?.comments.subject
            == presentation.content?.comments.subject
            && previousPresentation.content?.comments.sort
                != presentation.content?.comments.sort
        let preservesCommentPaginationPosition =
            NativePlaybackCommentsAnchorPolicy.preservesRelativePosition(
                previous: previousPresentation.content?.comments,
                next: presentation.content?.comments
            )
        if changesIdentity {
            summaryExpanded = false
            browsedSectionID = nil
            lastSelectedEpisodeID = nil
            commentsPagination.reset()
        }
        if changesCommentSort {
            commentsPagination.reset()
        }
        reconcileBrowsedSection(with: presentation.content?.selection)
        let changedItemIDs = presentation.changedItemIDs(
            comparedTo: previousPresentation
        )
        self.presentation = presentation
        commentThreadsByItemID = Dictionary(
            uniqueKeysWithValues: presentation.content?.comments.threads.map {
                (
                    NativePlaybackDetailsItemID.commentThread(
                        subject: $0.subject,
                        rootID: $0.thread.id
                    ),
                    $0
                )
            } ?? []
        )
        commentTextRenderer.timestampLimitSeconds =
            presentation.content?.timestampLimitSeconds
        commentTextRenderer.retainFailureScopes(
            Set(commentThreadsByItemID.values.map(\.textScope))
        )
        commentRenderRevisions = commentRenderRevisions.filter {
            commentThreadsByItemID[$0.key] != nil
        }
        updateOverlay()
        applySnapshot(
            resetToTop: changesIdentity,
            scrollToComments: changesCommentSort,
            preservesCommentPaginationPosition: preservesCommentPaginationPosition,
            changedItemIDs: changedItemIDs
        )
    }

    func tearDown() {
        guard !isTornDown else { return }
        isTornDown = true
        snapshots.invalidate()
        cancelRefinement()
        pagination.cancel()
        commentsPagination.reset()
        isLiveScrolling = false
        pendingResetToTop = false
        pendingScrollToComments = false
        pendingThreadAlignment = nil
        releaseCollectionFirstResponder()
        rootView.viewportSizeDidChange = nil
        rootView.scrollView.onContentInsetsChange = nil
        observers.removeAll()
        for item in collectionView.visibleItems() {
            (item as? NativePlaybackDetailsUploaderItem)?.releaseOffscreenResources()
            (item as? NativePlaybackCommentThreadItem)?.releaseOffscreenResources()
        }
        dataSource = nil
        itemIDs.removeAll()
        commentThreadsByItemID.removeAll(keepingCapacity: false)
        commentRenderRevisions.removeAll(keepingCapacity: false)
        commentTextRenderer.removeAllFailures()
        heightCache.removeAll()
        collectionView.delegate = nil
        rootView.scrollView.documentView = nil
    }

    private func configureCollectionView() {
        layout.heightProvider = { [weak self] entry, width in
            self?.cachedHeight(for: entry.itemID, width: width) ?? 1
        }
        collectionView.collectionViewLayout = layout
        collectionView.delegate = self
        collectionView.isSelectable = false
        collectionView.backgroundColors = [.clear]
        collectionView.register(
            NativePlaybackDetailsUploaderItem.self,
            forItemWithIdentifier: NativePlaybackDetailsUploaderItem.reuseIdentifier
        )
        collectionView.register(
            NativePlaybackDetailsSummaryItem.self,
            forItemWithIdentifier: NativePlaybackDetailsSummaryItem.reuseIdentifier
        )
        collectionView.register(
            NativePlaybackDetailsSelectionItem.self,
            forItemWithIdentifier: NativePlaybackDetailsSelectionItem.reuseIdentifier
        )
        collectionView.register(
            NativePlaybackCommentsHeaderItem.self,
            forItemWithIdentifier: NativePlaybackCommentsHeaderItem.reuseIdentifier
        )
        collectionView.register(
            NativePlaybackCommentsStateItem.self,
            forItemWithIdentifier: NativePlaybackCommentsStateItem.reuseIdentifier
        )
        collectionView.register(
            NativePlaybackCommentThreadItem.self,
            forItemWithIdentifier: NativePlaybackCommentThreadItem.reuseIdentifier
        )
        collectionView.register(
            NativePlaybackCommentsFooterItem.self,
            forItemWithIdentifier: NativePlaybackCommentsFooterItem.reuseIdentifier
        )
        dataSource = NSCollectionViewDiffableDataSource(
            collectionView: collectionView
        ) { [weak self] collectionView, indexPath, itemID in
            self?.makeItem(
                collectionView: collectionView,
                indexPath: indexPath,
                itemID: itemID
            )
        }
        rootView.scrollView.documentView = collectionView
    }

    private func reconcileBrowsedSection(
        with selection: PlaybackSelectionProjection?
    ) {
        guard let selection else {
            browsedSectionID = nil
            lastSelectedEpisodeID = nil
            return
        }
        let selectedEpisodeChanged =
            selection.selectedEpisodeID != lastSelectedEpisodeID
        let requestedSectionIsAvailable =
            browsedSectionID.map { requestedID in
                selection.episodeSections.contains(where: { $0.id == requestedID })
            } ?? false
        if selectedEpisodeChanged || !requestedSectionIsAvailable {
            browsedSectionID =
                selection.selectedEpisodeSectionID
                ?? selection.episodeSections.first?.id
        }
        lastSelectedEpisodeID = selection.selectedEpisodeID
    }

    func toggleSummary() {
        mutateItem(.summary(bvid: presentation.content?.bvid ?? "")) {
            summaryExpanded.toggle()
        }
    }

    func browseSection(_ sectionID: VideoCollectionSectionIdentity) {
        guard let bvid = presentation.content?.bvid else { return }
        mutateItem(.selection(bvid: bvid)) {
            browsedSectionID = sectionID
        }
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        didEndDisplaying item: NSCollectionViewItem,
        forRepresentedObjectAt indexPath: IndexPath
    ) {
        guard collectionView.indexPath(for: item) == nil else { return }
        (item as? NativePlaybackDetailsUploaderItem)?.releaseOffscreenResources()
        (item as? NativePlaybackCommentThreadItem)?.releaseOffscreenResources()
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        willDisplay item: NSCollectionViewItem,
        forRepresentedObjectAt indexPath: IndexPath
    ) {
        guard let itemID = dataSource?.itemIdentifier(for: indexPath),
            case .commentsFooter = itemID
        else { return }
        scheduleNextCommentsPageIfNeeded()
    }
}
