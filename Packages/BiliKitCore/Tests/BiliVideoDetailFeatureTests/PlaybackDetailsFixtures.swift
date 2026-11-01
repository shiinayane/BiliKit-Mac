import AppKit
import BiliApplication
import BiliModels
import BiliUI
import Foundation
import Testing

@testable import BiliVideoDetailFeature

/// 侧栏各 Suite 共用的呈现、评论与视频上下文构造；Suite 遵循本协议即可直接调用，不各自复制。
protocol PlaybackDetailsFixtures {}

extension PlaybackDetailsFixtures {
    @MainActor
    var actions: NativePlaybackDetailsActions {
        NativePlaybackDetailsActions(
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
    }

    @MainActor
    func presentation(bvid: String) -> NativePlaybackDetailsPresentation {
        presentation(
            bvid: bvid,
            comments: NativePlaybackCommentsPresentation(model: nil)
        )
    }

    @MainActor
    func presentation(
        bvid: String,
        comments: NativePlaybackCommentsPresentation
    ) -> NativePlaybackDetailsPresentation {
        let context = context(bvid: bvid)
        return NativePlaybackDetailsPresentation(
            content: NativePlaybackDetailsContent(
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
    ) -> [NativePlaybackDetailsItemID] {
        let base = presentation(bvid: "BVCurrent")
        guard let content = base.content else { return [] }
        return NativePlaybackDetailsPresentation(
            content: NativePlaybackDetailsContent(
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

    func heightKey(rootID: Int64) -> NativePlaybackDetailsHeightCacheKey {
        NativePlaybackDetailsHeightCacheKey(
            itemID: .commentThread(
                subject: .video(aid: 700_001),
                rootID: CommentID(rawValue: rootID)
            ),
            widthBucket: 816,
            revision: Int(rootID)
        )
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

    func collectionSection(
        id: Int64,
        title: String,
        episodes: [VideoCollectionEpisode]
    ) -> VideoCollectionSection {
        VideoCollectionSection(
            id: VideoCollectionSectionIdentity(seasonID: 1, sectionID: id),
            ordinal: Int(id - 10),
            title: title,
            episodes: episodes
        )
    }

    func collectionEpisode(
        sectionID: Int64,
        episodeID: Int64,
        bvid: String,
        title: String
    ) -> VideoCollectionEpisode {
        VideoCollectionEpisode(
            id: VideoCollectionEpisodeIdentity(
                seasonID: 1,
                sectionID: sectionID,
                episodeID: episodeID
            ),
            ordinal: Int(episodeID - 100),
            aid: nil,
            bvid: bvid,
            title: title,
            coverURL: nil,
            durationSeconds: 122,
            defaultCID: 1_001,
            knownPages: [
                VideoPage(
                    cid: 1_001,
                    index: 1,
                    title: "第一部分",
                    durationSeconds: 61
                )
            ]
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

    @MainActor
    func makeCommentAvatarLoader(
        resolveURL: @escaping CommentAssetURLResolver = { _, _ in nil }
    ) -> NativePlaybackCommentAvatarLoader {
        NativePlaybackCommentAvatarLoader(
            imagePipeline: StubVideoDetailImageLoader(),
            resolveURL: resolveURL
        )
    }

    @MainActor
    func makeCommentPictureLoader(
        resolveURL: @escaping CommentAssetURLResolver = { _, _ in nil }
    ) -> NativePlaybackCommentPictureLoader {
        NativePlaybackCommentPictureLoader(
            imagePipeline: StubVideoDetailImageLoader(),
            resolveURL: resolveURL
        )
    }
}
