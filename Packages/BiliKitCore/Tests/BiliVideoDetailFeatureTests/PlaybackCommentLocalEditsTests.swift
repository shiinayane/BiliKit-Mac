import BiliApplication
import BiliModels
import Foundation
import Testing

@testable import BiliVideoDetailFeature

/// 评论区的本地改动：乐观表态同时改到同一条评论的每一处出现，并按赞踩互斥调整点赞数；回滚只在同一工作集、评论仍是
/// 改动后的样子时放回；刚发出的评论插到列表或所属楼的最前并标为自己发的，回复让根评论的回复数加一。
@Suite(.timeLimit(.minutes(1)))
struct PlaybackCommentLocalEditsTests {
    @Test
    @MainActor
    func reactionEditsEveryOccurrenceAndRevertsOnlyInTheSameWorkset() async throws {
        let model = try await loadedModel()

        let edit = try #require(model.applyReaction(.disliked, to: CommentID(rawValue: 2)))
        #expect(model.reaction(of: CommentID(rawValue: 2)) == .disliked)
        // 原本已赞：点踩同时取消点赞，点赞数减一。
        #expect(likeCount(of: model.threads[0].replyPreview[0]) == 4)

        model.revertReaction(edit)
        #expect(model.reaction(of: CommentID(rawValue: 2)) == .liked)
        #expect(likeCount(of: model.threads[0].replyPreview[0]) == 5)

        // 换排序重载后，旧工作集的回滚不能盖掉之后的新改动。
        let staleEdit = try #require(model.applyReaction(.none, to: CommentID(rawValue: 1)))
        model.selectSort(.latest)
        await model.waitForCurrentRootTask()
        _ = model.applyReaction(.disliked, to: CommentID(rawValue: 1))
        model.revertReaction(staleEdit)
        #expect(model.reaction(of: CommentID(rawValue: 1)) == .disliked)
    }

    @Test
    @MainActor
    func postedCommentsAreInsertedFirstAndMarkedAsOwn() async throws {
        let model = try await loadedModel()

        model.insertPostedComment(available(10), subject: .video(aid: 700_001))
        model.insertPostedComment(
            available(11, rootID: 1, parentID: 1),
            subject: .video(aid: 700_001)
        )
        model.insertPostedComment(available(12), subject: .video(aid: 999))

        #expect(model.threads.map(\.id.rawValue) == [10, 1])
        #expect(model.threads[1].replyPreview.map(\.id.rawValue) == [11, 2])
        guard case .available(let root) = model.threads[1].root.payload,
            case .available(let posted) = model.threads[0].root.payload
        else {
            Issue.record("评论应可见")
            return
        }
        #expect(root.replyCount == 2)
        #expect(posted.provenance.contains(.postedByViewer))
    }

    /// 正在看「查看对话」时发出的回复：属于这串对话就接在对话末尾，否则进当前页最前，关掉对话后能看到。
    @Test
    @MainActor
    func replyPostedWhileViewingADialogLandsWhereItCanBeSeen() async throws {
        let model = try await loadedModel()
        var state = PlaybackCommentReplyState()
        state.isExpanded = true
        var dialog = PlaybackCommentDialogState(dialogID: CommentID(rawValue: 2))
        dialog.replies = [available(2, rootID: 1, parentID: 1)]
        state.dialog = dialog
        model.replyStates[CommentID(rawValue: 1)] = state

        model.insertPostedComment(
            available(20, rootID: 1, parentID: 2, dialogID: 2),
            subject: .video(aid: 700_001)
        )
        model.insertPostedComment(
            available(21, rootID: 1, parentID: 1, dialogID: 21),
            subject: .video(aid: 700_001)
        )

        let shown = try #require(model.replyStates[CommentID(rawValue: 1)])
        #expect(shown.dialog?.replies.map(\.id.rawValue) == [2, 20])
        #expect(shown.replies.map(\.id.rawValue) == [21])
    }

    /// 下一页在途时插入刚发出的评论、这一页又带回它：列表里只能有一份（同一 ID 出现两次会让侧栏的集合视图崩溃）；
    /// 根评论重载期间（换排序）不插入，交给重载带回。
    @Test
    @MainActor
    func postedCommentNeverDuplicatesARootThread() async throws {
        let repository = CommentRepositoryStub(
            rootPages: [
                CommentRootPage(
                    threads: [CommentThread(root: available(1))],
                    totalCount: 3,
                    continuation: CommentContinuation(rawValue: "next"),
                    isEnd: false,
                    inputPolicy: .open
                )
            ],
            holdsRoots: true,
            answeredRootRequestCount: 1
        )
        let model = PlaybackCommentsViewModel(useCase: CommentUseCase(repository: repository))
        model.activate(subject: .video(aid: 700_001))
        await model.waitForCurrentRootTask()

        model.loadNextPage()
        await repository.waitForRootRequestCount(2)
        model.insertPostedComment(available(90), subject: .video(aid: 700_001))
        await repository.releaseAllHeldRoots(
            page: CommentRootPage(
                threads: [CommentThread(root: available(90)), CommentThread(root: available(2))],
                totalCount: 3,
                continuation: nil,
                isEnd: true,
                inputPolicy: .open
            )
        )
        await model.waitForCurrentRootTask()
        #expect(model.threads.map(\.id.rawValue) == [90, 1, 2])

        model.selectSort(.latest)
        model.insertPostedComment(available(91), subject: .video(aid: 700_001))
        #expect(!model.threads.contains { $0.id == CommentID(rawValue: 91) })
    }

    @MainActor
    private func loadedModel() async throws -> PlaybackCommentsViewModel {
        let page = CommentRootPage(
            threads: [
                CommentThread(
                    root: available(1, likes: 3, replyCount: 1, reaction: .liked),
                    replyPreview: [available(2, rootID: 1, parentID: 1, likes: 5, reaction: .liked)]
                )
            ],
            totalCount: 1,
            continuation: nil,
            isEnd: true,
            inputPolicy: .open
        )
        let model = PlaybackCommentsViewModel(
            useCase: CommentUseCase(repository: CommentRepositoryStub(rootPages: [page, page]))
        )
        model.activate(subject: .video(aid: 700_001))
        await model.waitForCurrentRootTask()
        return model
    }
}

private func likeCount(of comment: BiliModels.Comment) -> Int64? {
    guard case .available(let details) = comment.payload else { return nil }
    return details.likeCount
}

private func available(
    _ id: Int64,
    rootID: Int64? = nil,
    parentID: Int64? = nil,
    dialogID: Int64? = nil,
    likes: Int64 = 0,
    replyCount: Int = 0,
    reaction: CommentReaction = .none
) -> BiliModels.Comment {
    BiliModels.Comment(
        id: CommentID(rawValue: id),
        rootID: rootID.map(CommentID.init(rawValue:)),
        parentID: parentID.map(CommentID.init(rawValue:)),
        dialogID: dialogID.map(CommentID.init(rawValue:)),
        payload: .available(
            CommentDetails(
                author: CommentAuthor(id: CommentAuthorID(rawValue: "7"), name: "作者"),
                content: CommentContent(message: "正文"),
                createdAt: Date(timeIntervalSince1970: 0),
                likeCount: likes,
                replyCount: replyCount,
                viewerReaction: reaction
            )
        )
    )
}
