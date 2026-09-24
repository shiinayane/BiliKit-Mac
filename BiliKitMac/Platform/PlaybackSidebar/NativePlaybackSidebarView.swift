import AppKit
import BiliApplication
import BiliBrowseFeature
import BiliModels
import SwiftUI

struct NativePlaybackSidebarView: View {
    let model: VideoViewModel
    let commentsModel: PlaybackCommentsViewModel?
    let commentAssetURLResolver: CommentAssetURLResolver
    let commentImagePipeline: NativeVideoImagePipeline
    let onRetry: () -> Void
    let onSelectPlayback: (String, Int64?) -> Void
    let onOpenCommentLink: (CommentLinkTarget) -> Void
    let onOpenCommentPictures: (NativePlaybackCommentPictureGallery) -> Void

    var body: some View {
        let presentation = presentation
        NativePlaybackSidebarRepresentable(
            presentation: presentation,
            commentAssetURLResolver: commentAssetURLResolver,
            commentImagePipeline: commentImagePipeline,
            actions: NativePlaybackSidebarActions(
                selectEpisode: selectEpisode,
                selectPage: selectPage,
                retryPages: retryPages,
                selectCommentSort: { commentsModel?.selectSort($0) },
                retryComments: { commentsModel?.retryRoot() },
                loadNextComments: { commentsModel?.loadNextPage() },
                expandReplies: { commentsModel?.expandReplies(for: $0) },
                collapseReplies: { commentsModel?.collapseReplies(for: $0) },
                previousReplyPage: {
                    commentsModel?.showPreviousReplyPage(for: $0)
                },
                nextReplyPage: { commentsModel?.showNextReplyPage(for: $0) },
                retryReplies: { commentsModel?.retryReplies(for: $0) },
                openCommentLink: onOpenCommentLink,
                openCommentPictures: onOpenCommentPictures
            )
        )
        .overlay {
            NativePlaybackSidebarOverlayView(overlay: presentation.overlay, retry: retry)
        }
        .navigationTitle("观看辅助")
    }

    private var presentation: NativePlaybackSidebarPresentation {
        let content = model.presentedContext.map { context in
            NativePlaybackSidebarContent(
                bvid: context.detail.bvid,
                uploader: VideoUploaderHeaderContent(
                    owner: context.detail.owner,
                    signatureState: model.uploaderSignatureState
                ),
                summary: context.detail.summary,
                selection: selectionProjection(context),
                comments: commentsPresentation(context)
            )
        }
        return NativePlaybackSidebarPresentation(
            content: content,
            overlay: NativePlaybackSidebarOverlay.resolve(
                state: model.state,
                hasPresentedContent: content != nil
            )
        )
    }

    private func commentsPresentation(
        _ context: VideoContext
    ) -> NativePlaybackCommentsPresentation {
        guard let aid = context.detail.aid,
            commentsModel?.subject == .video(aid: aid)
        else {
            return NativePlaybackCommentsPresentation(model: nil)
        }
        return NativePlaybackCommentsPresentation(model: commentsModel)
    }

    private func selectionProjection(
        _ context: VideoContext
    ) -> PlaybackSelectionProjection {
        let episodes = context.detail.collection?.sections.flatMap(\.episodes) ?? []
        let pagesByEpisode = Dictionary(
            uniqueKeysWithValues: episodes.compactMap { episode in
                model.collectionEpisodePages(for: episode.id).map {
                    (episode.id, $0)
                }
            }
        )
        return PlaybackSelectionProjection(
            context: context,
            selectedEpisodeID: model.selectedCollectionEpisode,
            requestedBVID: model.requestedSelectionBVID,
            requestedCID: model.requestedPreferredCID,
            presentedIdentity: model.presentedPlaybackIdentity,
            pageStates: model.collectionEpisodePageStates,
            pagesByEpisode: pagesByEpisode
        )
    }

    private func retry() {
        if case .failedPage = model.state {
            model.retry()
        } else {
            onRetry()
        }
    }

    private func selectEpisode(_ identity: VideoCollectionEpisodeIdentity) {
        guard
            let episode = model.presentedContext?.detail.collection?.sections
                .flatMap(\.episodes)
                .first(where: { $0.id == identity })
        else { return }
        model.selectCollectionEpisode(episode) { bvid, preferredCID in
            onSelectPlayback(bvid, preferredCID)
        }
    }

    private func selectPage(_ bvid: String, _ cid: Int64) {
        onSelectPlayback(bvid, cid)
    }

    private func retryPages() {
        guard let identity = model.selectedCollectionEpisode,
            let episode = model.presentedContext?.detail.collection?.sections
                .flatMap(\.episodes)
                .first(where: { $0.id == identity })
        else { return }
        model.retryCollectionEpisodePages(episode)
    }
}

struct NativePlaybackSidebarActions {
    let selectEpisode: (VideoCollectionEpisodeIdentity) -> Void
    let selectPage: (String, Int64) -> Void
    let retryPages: () -> Void
    let selectCommentSort: (CommentSort) -> Void
    let retryComments: () -> Void
    let loadNextComments: () -> Void
    let expandReplies: (CommentID) -> Void
    let collapseReplies: (CommentID) -> Void
    let previousReplyPage: (CommentID) -> Void
    let nextReplyPage: (CommentID) -> Void
    let retryReplies: (CommentID) -> Void
    let openCommentLink: (CommentLinkTarget) -> Void
    let openCommentPictures: (NativePlaybackCommentPictureGallery) -> Void
}

private struct NativePlaybackSidebarRepresentable: NSViewRepresentable {
    let presentation: NativePlaybackSidebarPresentation
    let commentAssetURLResolver: CommentAssetURLResolver
    let commentImagePipeline: NativeVideoImagePipeline
    let actions: NativePlaybackSidebarActions

    func makeCoordinator() -> NativePlaybackSidebarController {
        NativePlaybackSidebarController(
            commentAssetURLResolver: commentAssetURLResolver,
            imagePipeline: commentImagePipeline
        )
    }

    func makeNSView(context: Context) -> NativePlaybackSidebarRootView {
        context.coordinator.update(presentation: presentation, actions: actions)
        return context.coordinator.rootView
    }

    func updateNSView(
        _ view: NativePlaybackSidebarRootView,
        context: Context
    ) {
        context.coordinator.update(presentation: presentation, actions: actions)
    }

    static func dismantleNSView(
        _ view: NativePlaybackSidebarRootView,
        coordinator: NativePlaybackSidebarController
    ) {
        coordinator.tearDown()
    }
}

@MainActor
final class NativePlaybackSidebarRootView: NSView {
    let scrollView = NativePlaybackSidebarScrollView()
    var commentsTopButton: NSButton { scrollView.commentsTopButton }
    var viewportSizeDidChange: ((CGSize) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.usesPredominantAxisScrolling = true
        scrollView.verticalScrollElasticity = .automatic
        scrollView.horizontalScrollElasticity = .none
        scrollView.automaticallyAdjustsContentInsets = true
        addSubview(scrollView)
        commentsTopButton.imagePosition = .imageOnly
        commentsTopButton.imageScaling = .scaleProportionallyDown
        commentsTopButton.controlSize = .large
        if #available(macOS 26.0, *) {
            commentsTopButton.bezelStyle = .glass
        } else {
            commentsTopButton.bezelStyle = .circular
        }
        commentsTopButton.setAccessibilityLabel(AppStrings.localized("返回评论区顶部"))
        commentsTopButton.toolTip = AppStrings.localized("返回评论区顶部")
        commentsTopButton.isHidden = true
        scrollView.addSubview(commentsTopButton)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func layout() {
        scrollView.frame = bounds
        super.layout()
        viewportSizeDidChange?(scrollView.contentSize)
    }
}

@MainActor
final class NativePlaybackSidebarScrollView: NSScrollView {
    let commentsTopButton = NSButton(
        image: NSImage(
            systemSymbolName: "arrow.up",
            accessibilityDescription: AppStrings.localized("返回评论区顶部")
        ) ?? NSImage(),
        target: nil,
        action: nil
    )
    var onContentInsetsChange: ((NSEdgeInsets, NSEdgeInsets) -> Void)?
    private var viewportTracker = NativeScrollViewportTracker()

    override func layout() {
        super.layout()
        let safeTrailing = max(contentInsets.right, safeAreaInsets.right)
        let safeBottom = max(contentInsets.bottom, safeAreaInsets.bottom)
        let bottomAlignedY = max(16, bounds.height - safeBottom - 60)
        commentsTopButton.frame = NSRect(
            x: max(16, bounds.width - safeTrailing - 60),
            y: isFlipped ? bottomAlignedY : safeBottom + 16,
            width: 44,
            height: 44
        )
        guard let previousInsets = viewportTracker.update(for: self).previousInsets else { return }
        onContentInsetsChange?(previousInsets, contentInsets)
    }
}

struct NativePlaybackCommentsPaginationIdentity: Equatable {
    let subject: CommentSubjectIdentity
    let lastRootID: CommentID?
}

@MainActor
final class NativePlaybackSidebarController: NSObject, NSCollectionViewDelegate {
    let rootView = NativePlaybackSidebarRootView()
    private let collectionView = NSCollectionView()
    private let layout = NativePlaybackSidebarLayout()
    private let heightCache = NativePlaybackSidebarHeightCache(capacity: 2_048)
    private let imageOwner: NativeVideoImagePipelineOwner?
    private let imagePipeline: NativeVideoImagePipeline
    private let commentAssetURLResolver: CommentAssetURLResolver
    private lazy var commentTextRenderer = NativePlaybackCommentTextRenderer(
        imagePipeline: imagePipeline,
        resolveURL: commentAssetURLResolver
    )
    private lazy var commentAvatarLoader = NativePlaybackCommentAvatarLoader(
        imagePipeline: imagePipeline,
        resolveURL: commentAssetURLResolver
    )
    private lazy var commentPictureLoader = NativePlaybackCommentPictureLoader(
        imagePipeline: imagePipeline,
        resolveURL: commentAssetURLResolver
    )
    private var dataSource:
        NSCollectionViewDiffableDataSource<
            NativePlaybackSidebarSectionID,
            NativePlaybackSidebarItemID
        >?
    private var presentation = NativePlaybackSidebarPresentation(
        content: nil,
        overlay: .unavailable(
            title: AppStrings.localized("没有播放上下文"),
            message: AppStrings.localized("返回来源页并重新选择视频。")
        )
    )
    private var actions = NativePlaybackSidebarActions(
        selectEpisode: { _ in },
        selectPage: { _, _ in },
        retryPages: {},
        selectCommentSort: { _ in },
        retryComments: {},
        loadNextComments: {},
        expandReplies: { _ in },
        collapseReplies: { _ in },
        previousReplyPage: { _ in },
        nextReplyPage: { _ in },
        retryReplies: { _ in },
        openCommentLink: { _ in },
        openCommentPictures: { _ in }
    )
    private var itemIDs: [NativePlaybackSidebarItemID] = []
    private var commentThreadsByItemID:
        [NativePlaybackSidebarItemID: NativePlaybackCommentThreadPresentation] = [:]
    private var commentRenderRevisions: [NativePlaybackSidebarItemID: UInt64] = [:]
    private var summaryExpanded = false
    private var signatureExpanded = false
    private var browsedSectionID: VideoCollectionSectionIdentity?
    private var lastSelectedEpisodeID: VideoCollectionEpisodeIdentity?
    private var measuredViewportWidth: CGFloat = 0
    private var snapshotGeneration: UInt64 = 0
    private var refinementGeneration: UInt64 = 0
    private var refinementTask: Task<Void, Never>?
    private var paginationTask: Task<Void, Never>?
    private var commentsPagination = NearEndPagination<NativePlaybackCommentsPaginationIdentity>()
    private var isLiveScrolling = false
    private var snapshotApplicationsInFlight = 0
    private var pendingResetToTop = false
    private var pendingScrollToComments = false
    private var observers = NativeVideoNotificationObservers()
    private var isTornDown = false

    init(
        commentAssetURLResolver: @escaping CommentAssetURLResolver = { _ in nil },
        imagePipeline: NativeVideoImagePipeline? = nil
    ) {
        self.commentAssetURLResolver = commentAssetURLResolver
        if let imagePipeline {
            imageOwner = nil
            self.imagePipeline = imagePipeline
        } else {
            let owner = NativeVideoImagePipelineOwner()
            imageOwner = owner
            self.imagePipeline = owner.pipeline
        }
        super.init()
        configureCollectionView()
        rootView.commentsTopButton.target = self
        rootView.commentsTopButton.action = #selector(scrollCommentsToTop)
        rootView.scrollView.contentView.postsBoundsChangedNotifications = true
        observers.observeScrolling(of: rootView.scrollView) { [weak self] in
            self?.viewportDidScroll()
        }
        observers.observe(
            NSScrollView.willStartLiveScrollNotification,
            object: rootView.scrollView
        ) { [weak self] in
            self?.isLiveScrolling = true
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
        presentation: NativePlaybackSidebarPresentation,
        actions: NativePlaybackSidebarActions
    ) {
        guard !isTornDown else { return }
        self.actions = actions
        let previousPresentation = self.presentation
        let previousBVID = previousPresentation.content?.bvid
        let nextBVID = presentation.content?.bvid
        let changesIdentity = NativePlaybackSidebarIdentityPolicy.resetsToTop(
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
            signatureExpanded = false
            browsedSectionID = nil
            lastSelectedEpisodeID = nil
            commentsPagination.reset()
        } else if previousPresentation.content?.uploader.signature
            != presentation.content?.uploader.signature
        {
            signatureExpanded = false
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
                    NativePlaybackSidebarItemID.commentThread(
                        subject: $0.subject,
                        rootID: $0.thread.id
                    ),
                    $0
                )
            } ?? []
        )
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
        snapshotGeneration &+= 1
        cancelRefinement()
        paginationTask?.cancel()
        paginationTask = nil
        commentsPagination.reset()
        isLiveScrolling = false
        pendingResetToTop = false
        pendingScrollToComments = false
        releaseCollectionFirstResponder()
        rootView.viewportSizeDidChange = nil
        rootView.scrollView.onContentInsetsChange = nil
        observers.removeAll()
        for item in collectionView.visibleItems() {
            (item as? NativePlaybackSidebarUploaderItem)?.releaseOffscreenResources()
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
        imageOwner?.shutdown()
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
            NativePlaybackSidebarUploaderItem.self,
            forItemWithIdentifier: NativePlaybackSidebarUploaderItem.reuseIdentifier
        )
        collectionView.register(
            NativePlaybackSidebarSummaryItem.self,
            forItemWithIdentifier: NativePlaybackSidebarSummaryItem.reuseIdentifier
        )
        collectionView.register(
            NativePlaybackSidebarSelectionItem.self,
            forItemWithIdentifier: NativePlaybackSidebarSelectionItem.reuseIdentifier
        )
        collectionView.register(
            NativePlaybackSidebarUnavailableItem.self,
            forItemWithIdentifier: NativePlaybackSidebarUnavailableItem.reuseIdentifier
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

    private func makeItem(
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
            item.configure(
                content: content.uploader,
                signatureExpanded: signatureExpanded,
                imagePipeline: imagePipeline,
                onToggleSignature: { [weak self] in self?.toggleSignature() }
            )
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
                expanded: summaryExpanded,
                onToggle: { [weak self] in self?.toggleSummary() }
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
            item.configure(
                presentation: thread,
                textRenderer: commentTextRenderer,
                avatarLoader: commentAvatarLoader,
                pictureLoader: commentPictureLoader,
                onTextLayoutChange: { [weak self] in
                    self?.commentTextLayoutDidChange(for: itemID)
                },
                onExpand: { [weak self] in self?.actions.expandReplies(rootID) },
                onCollapse: { [weak self] in self?.actions.collapseReplies(rootID) },
                onPrevious: { [weak self] in self?.actions.previousReplyPage(rootID) },
                onNext: { [weak self] in self?.actions.nextReplyPage(rootID) },
                onRetry: { [weak self] in self?.actions.retryReplies(rootID) },
                onOpenLink: { [weak self] in self?.actions.openCommentLink($0) },
                onOpenPictures: { [weak self] in
                    self?.actions.openCommentPictures($0)
                }
            )
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

    private func applySnapshot(
        resetToTop: Bool,
        scrollToComments: Bool,
        preservesCommentPaginationPosition: Bool,
        changedItemIDs: Set<NativePlaybackSidebarItemID>
    ) {
        guard let dataSource else { return }
        let currentSnapshot = dataSource.snapshot()
        let currentSections = currentSnapshot.sectionIdentifiers.map {
            NativePlaybackSidebarSnapshotSection(
                id: $0,
                items: currentSnapshot.itemIdentifiers(inSection: $0)
            )
        }
        let nextSections = presentation.snapshotSections
        let strategy = NativePlaybackSidebarCollectionUpdatePolicy.resolve(
            current: currentSections,
            next: nextSections,
            changedItemIDs: changedItemIDs,
            hasSnapshotInFlight: snapshotApplicationsInFlight > 0
        )
        guard strategy != .none else {
            paginationTask?.cancel()
            paginationTask = nil
            if !presentation.overlay.blocksContent {
                scheduleNextCommentsPageIfNeeded()
            }
            return
        }
        cancelRefinement()
        paginationTask?.cancel()
        paginationTask = nil
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
            snapshotGeneration &+= 1
            updateLayoutEntries(invalidating: changedItemIDs)
            let indexPaths = Set(
                changedItemIDs.compactMap { dataSource.indexPath(for: $0) }
            )
            if !indexPaths.isEmpty {
                collectionView.reloadItems(at: indexPaths)
            }
            completeCollectionUpdate(anchor: anchor)
            return
        }
        var snapshot = NSDiffableDataSourceSnapshot<
            NativePlaybackSidebarSectionID,
            NativePlaybackSidebarItemID
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
        snapshotGeneration &+= 1
        let generation = snapshotGeneration
        snapshotApplicationsInFlight += 1
        let updatesLayoutBeforeSnapshot = strategy == .appendComments
        if updatesLayoutBeforeSnapshot {
            updateLayoutEntries(invalidating: changedItemIDs)
            collectionView.layoutSubtreeIfNeeded()
        }
        let completion = { [weak self] in
            guard let self else { return }
            self.snapshotApplicationsInFlight = max(
                0,
                self.snapshotApplicationsInFlight - 1
            )
            guard !self.isTornDown else { return }
            guard self.snapshotGeneration == generation else {
                if self.snapshotApplicationsInFlight == 0 {
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
        updateCommentsTopButton()
        scheduleNextCommentsPageIfNeeded()
    }

    private func updateLayoutEntries(
        invalidating changedItemIDs: Set<NativePlaybackSidebarItemID> = []
    ) {
        guard presentation.content != nil else {
            layout.update(entries: [])
            return
        }
        let entries = presentation.sections.enumerated().flatMap {
            sectionIndex,
            section in
            section.items.enumerated().map { itemIndex, itemID in
                NativePlaybackSidebarLayout.Entry(
                    indexPath: IndexPath(item: itemIndex, section: sectionIndex),
                    itemID: itemID
                )
            }
        }
        layout.update(entries: entries, invalidating: changedItemIDs)
    }

    private func cachedHeight(
        for itemID: NativePlaybackSidebarItemID,
        width: CGFloat
    ) -> CGFloat {
        guard let content = presentation.content else { return 1 }
        let key = NativePlaybackSidebarHeightCacheKey(
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
        for itemID: NativePlaybackSidebarItemID,
        content: NativePlaybackSidebarContent
    ) -> Int {
        var hasher = Hasher()
        hasher.combine(itemID)
        switch itemID {
        case .uploader:
            hasher.combine(String(reflecting: content.uploader))
            hasher.combine(signatureExpanded)
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

    private func height(
        for itemID: NativePlaybackSidebarItemID,
        content: NativePlaybackSidebarContent,
        width: CGFloat
    ) -> CGFloat {
        switch itemID {
        case .uploader:
            return NativePlaybackSidebarItemMeasurement.uploader(
                content.uploader,
                width: width,
                signatureExpanded: signatureExpanded
            )
        case .summary:
            return NativePlaybackSidebarItemMeasurement.summary(
                content.summary,
                width: width,
                expanded: summaryExpanded
            )
        case .selection:
            return NativePlaybackSidebarItemMeasurement.selection(
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

    private func viewportSizeDidChange(_ size: CGSize) {
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

    private func toggleSummary() {
        mutateItem(.summary(bvid: presentation.content?.bvid ?? "")) {
            summaryExpanded.toggle()
        }
    }

    private func toggleSignature() {
        mutateItem(.uploader(bvid: presentation.content?.bvid ?? "")) {
            signatureExpanded.toggle()
        }
    }

    private func browseSection(_ sectionID: VideoCollectionSectionIdentity) {
        guard let bvid = presentation.content?.bvid else { return }
        mutateItem(.selection(bvid: bvid)) {
            browsedSectionID = sectionID
        }
    }

    private func mutateItem(
        _ itemID: NativePlaybackSidebarItemID,
        mutation: () -> Void
    ) {
        guard itemIDs.contains(itemID), let dataSource else { return }
        cancelRefinement()
        paginationTask?.cancel()
        paginationTask = nil
        let anchor = captureAnchor()
        mutation()
        updateLayoutEntries(invalidating: [itemID])
        var snapshot = dataSource.snapshot()
        if snapshot.itemIdentifiers.contains(itemID) {
            snapshot.reloadItems([itemID])
        }
        snapshotGeneration &+= 1
        let generation = snapshotGeneration
        snapshotApplicationsInFlight += 1
        dataSource.apply(snapshot, animatingDifferences: false) { [weak self] in
            guard let self else { return }
            self.snapshotApplicationsInFlight = max(
                0,
                self.snapshotApplicationsInFlight - 1
            )
            guard !self.isTornDown else { return }
            guard self.snapshotGeneration == generation else {
                if self.snapshotApplicationsInFlight == 0 {
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

    private func commentTextLayoutDidChange(
        for itemID: NativePlaybackSidebarItemID
    ) {
        guard !isTornDown, itemIDs.contains(itemID) else { return }
        cancelRefinement()
        paginationTask?.cancel()
        paginationTask = nil
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
        updateCommentsTopButton()
        scheduleNextCommentsPageIfNeeded()
    }

    private struct Anchor {
        let itemID: NativePlaybackSidebarItemID
        let relativeY: CGFloat
        let wasPinnedToBottom: Bool
    }

    private func captureAnchor(
        allowsBottomFollowing: Bool = true
    ) -> Anchor? {
        collectionView.layoutSubtreeIfNeeded()
        let viewport = rootView.scrollView.documentVisibleRect
        let wasPinnedToBottom =
            allowsBottomFollowing
            && NativePlaybackSidebarAnchorPolicy.isBottomPinned(
                contentHeight: layout.collectionViewContentSize.height,
                viewport: viewport
            )
        return collectionView.indexPathsForVisibleItems()
            .compactMap { indexPath -> (NativePlaybackSidebarItemID, NSRect)? in
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

    private func restore(_ anchor: Anchor) {
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

    private func synchronizeDocumentFrame() {
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

    private func cancelRefinement() {
        refinementGeneration &+= 1
        refinementTask?.cancel()
        refinementTask = nil
    }

    private func scheduleRefinement() {
        guard !isTornDown, !layout.pendingRefinementIndexes.isEmpty else {
            return
        }
        refinementGeneration &+= 1
        let generation = refinementGeneration
        refinementTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled,
                !self.isTornDown,
                self.refinementGeneration == generation,
                !self.layout.pendingRefinementIndexes.isEmpty
            {
                let anchor = self.captureAnchor()
                guard
                    self.layout.refineNextBatch(
                        maximumCount: 32,
                        prioritizing: anchor?.itemID
                    )
                else { break }
                self.collectionView.layoutSubtreeIfNeeded()
                self.synchronizeDocumentFrame()
                if let anchor { self.restore(anchor) }
                await Task.yield()
            }
            if self.refinementGeneration == generation {
                self.refinementTask = nil
            }
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

    private func applyPendingViewportIntent(fallbackAnchor: Anchor?) {
        if pendingResetToTop {
            pendingResetToTop = false
            pendingScrollToComments = false
            scrollToTop()
        } else if pendingScrollToComments {
            pendingScrollToComments = false
            scrollToCommentsHeader()
        } else if let fallbackAnchor {
            restore(fallbackAnchor)
        }
    }

    private func updateCommentsTopButton() {
        guard !presentation.overlay.blocksContent,
            let itemID = itemIDs.first(where: {
                if case .commentsHeader = $0 { return true }
                return false
            }), let indexPath = dataSource?.indexPath(for: itemID),
            let attributes = layout.layoutAttributesForItem(at: indexPath)
        else {
            rootView.commentsTopButton.isHidden = true
            return
        }
        let viewport = rootView.scrollView.documentVisibleRect
        rootView.commentsTopButton.isHidden =
            attributes.frame.minY - viewport.minY >= -280
    }

    @objc private func scrollCommentsToTop() {
        scrollToCommentsHeader()
    }

    func scroll(to y: CGFloat) {
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
            )
        )
    }

    private func updateOverlay() {
        let blocked = presentation.overlay.blocksContent
        if blocked, !collectionView.isHidden {
            releaseCollectionFirstResponder()
        }
        rootView.scrollView.setAccessibilityHidden(blocked)
        rootView.scrollView.isHidden = false
        collectionView.isHidden = blocked
        updateCommentsTopButton()
    }

    private func releaseCollectionFirstResponder() {
        guard let window = rootView.window,
            let responder = window.firstResponder,
            collectionOwnsFirstResponder(responder)
        else { return }
        window.makeFirstResponder(nil)
    }

    private func collectionOwnsFirstResponder(_ responder: NSResponder) -> Bool {
        if let responderView = responder as? NSView,
            responderView === collectionView
                || responderView.isDescendant(of: collectionView)
        {
            return true
        }
        return containsFieldEditor(responder, in: collectionView)
    }

    private func containsFieldEditor(
        _ responder: NSResponder,
        in view: NSView
    ) -> Bool {
        if let textField = view as? NSTextField,
            textField.currentEditor() === responder
        {
            return true
        }
        return view.subviews.contains {
            containsFieldEditor(responder, in: $0)
        }
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        didEndDisplaying item: NSCollectionViewItem,
        forRepresentedObjectAt indexPath: IndexPath
    ) {
        guard collectionView.indexPath(for: item) == nil else { return }
        (item as? NativePlaybackSidebarUploaderItem)?.releaseOffscreenResources()
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

    private func viewportDidScroll() {
        updateCommentsTopButton()
        scheduleNextCommentsPageIfNeeded()
    }

    private func scheduleNextCommentsPageIfNeeded() {
        guard !isTornDown, snapshotApplicationsInFlight == 0,
            paginationTask == nil
        else { return }
        let generation = snapshotGeneration
        paginationTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard let self else { return }
            self.paginationTask = nil
            guard !Task.isCancelled, !self.isTornDown,
                self.snapshotApplicationsInFlight == 0,
                self.snapshotGeneration == generation
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
        case .retry, .stopped, .end:
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

enum NativePlaybackSidebarIdentityPolicy {
    static func resetsToTop(
        previousBVID: String?,
        nextBVID: String?
    ) -> Bool {
        nextBVID != nil && previousBVID != nextBVID
    }
}

enum NativePlaybackCommentsAnchorPolicy {
    static func preservesRelativePosition(
        previous: NativePlaybackCommentsPresentation?,
        next: NativePlaybackCommentsPresentation?
    ) -> Bool {
        guard let previous, let next, previous.subject != nil,
            previous.subject == next.subject, previous.sort == next.sort,
            previous.rootState == .loaded, next.rootState == .loaded
        else { return false }

        if previous.footer != next.footer { return true }
        let previousIDs = previous.threads.map { $0.thread.id }
        let nextIDs = next.threads.map { $0.thread.id }
        return nextIDs.count > previousIDs.count
            && Array(nextIDs.prefix(previousIDs.count)) == previousIDs
    }
}

enum NativePlaybackSidebarAnchorPolicy {
    private static let bottomTolerance: CGFloat = 2

    static func isBottomPinned(
        contentHeight: CGFloat,
        viewport: NSRect
    ) -> Bool {
        let maximumY = max(0, contentHeight - viewport.height)
        guard maximumY > bottomTolerance else { return false }
        return maximumY - viewport.minY <= bottomTolerance
    }
}

/// 加载、失败与不可用状态盖在侧栏之上；`.none` 时不创建任何视图。
private struct NativePlaybackSidebarOverlayView: View {
    let overlay: NativePlaybackSidebarOverlay
    let retry: () -> Void

    var body: some View {
        switch overlay {
        case .none:
            EmptyView()
        case .loading(let label):
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel(label)
        case .failure(let title, let message):
            ContentUnavailableView {
                Text(title)
            } description: {
                Text(message)
            } actions: {
                Button(AppStrings.localized("重试"), action: retry)
            }
        case .unavailable(let title, let message):
            ContentUnavailableView {
                Text(title)
            } description: {
                Text(message)
            }
        }
    }
}
