import AppKit
import BiliApplication
import BiliModels
import SwiftUI

/// 播放页详情区：把视频与评论 ViewModel 投影成原生集合视图的呈现，用户操作转回 ViewModel 或 App 给的回调。
///
/// AppKit 集合视图的理由见 ARCHITECTURE「原生 AppKit 集合视图」；图片经 `VideoDetailImageLoading` 注入。
public struct NativePlaybackDetailsView: View {
    let model: VideoViewModel
    let commentsModel: PlaybackCommentsViewModel?
    let commentAssetURLResolver: CommentAssetURLResolver
    let commentImagePipeline: any VideoDetailImageLoading
    let onRetry: () -> Void
    let onSelectPlayback: (String, Int64?) -> Void
    let onOpenCommentLink: (CommentLinkTarget) -> Void
    let onOpenCommentPictures: (NativePlaybackCommentPictureGallery) -> Void
    /// 点击 UP 主行、评论作者（头像与昵称）或正文 @ 提及进入空间。
    let onOpenUploaderSpace: (VideoOwner) -> Void
    /// 单栏时切到右栏分页（推荐或空间）时真正隐藏原生视图：SwiftUI 的透明度与 hit testing 管不到 AppKit 的
    /// cursor rect 与 tracking area，只设透明会让评论正文继续改变指针形状。
    var isObscured: Bool

    public init(
        model: VideoViewModel,
        commentsModel: PlaybackCommentsViewModel?,
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
        self.commentsModel = commentsModel
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
        NativePlaybackDetailsRepresentable(
            presentation: presentation,
            commentAssetURLResolver: commentAssetURLResolver,
            commentImagePipeline: commentImagePipeline,
            isObscured: isObscured,
            actions: NativePlaybackDetailsActions(
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
                openCommentAuthorSpace: openUserSpace
            )
        )
        .overlay {
            NativePlaybackDetailsOverlayView(overlay: presentation.overlay, retry: retry)
        }
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

    private var presentation: NativePlaybackDetailsPresentation {
        let content = model.presentedContext.map { context in
            NativePlaybackDetailsContent(
                bvid: context.detail.bvid,
                uploader: VideoUploaderHeaderContent(
                    owner: context.detail.owner,
                    profileState: model.uploaderProfileState
                ),
                summary: context.detail.summary,
                summaryLinks: context.detail.summaryLinks,
                selection: selectionProjection(context),
                comments: commentsPresentation(context),
                timestampLimitSeconds: timestampLimitSeconds
            )
        }
        return NativePlaybackDetailsPresentation(
            content: content,
            overlay: NativePlaybackDetailsOverlay.resolve(
                state: model.state,
                hasPresentedContent: content != nil
            )
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

/// 详情区条目可以触发的全部动作：由 `NativePlaybackDetailsView` 接到 ViewModel 或 App 回调，控制器只转发。
///
/// 两个空间入口为 nil 时不显示对应入口。
struct NativePlaybackDetailsActions {
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
}

/// 把详情区控制器挂进 SwiftUI：控制器作为 coordinator 随视图创建，`dismantleNSView` 时 `tearDown`；
/// 被空间层盖住时直接隐藏 AppKit 根视图（理由见 `NativePlaybackDetailsView.isObscured`）。
private struct NativePlaybackDetailsRepresentable: NSViewRepresentable {
    let presentation: NativePlaybackDetailsPresentation
    let commentAssetURLResolver: CommentAssetURLResolver
    let commentImagePipeline: any VideoDetailImageLoading
    let isObscured: Bool
    let actions: NativePlaybackDetailsActions

    func makeCoordinator() -> NativePlaybackDetailsController {
        NativePlaybackDetailsController(
            commentAssetURLResolver: commentAssetURLResolver,
            imagePipeline: commentImagePipeline
        )
    }

    func makeNSView(context: Context) -> NativePlaybackDetailsRootView {
        context.coordinator.update(presentation: presentation, actions: actions)
        context.coordinator.rootView.isHidden = isObscured
        return context.coordinator.rootView
    }

    func updateNSView(
        _ view: NativePlaybackDetailsRootView,
        context: Context
    ) {
        context.coordinator.update(presentation: presentation, actions: actions)
        if view.isHidden != isObscured {
            view.isHidden = isObscured
        }
    }

    static func dismantleNSView(
        _ view: NativePlaybackDetailsRootView,
        coordinator: NativePlaybackDetailsController
    ) {
        coordinator.tearDown()
    }
}

/// 详情区的 AppKit 根视图：承载带“返回顶部”按钮的滚动视图，布局后把视口尺寸告诉控制器（宽度变化触发重排）。
@MainActor
final class NativePlaybackDetailsRootView: NSView {
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

/// 加载、失败与不可用状态盖在详情区之上；`.none` 时不创建任何视图。
private struct NativePlaybackDetailsOverlayView: View {
    let overlay: NativePlaybackDetailsOverlay
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
