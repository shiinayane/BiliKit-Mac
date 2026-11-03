import AppKit
import BiliApplication
import BiliModels
import BiliUI
import Foundation
import Testing

@testable import BiliVideoDetailFeature

/// 侧栏各 Suite 共用的呈现、评论与视频上下文构造；Suite 遵循本协议即可直接调用，不各自复制。
protocol PlaybackSidebarFixtures {}

extension PlaybackSidebarFixtures {
    @MainActor
    var actions: NativePlaybackSidebarActions { sidebarActions() }

    /// 侧栏动作：只有 `loadNextComments` 可替换，其余都不做事。
    @MainActor
    func sidebarActions(
        loadNextComments: @escaping () -> Void = {}
    ) -> NativePlaybackSidebarActions {
        NativePlaybackSidebarActions(
            selectEpisode: { _ in },
            selectPage: { _, _ in },
            retryPages: {},
            selectCommentSort: { _ in },
            retryComments: {},
            loadNextComments: loadNextComments,
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
    }

    @MainActor
    func presentation(bvid: String) -> NativePlaybackSidebarPresentation {
        presentation(
            bvid: bvid,
            comments: NativePlaybackCommentsPresentation(model: nil)
        )
    }

    @MainActor
    func presentation(
        bvid: String,
        comments: NativePlaybackCommentsPresentation
    ) -> NativePlaybackSidebarPresentation {
        let context = context(bvid: bvid)
        return NativePlaybackSidebarPresentation(
            content: NativePlaybackSidebarContent(
                bvid: bvid,
                uploader: VideoUploaderHeaderContent(
                    owner: context.detail.owner,
                    profileState: .loaded(
                        UploaderProfile(signature: "签名")
                    )
                ),
                summary: context.detail.summary,
                summaryLinks: context.detail.summaryLinks,
                selection: selectionProjection(context: context),
                comments: comments,
                timestampLimitSeconds: nil
            ),
            overlay: .none
        )
    }

    /// 已加载的评论区，经 ViewModel 的真实加载得到；`isLoadingNextPage` 时下一页请求挂起中。
    @MainActor
    func commentsPresentation(
        subject: CommentSubjectIdentity,
        threads: [CommentThread],
        isLoadingNextPage: Bool = false
    ) async -> NativePlaybackCommentsPresentation {
        await liveCommentsPresentation(
            subject: subject,
            threads: threads,
            next: isLoadingNextPage ? .loading : .available
        )
    }

    @MainActor
    func commentItemIDs(
        _ comments: NativePlaybackCommentsPresentation
    ) -> [NativePlaybackSidebarItemID] {
        let base = presentation(bvid: "BVCurrent")
        guard let content = base.content else { return [] }
        return NativePlaybackSidebarPresentation(
            content: NativePlaybackSidebarContent(
                bvid: content.bvid,
                uploader: content.uploader,
                summary: content.summary,
                summaryLinks: content.summaryLinks,
                selection: content.selection,
                comments: comments,
                timestampLimitSeconds: nil
            ),
            overlay: .none
        ).sections.first { $0.id == .comments }?.items ?? []
    }

    func commentThread(
        id: Int64,
        message: String,
        links: [CommentLink] = [],
        pictures: [CommentImage] = [],
        pictureCount: Int? = nil,
        replyCount: Int = 0,
        preview: [BiliModels.Comment] = [],
        author: CommentAuthor? = nil,
        provenance: [CommentProvenance] = []
    ) -> CommentThread {
        CommentThread(
            root: comment(
                id: id,
                message: message,
                links: links,
                pictures: pictures,
                pictureCount: pictureCount,
                replyCount: replyCount,
                author: author,
                provenance: provenance
            ),
            replyPreview: preview
        )
    }

    func comment(
        id: Int64,
        rootID: Int64? = nil,
        message: String,
        links: [CommentLink] = [],
        pictures: [CommentImage] = [],
        pictureCount: Int? = nil,
        replyCount: Int = 0,
        author: CommentAuthor? = nil,
        provenance: [CommentProvenance] = []
    ) -> BiliModels.Comment {
        BiliModels.Comment(
            id: CommentID(rawValue: id),
            rootID: rootID.map { CommentID(rawValue: $0) },
            payload: .available(
                CommentDetails(
                    author: author
                        ?? CommentAuthor(
                            id: CommentAuthorID(rawValue: "author-\(id)"),
                            name: "评论者\(id)",
                            level: 6,
                            isVIP: true
                        ),
                    content: CommentContent(
                        message: message,
                        links: links,
                        pictures: pictures,
                        pictureCount: pictureCount
                    ),
                    createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                    location: "东京",
                    likeCount: 42,
                    replyCount: replyCount,
                    provenance: provenance
                )
            )
        )
    }

    @MainActor
    func selectionProjection(
        context: VideoContext? = nil
    ) -> PlaybackSelectionProjection {
        let context = context ?? self.context(bvid: "BVCurrent")
        return PlaybackSelectionProjection(
            context: context,
            selectedEpisodeID: nil,
            requestedBVID: context.detail.bvid,
            requestedCID: context.pages.first?.cid,
            presentedIdentity: nil,
            pageStates: [:],
            pagesByEpisode: [:]
        )
    }

    func context(
        bvid: String,
        collection: VideoCollection? = nil
    ) -> VideoContext {
        makeVideoContext(
            detail: makeVideoDetail(
                bvid: bvid,
                summary: "一段可选择、可精确换行的简介正文。",
                owner: VideoOwner(id: 1, name: "UP 主"),
                pages: [
                    VideoPage(cid: 1_001, index: 1, title: "第一部分", durationSeconds: 61),
                    VideoPage(cid: 1_002, index: 2, title: "第二部分", durationSeconds: 122)
                ],
                collection: collection
            )
        )
    }

    @MainActor
    func makeCommentTextRenderer(
        resolveURL: @escaping CommentAssetURLResolver = { _, _ in nil }
    ) -> NativePlaybackCommentTextRenderer {
        NativePlaybackCommentTextRenderer(
            imagePipeline: StubVideoDetailImageLoader(),
            resolveURL: resolveURL
        )
    }

    /// 按评论行自己的测量高度（宽 408）装配一条评论行并完成布局；取图全部未命中，没传的回调都不做事。
    @MainActor
    func configureThreadItem(
        _ item: NativePlaybackCommentThreadItem,
        with row: NativePlaybackCommentThreadPresentation,
        onShowDialog: @escaping (BiliModels.Comment) -> Void = { _ in },
        onCloseDialog: @escaping () -> Void = {},
        onOpenPictures: @escaping (NativePlaybackCommentPictureGallery) -> Void = { _ in },
        onOpenAuthorSpace: ((CommentAuthor) -> Void)? = nil
    ) {
        item.view.frame = NSRect(
            x: 0,
            y: 0,
            width: 408,
            height: NativePlaybackCommentsItemMeasurement.thread(row, width: 408)
        )
        item.configure(
            presentation: row,
            textRenderer: makeCommentTextRenderer(),
            avatarLoader: NativePlaybackCommentAvatarLoader(
                imagePipeline: StubVideoDetailImageLoader(),
                resolveURL: { _, _ in nil }
            ),
            pictureLoader: NativePlaybackCommentPictureLoader(
                imagePipeline: StubVideoDetailImageLoader(),
                resolveURL: { _, _ in nil }
            ),
            onTextLayoutChange: {},
            onExpand: {},
            onCollapse: {},
            onShowPage: { _ in },
            onRetry: {},
            onShowDialog: onShowDialog,
            onLoadMoreDialog: {},
            onCloseDialog: onCloseDialog,
            onOpenLink: { _ in },
            onOpenPictures: onOpenPictures,
            onOpenAuthorSpace: onOpenAuthorSpace
        )
        item.view.layoutSubtreeIfNeeded()
    }
}

/// 挂在真实窗口（440×600）里的侧栏控制器，供需要真实滚动与布局的 Suite 共用。
///
/// 只持有控制器与窗口；`tearDown` 先拆控制器、再卸下窗口内容，测试结束前必须调用。
@MainActor
struct HostedPlaybackSidebar: PlaybackSidebarFixtures {
    let controller = makeSidebarController()
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 440, height: 600),
        styleMask: .borderless,
        backing: .buffered,
        defer: false
    )

    init() {
        window.contentView = controller.rootView
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
    }

    /// 可见区顶边，已扣除顶部内容缩进。
    var visibleTop: CGFloat {
        controller.rootView.scrollView.documentVisibleRect.minY
            + max(0, controller.rootView.scrollView.contentInsets.top)
    }

    func tearDown() {
        controller.tearDown()
        window.contentView = nil
    }
}
