import AppKit
import BiliApplication
import BiliModels
import BiliUI
import SwiftUI

/// 播放态侧栏：把视频、互动状态与评论 ViewModel 投影成原生集合视图的呈现，用户操作转回 ViewModel 或 App 给的回调。
///
/// AppKit 集合视图的理由见 ARCHITECTURE「原生 AppKit 集合视图」；图片经 `VideoDetailImageLoading` 注入。UP 主行的关注按钮
/// 读 `engagementModel`，点按经环境里的 `VideoEngagementActions` 交给 App 的写入协调者。
public struct NativePlaybackSidebarView: View {
    @Environment(\.videoEngagementActions) private var engagementActions
    let model: VideoViewModel
    let engagementModel: VideoEngagementModel
    let commentsModel: PlaybackCommentsViewModel?
    /// 评论区底部输入框与评论行上的赞、踩；nil 时评论只读。
    let commentWrite: PlaybackCommentWriteModel?
    let commentAssetURLResolver: CommentAssetURLResolver
    let commentImagePipeline: any VideoDetailImageLoading
    let onRetry: () -> Void
    let onSelectPlayback: (String, Int64?) -> Void
    let onOpenCommentLink: (CommentLinkTarget) -> Void
    let onOpenCommentPictures: (NativePlaybackCommentPictureGallery) -> Void
    /// 点击 UP 主行、评论作者（头像与昵称）或正文 @ 提及进入空间。
    let onOpenUploaderSpace: (VideoOwner) -> Void
    /// 被空间层盖住时真正隐藏原生视图：SwiftUI 的透明度与 hit testing 管不到 AppKit 的
    /// cursor rect 与 tracking area，只设透明会让评论正文继续改变指针形状。
    var isObscured: Bool
    /// 把评论入口逐帧的高度转给侧栏滚动视图的「返回顶部」；随视图身份保留，不是 SwiftUI 状态（逐帧写入不能触发重渲染）。
    @State private var composerClearance = NativePlaybackComposerClearance()

    public init(
        model: VideoViewModel,
        engagementModel: VideoEngagementModel,
        commentsModel: PlaybackCommentsViewModel?,
        commentWrite: PlaybackCommentWriteModel? = nil,
        commentAssetURLResolver: @escaping CommentAssetURLResolver,
        commentImagePipeline: any VideoDetailImageLoading,
        onRetry: @escaping () -> Void,
        onSelectPlayback: @escaping (String, Int64?) -> Void,
        onOpenCommentLink: @escaping (CommentLinkTarget) -> Void,
        onOpenCommentPictures: @escaping (NativePlaybackCommentPictureGallery) -> Void,
        onOpenUploaderSpace: @escaping (VideoOwner) -> Void,
        isObscured: Bool = false
    ) {
        self.model = model
        self.engagementModel = engagementModel
        self.commentsModel = commentsModel
        self.commentWrite = commentWrite
        self.commentAssetURLResolver = commentAssetURLResolver
        self.commentImagePipeline = commentImagePipeline
        self.onRetry = onRetry
        self.onSelectPlayback = onSelectPlayback
        self.onOpenCommentLink = onOpenCommentLink
        self.onOpenCommentPictures = onOpenCommentPictures
        self.onOpenUploaderSpace = onOpenUploaderSpace
        self.isObscured = isObscured
    }

    public var body: some View {
        let presentation = presentation
        let openUserSpace = openUserSpace
        NativePlaybackSidebarRepresentable(
            presentation: presentation,
            commentAssetURLResolver: commentAssetURLResolver,
            commentImagePipeline: commentImagePipeline,
            isObscured: isObscured,
            composerClearance: composerClearance,
            actions: NativePlaybackSidebarActions(
                selectEpisode: selectEpisode,
                selectPage: selectPage,
                retryPages: retryPages,
                selectCommentSort: { commentsModel?.selectSort($0) },
                retryComments: { commentsModel?.retryRoot() },
                loadNextComments: { commentsModel?.loadNextPage() },
                expandReplies: { commentsModel?.expandReplies(for: $0) },
                collapseReplies: { commentsModel?.collapseReplies(for: $0) },
                showReplyPage: { commentsModel?.showReplyPage($1, for: $0) },
                showDialog: { commentsModel?.showDialog(of: $1, for: $0) },
                loadMoreDialog: { commentsModel?.loadMoreDialog(for: $0) },
                closeDialog: { commentsModel?.closeDialog(for: $0) },
                retryReplies: { commentsModel?.retryReplies(for: $0) },
                openCommentLink: { [onOpenCommentLink] target in
                    NativePlaybackCommentAuthorSpace.openLink(
                        target,
                        openSpace: openUserSpace,
                        otherwise: onOpenCommentLink
                    )
                },
                openCommentPictures: onOpenCommentPictures,
                openUploaderSpace: { [onOpenUploaderSpace] in
                    guard let owner = model.presentedContext?.detail.owner else { return }
                    onOpenUploaderSpace(owner)
                },
                openCommentAuthorSpace: openUserSpace,
                setFollowing: { [engagementActions] isFollowing in
                    guard let bvid = model.presentedContext?.detail.bvid else { return }
                    engagementActions?.setFollowing(isFollowing, bvid)
                },
                reactToComment: commentWrite.map { write in
                    { write.toggle($1, on: $0) }
                },
                replyToComment: commentWrite.map { write in
                    { write.beginReply(to: $0) }
                }
            )
        )
        .overlay {
            NativePlaybackSidebarOverlayView(overlay: presentation.overlay, retry: retry)
        }
        .overlay(alignment: .bottom) {
            if let commentWrite, presentation.content?.comments.subject != nil,
                commentsModel?.acceptsNewComments == true,
                presentation.overlay == .none, !isObscured
            {
                PlaybackCommentComposerView(
                    model: commentWrite,
                    onVisibleHeightChange: { [composerClearance] in
                        composerClearance.visibleHeightDidChange($0)
                    },
                    onLayoutHeightChange: { [composerClearance] in
                        composerClearance.layoutHeightDidChange($0)
                    }
                )
                .onDisappear { [composerClearance] in composerClearance.composerDidDisappear() }
            }
        }
        .onChange(of: commentsModel?.subject) { commentWrite?.subjectDidChange() }
        .navigationTitle(VideoDetailFeatureStrings.localized("观看辅助"))
    }

    /// 评论作者与正文 @ 用户进入空间的同一入口。
    private var openUserSpace: (CommentAuthor) -> Void {
        { [commentAssetURLResolver, onOpenUploaderSpace] user in
            guard
                let owner = NativePlaybackCommentAuthorSpace.owner(
                    for: user,
                    resolveAvatar: commentAssetURLResolver
                )
            else { return }
            onOpenUploaderSpace(owner)
        }
    }

    private var presentation: NativePlaybackSidebarPresentation {
        let content = model.presentedContext.map { context in
            NativePlaybackSidebarContent(
                bvid: context.detail.bvid,
                uploader: VideoUploaderHeaderContent(
                    owner: context.detail.owner,
                    profileState: model.uploaderProfileState,
                    follow: followContent(for: context.detail.bvid)
                ),
                summary: context.detail.summary,
                summaryLinks: context.detail.summaryLinks,
                selection: selectionProjection(context),
                comments: commentsPresentation(context),
                timestampLimitSeconds: timestampLimitSeconds
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

    /// 关注按钮：互动状态显示的是这个视频、且不是自己的视频时出现；满足写入门槛并读到关注状态时可点，否则禁用。
    private func followContent(for bvid: String) -> VideoUploaderFollowContent? {
        guard engagementModel.bvid == bvid, engagementModel.showsFollowButton else { return nil }
        let isFollowing = engagementModel.isFollowingUploader
        return VideoUploaderFollowContent(
            isFollowing: isFollowing == true,
            isEnabled: isFollowing != nil && (engagementActions?.isAvailable() ?? false)
        )
    }

    /// 播放器就绪的分 P 的可跳转时长；加载、切换分 P 或失败时为 nil，时间戳按普通文字显示。
    private var timestampLimitSeconds: Int? {
        guard case .ready(let context) = model.state else { return nil }
        return context.seekableDurationSeconds
    }

    private func commentsPresentation(
        _ context: VideoContext
    ) -> NativePlaybackCommentsPresentation {
        guard let aid = context.detail.aid,
            commentsModel?.subject == .video(aid: aid)
        else {
            return NativePlaybackCommentsPresentation(model: nil, canWrite: false)
        }
        return NativePlaybackCommentsPresentation(
            model: commentsModel,
            canWrite: commentWrite?.isWritable ?? false
        )
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

/// 让侧栏给浮在底部的评论入口让位：「返回顶部」随入口逐帧上移，列表末尾留出入口的高度。
///
/// 引用类型、由 `NativePlaybackSidebarView` 以 `@State` 持有：入口在渲染时逐帧报告可见高度，写 SwiftUI 状态会在渲染中再
/// 触发更新，所以只改 AppKit 按钮的 frame；列表末尾的留白按入口的布局高度改，展开、收起各一次。弱引用滚动视图与布局，
/// 表示层拆除后写入自然落空。
@MainActor
final class NativePlaybackComposerClearance {
    /// 「返回顶部」与下方评论入口之间的间距。
    static let gapAboveComposer: CGFloat = 12
    /// 列表末尾在入口高度之外再多留的距离：入口离侧栏底边的边距，最后一条评论滚到底时露在入口上方。
    static let listGapAboveComposer: CGFloat = 16

    weak var scrollView: NativeScrollToTopScrollView?
    weak var layout: NativePlaybackSidebarLayout?

    /// 入口此刻看起来的高度；0 表示没有显示，按钮回到默认位置。
    func visibleHeightDidChange(_ height: CGFloat) {
        scrollView?.topButtonLift = height > 0 ? height + Self.gapAboveComposer : 0
    }

    /// 入口的布局高度（终值）；0 表示没有显示，列表末尾不再留白。
    func layoutHeightDidChange(_ height: CGFloat) {
        layout?.bottomClearance = height > 0 ? height + Self.listGapAboveComposer : 0
    }

    /// 入口不再显示。
    func composerDidDisappear() {
        visibleHeightDidChange(0)
        layoutHeightDidChange(0)
    }
}

/// 侧栏条目可以触发的全部动作：由 `NativePlaybackSidebarView` 接到 ViewModel 或 App 回调，控制器只转发。
///
/// 两个空间入口为 nil 时不显示对应入口；`setFollowing` 收到关注按钮点按后的目标状态。
struct NativePlaybackSidebarActions {
    let selectEpisode: (VideoCollectionEpisodeIdentity) -> Void
    let selectPage: (String, Int64) -> Void
    let retryPages: () -> Void
    let selectCommentSort: (CommentSort) -> Void
    let retryComments: () -> Void
    let loadNextComments: () -> Void
    let expandReplies: (CommentID) -> Void
    let collapseReplies: (CommentID) -> Void
    let showReplyPage: (CommentID, Int) -> Void
    let showDialog: (CommentID, BiliModels.Comment) -> Void
    let loadMoreDialog: (CommentID) -> Void
    let closeDialog: (CommentID) -> Void
    let retryReplies: (CommentID) -> Void
    let openCommentLink: (CommentLinkTarget) -> Void
    let openCommentPictures: (NativePlaybackCommentPictureGallery) -> Void
    var openUploaderSpace: (() -> Void)? = nil
    var openCommentAuthorSpace: ((CommentAuthor) -> Void)? = nil
    var setFollowing: ((Bool) -> Void)? = nil
    /// 评论行上的赞或踩（参数是点的那一个，已是它时取消）；nil 时不提供评论写入。
    var reactToComment: ((CommentID, CommentReaction) -> Void)? = nil
    /// 评论行上的「回复」：底部输入框改为回复这条评论。
    var replyToComment: ((BiliModels.Comment) -> Void)? = nil
}

/// 把侧栏控制器挂进 SwiftUI：控制器作为 coordinator 随视图创建，`dismantleNSView` 时 `tearDown`；
/// 被空间层盖住时直接隐藏 AppKit 根视图（理由见 `NativePlaybackSidebarView.isObscured`）。
private struct NativePlaybackSidebarRepresentable: NSViewRepresentable {
    let presentation: NativePlaybackSidebarPresentation
    let commentAssetURLResolver: CommentAssetURLResolver
    let commentImagePipeline: any VideoDetailImageLoading
    let isObscured: Bool
    /// 让侧栏给评论入口让位；挂上视图时把侧栏的滚动视图与布局交给它。
    let composerClearance: NativePlaybackComposerClearance
    let actions: NativePlaybackSidebarActions

    func makeCoordinator() -> NativePlaybackSidebarController {
        NativePlaybackSidebarController(
            commentAssetURLResolver: commentAssetURLResolver,
            imagePipeline: commentImagePipeline
        )
    }

    func makeNSView(context: Context) -> NativePlaybackSidebarRootView {
        context.coordinator.update(presentation: presentation, actions: actions)
        context.coordinator.rootView.isHidden = isObscured
        composerClearance.scrollView = context.coordinator.rootView.scrollView
        composerClearance.layout = context.coordinator.layout
        return context.coordinator.rootView
    }

    func updateNSView(
        _ view: NativePlaybackSidebarRootView,
        context: Context
    ) {
        context.coordinator.update(presentation: presentation, actions: actions)
        if view.isHidden != isObscured {
            view.isHidden = isObscured
        }
        composerClearance.scrollView = view.scrollView
        composerClearance.layout = context.coordinator.layout
    }

    static func dismantleNSView(
        _ view: NativePlaybackSidebarRootView,
        coordinator: NativePlaybackSidebarController
    ) {
        coordinator.tearDown()
    }
}

/// 侧栏的 AppKit 根视图：承载带“返回顶部”按钮的滚动视图，布局后把视口尺寸告诉控制器（宽度变化触发重排）。
@MainActor
final class NativePlaybackSidebarRootView: NSView {
    let scrollView = NativeScrollToTopScrollView(
        topButtonLabel: VideoDetailFeatureStrings.localized("返回顶部")
    )
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

/// 加载、失败与不可用状态盖在侧栏之上；`.none` 时不创建任何视图。
private struct NativePlaybackSidebarOverlayView: View {
    let overlay: NativePlaybackSidebarOverlay
    let retry: () -> Void

    var body: some View {
        switch overlay {
        case .none:
            EmptyView()
        case .loading(let label):
            // 占满侧栏的加载与评论首次加载、UP 主空间一样用大转圈。
            ProgressView()
                .controlSize(.large)
                .accessibilityLabel(label)
                .revealsAfterLoadingDelay()
        case .failure(let title, let message):
            ContentUnavailableView {
                Text(title)
            } description: {
                Text(message)
            } actions: {
                Button(VideoDetailFeatureStrings.localized("重试"), action: retry)
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
