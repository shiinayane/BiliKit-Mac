import AppKit
import BiliApplication
import BiliModels
import BiliUI
import Foundation
import Testing

@testable import BiliVideoDetailFeature

/// 侧栏快照按稳定的语义分区与行身份组织，内容变化只重载对应的行；选集与分 P 只呈现所选目录，失败时保留恢复路径。
@Suite(.serialized, .timeLimit(.minutes(1)))
struct PlaybackDetailsPresentationTests: PlaybackDetailsFixtures {
    @Test
    @MainActor
    func snapshotKeepsStableSemanticSectionsAndRows() {
        let presentation = presentation(bvid: "BVCurrent")

        #expect(
            presentation.sections.map(\.id)
                == [.uploader, .summary, .selection, .comments]
        )
        #expect(
            presentation.itemIDs
                == [
                    .uploader(bvid: "BVCurrent"),
                    .summary(bvid: "BVCurrent"),
                    .selection(bvid: "BVCurrent"),
                    .commentsHeader(subject: nil),
                    .commentsState(subject: nil, kind: .idle)
                ]
        )
    }

    @Test
    @MainActor
    func browsingAnotherSectionKeepsPagesOnlyForTheSelectedEpisodeSection() {
        let collection = VideoCollection(
            id: 1,
            title: "合集",
            reportedEpisodeCount: 2,
            sections: [
                collectionSection(
                    id: 10,
                    title: "正片",
                    episodes: [
                        collectionEpisode(
                            sectionID: 10,
                            episodeID: 100,
                            bvid: "BVCurrent",
                            title: "第一集"
                        )
                    ]
                ),
                collectionSection(
                    id: 11,
                    title: "花絮",
                    episodes: [
                        collectionEpisode(
                            sectionID: 11,
                            episodeID: 101,
                            bvid: "BVOther",
                            title: "幕后花絮"
                        )
                    ]
                )
            ]
        )
        let projection = selectionProjection(
            context: context(bvid: "BVCurrent", collection: collection)
        )
        let selectedSectionHeight = NativePlaybackDetailsItemMeasurement.selection(
            projection,
            width: 328,
            browsedSectionID: projection.selectedEpisodeSectionID
        )
        let otherSectionHeight = NativePlaybackDetailsItemMeasurement.selection(
            projection,
            width: 328,
            browsedSectionID: collection.sections[1].id
        )

        #expect(projection.showsSectionPicker)
        #expect(
            projection.episodeSections.map { $0.episodes.map(\.title) }
                == [["第一集"], ["幕后花絮"]]
        )
        #expect(projection.selectedEpisodeSectionID == collection.sections[0].id)
        #expect(projection.showsPagePicker)
        #expect(otherSectionHeight < selectedSectionHeight)
    }

    @Test
    @MainActor
    func retainedFailedPageKeepsSelectionAvailableAsARecoveryPath() {
        let context = context(bvid: "BVCurrent")
        let failure = VideoLoadFailure.playback

        #expect(
            NativePlaybackDetailsOverlay.resolve(
                state: .failedPage(
                    context: context,
                    targetPage: context.pages[1],
                    failure: failure
                ),
                hasPresentedContent: true
            ) == .none
        )
    }

    /// 内容不存在或不可见时重试不会改变结果：侧栏只说明原因，不给重试按钮。
    @Test
    @MainActor
    func unavailableContentFailureOffersNoRetry() {
        let failure = VideoLoadFailure.content(.contentUnavailable)
        let retryable = VideoLoadFailure.content(.transportFailure)

        #expect(
            NativePlaybackDetailsOverlay.resolve(
                state: .failed(bvid: "BVGone", failure: failure),
                hasPresentedContent: false
            ) == .unavailable(title: failure.title, message: failure.message)
        )
        #expect(
            NativePlaybackDetailsOverlay.resolve(
                state: .failed(bvid: "BVGone", failure: retryable),
                hasPresentedContent: false
            ) == .failure(title: retryable.title, message: retryable.message)
        )
    }

    @Test
    @MainActor
    func presentationReloadsOnlyTheStableRowWhoseContentChanged() throws {
        let original = presentation(bvid: "BVCurrent")
        let content = try #require(original.content)
        let updatedUploader = NativePlaybackDetailsPresentation(
            content: NativePlaybackDetailsContent(
                bvid: content.bvid,
                uploader: VideoUploaderHeaderContent(
                    owner: VideoOwner(id: 1, name: "UP 主"),
                    profileState: .loaded(UploaderProfile(signature: "新签名"))
                ),
                summary: content.summary,
                summaryLinks: content.summaryLinks,
                selection: content.selection,
                comments: content.comments,
                timestampLimitSeconds: nil
            ),
            overlay: .none
        )
        let overlayOnly = NativePlaybackDetailsPresentation(
            content: content,
            overlay: .loading(label: "正在加载所选视频上下文")
        )

        #expect(
            updatedUploader.changedItemIDs(comparedTo: original)
                == [.uploader(bvid: content.bvid)]
        )
        #expect(overlayOnly.changedItemIDs(comparedTo: original).isEmpty)
    }

    /// 分 P 菜单项在标题为空时省略标题段，不出现「P1 ·  · 时长」。
    @Test
    @MainActor
    func pageMenuTitleOmitsAnEmptyPartTitle() {
        #expect(
            NativePlaybackDetailsSelectionItem.pageMenuTitle(
                index: 1,
                title: "第一部分",
                durationSeconds: 61
            ) == "P1 · 第一部分 · " + VideoDurationFormatting.string(seconds: 61)
        )
        #expect(
            NativePlaybackDetailsSelectionItem.pageMenuTitle(
                index: 2,
                title: " ",
                durationSeconds: 988
            ) == "P2 · " + VideoDurationFormatting.string(seconds: 988)
        )
    }

    @Test
    @MainActor
    func collectionUpdatePolicySeparatesStableRowsFromCommentAppend() async throws {
        let subject = CommentSubjectIdentity.video(aid: 700_001)
        let first = commentThread(id: 1, message: "第一条评论")
        let original = presentation(
            bvid: "BVCurrent",
            comments: await commentsPresentation(subject: subject, threads: [first])
        )
        let changed = presentation(
            bvid: "BVCurrent",
            comments: await commentsPresentation(
                subject: subject,
                threads: [commentThread(id: 1, message: "修改后的正文")]
            )
        )
        let appended = presentation(
            bvid: "BVCurrent",
            comments: await commentsPresentation(
                subject: subject,
                threads: [first, commentThread(id: 2, message: "第二条评论")]
            )
        )

        #expect(
            NativePlaybackDetailsCollectionUpdatePolicy.resolve(
                current: original.snapshotSections,
                next: original.snapshotSections,
                changedItemIDs: [],
                hasSnapshotInFlight: false
            ) == .none
        )
        #expect(
            NativePlaybackDetailsCollectionUpdatePolicy.resolve(
                current: original.snapshotSections,
                next: changed.snapshotSections,
                changedItemIDs: changed.changedItemIDs(comparedTo: original),
                hasSnapshotInFlight: false
            ) == .reloadChangedItems
        )
        #expect(
            NativePlaybackDetailsCollectionUpdatePolicy.resolve(
                current: original.snapshotSections,
                next: appended.snapshotSections,
                changedItemIDs: appended.changedItemIDs(comparedTo: original),
                hasSnapshotInFlight: false
            ) == .appendComments
        )
        #expect(
            NativePlaybackDetailsCollectionUpdatePolicy.resolve(
                current: original.snapshotSections,
                next: appended.snapshotSections,
                changedItemIDs: appended.changedItemIDs(comparedTo: original),
                hasSnapshotInFlight: true
            ) == .replaceSnapshot
        )
    }

    @Test
    @MainActor
    func commentsUseStableSubjectAndRootIDsAcrossAppend() async {
        let subject = CommentSubjectIdentity.video(aid: 700_001)
        let first = commentThread(id: 1, message: "第一条评论")
        let second = commentThread(id: 2, message: "第二条评论")
        let initial = await commentsPresentation(subject: subject, threads: [first])
        let appended = await commentsPresentation(subject: subject, threads: [first, second])

        #expect(
            commentItemIDs(initial)
                == [
                    .commentsHeader(subject: subject),
                    .commentThread(subject: subject, rootID: first.id),
                    .commentsFooter(subject: subject)
                ]
        )
        #expect(
            Array(commentItemIDs(appended).prefix(2)) == Array(commentItemIDs(initial).prefix(2))
        )
        #expect(
            commentItemIDs(appended)[2]
                == .commentThread(subject: subject, rootID: second.id)
        )
    }

    @Test
    @MainActor
    func commentRevisionTracksRenderedVerificationLinksAndPictures() {
        let subject = CommentSubjectIdentity.video(aid: 700_001)
        let message = "查看视频"
        let range = CommentTextRange(location: 0, length: 4)
        let plainAuthor = CommentAuthor(
            id: CommentAuthorID(rawValue: "author"),
            name: "评论者"
        )
        let verifiedAuthor = CommentAuthor(
            id: CommentAuthorID(rawValue: "author"),
            name: "评论者",
            verification: .personal(description: "认证")
        )
        let avatarAuthor = CommentAuthor(
            id: CommentAuthorID(rawValue: "author"),
            name: "评论者",
            avatar: fixtureAssetReference()
        )
        let plain = NativePlaybackCommentThreadPresentation(
            subject: subject,
            thread: commentThread(id: 1, message: message, author: plainAuthor),
            replyState: nil
        )
        let verified = NativePlaybackCommentThreadPresentation(
            subject: subject,
            thread: commentThread(id: 1, message: message, author: verifiedAuthor),
            replyState: nil
        )
        let avatar = NativePlaybackCommentThreadPresentation(
            subject: subject,
            thread: commentThread(id: 1, message: message, author: avatarAuthor),
            replyState: nil
        )
        let linked = NativePlaybackCommentThreadPresentation(
            subject: subject,
            thread: commentThread(
                id: 1,
                message: message,
                links: [
                    CommentLink(
                        range: range,
                        target: .video(bvid: "BV1FixtureA1", page: nil, startSeconds: nil)
                    )
                ],
                author: verifiedAuthor
            ),
            replyState: nil
        )
        let pictured = NativePlaybackCommentThreadPresentation(
            subject: subject,
            thread: commentThread(
                id: 1,
                message: message,
                links: [
                    CommentLink(
                        range: range,
                        target: .video(bvid: "BV1FixtureA1", page: nil, startSeconds: nil)
                    )
                ],
                pictures: [CommentImage(asset: fixtureAssetReference())],
                author: verifiedAuthor
            ),
            replyState: nil
        )

        #expect(plain.revision != avatar.revision)
        #expect(plain.revision != verified.revision)
        #expect(verified.revision != linked.revision)
        #expect(linked.revision != pictured.revision)
    }
}
