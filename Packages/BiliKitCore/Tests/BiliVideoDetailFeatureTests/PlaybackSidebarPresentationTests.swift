import AppKit
import BiliApplication
import BiliModels
import BiliUI
import Foundation
import Testing

@testable import BiliVideoDetailFeature

/// 侧栏快照按稳定的语义分区与行身份组织，内容变化只重载对应的行，分 P 时长变化只重载含时间戳的简介与评论；选集与分 P 只呈现所选目录，失败时保留恢复路径。
@Suite(.serialized, .timeLimit(.minutes(1)))
struct PlaybackSidebarPresentationTests: PlaybackSidebarFixtures {
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
        let collection = makeTestCollection(sections: [
            [
                makeTestEpisode(
                    ordinal: 0,
                    bvid: "BVCurrent",
                    pages: [makeTestPage(1)],
                    title: "第一集"
                )
            ],
            [
                makeTestEpisode(
                    ordinal: 1,
                    bvid: "BVOther",
                    pages: [makeTestPage(1)],
                    section: 1,
                    title: "幕后花絮"
                )
            ]
        ])
        let projection = selectionProjection(
            context: context(bvid: "BVCurrent", collection: collection)
        )
        let selectedSectionHeight = NativePlaybackSidebarItemMeasurement.selection(
            projection,
            width: 328,
            browsedSectionID: projection.selectedEpisodeSectionID
        )
        let otherSectionHeight = NativePlaybackSidebarItemMeasurement.selection(
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
            NativePlaybackSidebarOverlay.resolve(
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
            NativePlaybackSidebarOverlay.resolve(
                state: .failed(bvid: "BVGone", failure: failure),
                hasPresentedContent: false
            ) == .unavailable(title: failure.title, message: failure.message)
        )
        #expect(
            NativePlaybackSidebarOverlay.resolve(
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
        let updatedUploader = NativePlaybackSidebarPresentation(
            content: NativePlaybackSidebarContent(
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
        let overlayOnly = NativePlaybackSidebarPresentation(
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
            NativePlaybackSidebarSelectionItem.pageMenuTitle(
                index: 1,
                title: "第一部分",
                durationSeconds: 61
            ) == "P1 · 第一部分 · " + VideoDurationFormatting.string(seconds: 61)
        )
        #expect(
            NativePlaybackSidebarSelectionItem.pageMenuTitle(
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
            NativePlaybackSidebarCollectionUpdatePolicy.resolve(
                current: original.snapshotSections,
                next: original.snapshotSections,
                changedItemIDs: [],
                hasSnapshotInFlight: false
            ) == .none
        )
        #expect(
            NativePlaybackSidebarCollectionUpdatePolicy.resolve(
                current: original.snapshotSections,
                next: changed.snapshotSections,
                changedItemIDs: changed.changedItemIDs(comparedTo: original),
                hasSnapshotInFlight: false
            ) == .reloadChangedItems
        )
        #expect(
            NativePlaybackSidebarCollectionUpdatePolicy.resolve(
                current: original.snapshotSections,
                next: appended.snapshotSections,
                changedItemIDs: appended.changedItemIDs(comparedTo: original),
                hasSnapshotInFlight: false
            ) == .appendComments
        )
        #expect(
            NativePlaybackSidebarCollectionUpdatePolicy.resolve(
                current: original.snapshotSections,
                next: appended.snapshotSections,
                changedItemIDs: appended.changedItemIDs(comparedTo: original),
                hasSnapshotInFlight: true
            ) == .replaceSnapshot
        )
    }

    /// 切换分 P 后可跳转上限变化：只有含时间戳链接的简介与评论重新配置，链接随之更新；行高不变，更新方式与
    /// 正文修改相同；简介链接本身变化照常重载简介。
    @Test
    @MainActor
    func timestampLimitChangeReconfiguresOnlyRowsWithTimestamps() async throws {
        let subject = CommentSubjectIdentity.video(aid: 700_001)
        let timestamp = CommentLink(
            range: CommentTextRange(location: 0, length: 4),
            target: .timestamp(seconds: 60)
        )
        let comments = await commentsPresentation(
            subject: subject,
            threads: [
                commentThread(id: 1, message: "1:00", links: [timestamp]),
                commentThread(id: 2, message: "第二条")
            ]
        )
        let base = try #require(presentation(bvid: "BVCurrent", comments: comments).content)
        func limited(
            _ seconds: Int?,
            summaryLinks: [CommentLink]
        ) -> NativePlaybackSidebarPresentation {
            NativePlaybackSidebarPresentation(
                content: NativePlaybackSidebarContent(
                    bvid: base.bvid,
                    uploader: base.uploader,
                    summary: "1:00 开始",
                    summaryLinks: summaryLinks,
                    selection: base.selection,
                    comments: base.comments,
                    timestampLimitSeconds: seconds
                ),
                overlay: .none
            )
        }
        let timedThread = NativePlaybackSidebarItemID.commentThread(
            subject: subject,
            rootID: CommentID(rawValue: 1)
        )
        let short = limited(120, summaryLinks: [timestamp])
        let long = limited(600, summaryLinks: [timestamp])
        let changed = long.changedItemIDs(comparedTo: short)

        #expect(changed == [.summary(bvid: "BVCurrent"), timedThread])
        #expect(limited(120, summaryLinks: [timestamp]).changedItemIDs(comparedTo: short).isEmpty)
        #expect(
            limited(600, summaryLinks: [])
                .changedItemIDs(comparedTo: limited(120, summaryLinks: []))
                == [timedThread]
        )
        #expect(
            limited(120, summaryLinks: [timestamp])
                .changedItemIDs(comparedTo: limited(120, summaryLinks: []))
                == [.summary(bvid: "BVCurrent")]
        )
        #expect(
            NativePlaybackSidebarCollectionUpdatePolicy.resolve(
                current: short.snapshotSections,
                next: long.snapshotSections,
                changedItemIDs: changed,
                hasSnapshotInFlight: false
            ) == .reloadChangedItems
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

    /// 点赞数与赞踩不进 `revision`（正文渲染作用域与行高缓存键），只进 `reactionRevision`；这一楼仍算变化、会被重新配置。
    @Test
    @MainActor
    func reactionChangeRefreshesTheRowWithoutChangingItsContentRevision() async throws {
        let subject = CommentSubjectIdentity.video(aid: 700_001)
        let thread = commentThread(id: 1, message: "正文")
        var reacted = thread
        guard case .available(var details) = reacted.root.payload else {
            Issue.record("评论应可见")
            return
        }
        details.likeCount += 1
        details.viewerReaction = .liked
        reacted.root.payload = .available(details)

        let original = await commentsPresentation(subject: subject, threads: [thread])
        let changed = await commentsPresentation(subject: subject, threads: [reacted])
        let before = try #require(original.threads.first)
        let after = try #require(changed.threads.first)

        #expect(after.revision == before.revision)
        #expect(after.reactionRevision != before.reactionRevision)
        #expect(
            sidebarPresentation(comments: changed)
                .changedItemIDs(comparedTo: sidebarPresentation(comments: original))
                == [.commentThread(subject: subject, rootID: thread.id)]
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
            replyState: nil,
            writeAvailability: .unavailable
        )
        let verified = NativePlaybackCommentThreadPresentation(
            subject: subject,
            thread: commentThread(id: 1, message: message, author: verifiedAuthor),
            replyState: nil,
            writeAvailability: .unavailable
        )
        let avatar = NativePlaybackCommentThreadPresentation(
            subject: subject,
            thread: commentThread(id: 1, message: message, author: avatarAuthor),
            replyState: nil,
            writeAvailability: .unavailable
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
            replyState: nil,
            writeAvailability: .unavailable
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
            replyState: nil,
            writeAvailability: .unavailable
        )

        #expect(plain.revision != avatar.revision)
        #expect(plain.revision != verified.revision)
        #expect(verified.revision != linked.revision)
        #expect(linked.revision != pictured.revision)
    }
}
