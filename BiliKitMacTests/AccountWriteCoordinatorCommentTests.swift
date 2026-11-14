import BiliApplication
import BiliModels
import Observation
import Testing

@testable import BiliKit

/// 写入协调者的评论路径：同一条评论的表态同时只有一次在途，失败先放回本地改动再在结果胶囊里说明；发评论窗口里同时只有
/// 一条在途，结局只交回输入卡片、不进结果胶囊；关窗取消在途的发评论，之后不再接受。
@Suite(.timeLimit(.minutes(1)))
@MainActor
struct AccountWriteCoordinatorCommentTests {
    private static let subject = CommentSubjectIdentity.video(aid: 700_001)

    @Test
    func reactionsOnOneCommentAreOneAtATimeAndFailuresRollBackWithAReport() async throws {
        let writes = AccountWriteRepositoryStub(outcomes: [.restricted], holdsWrites: true)
        let window = try await signedInWindow(process: makeTestProcess(), writes: writes)
        defer { window.close() }
        let target = try #require(
            CommentWriteTarget(subject: Self.subject, commentID: CommentID(rawValue: 11))
        )
        let like = try #require(CommentWriteUseCase.operation(for: target, from: .none, to: .liked))
        let dislike = try #require(
            CommentWriteUseCase.operation(for: target, from: .none, to: .disliked)
        )
        let rollbacks = RollbackCounter()

        #expect(window.accountWrites.setCommentReaction(like, rollback: rollbacks.record))
        #expect(!window.accountWrites.setCommentReaction(dislike, rollback: rollbacks.record))
        await writes.waitForCallCount(1)
        await writes.releaseWrites()
        await waitForObservedState { window.accountWrites.report != nil }

        #expect(rollbacks.count == 1)
        #expect(await writes.calls == ["comment-like 11 true 7"])
        #expect(
            window.accountWrites.report
                == AccountWriteReport(change: .commentReactionChanged(like), failure: .restricted)
        )
    }

    @Test
    func commentPostsOneAtATimeReportOnlyToTheComposerAndCloseCancels() async throws {
        let writes = AccountWriteRepositoryStub(holdsWrites: true)
        let window = try await signedInWindow(process: makeTestProcess(), writes: writes)
        let outcomes = CommentOutcomeRecorder()
        let request = try #require(
            CommentWriteUseCase.request(
                message: "好",
                subject: Self.subject,
                replyTarget: nil,
                mentions: [:],
                uploaderID: nil
            )
        )

        #expect(window.accountWrites.postComment(request, completion: outcomes.record))
        #expect(!window.accountWrites.postComment(request, completion: outcomes.record))
        await writes.waitForCallCount(1)
        await writes.releaseWrites()
        await waitForObservedState { !outcomes.values.isEmpty }

        #expect(await writes.calls == ["comment-post 700001 好 7"])
        guard case .posted(let comment) = outcomes.values.first else {
            Issue.record("发评论应交回成功")
            return
        }
        #expect(comment != nil)
        #expect(window.accountWrites.report == nil)

        let held = AccountWriteRepositoryStub(holdsWrites: true)
        let closing = try await signedInWindow(process: makeTestProcess(), writes: held)
        let cancelled = CommentOutcomeRecorder()
        closing.accountWrites.postComment(request, completion: cancelled.record)
        await held.waitForCallCount(1)
        closing.close()
        await held.releaseWrites()
        await waitForObservedState { !cancelled.values.isEmpty }

        #expect(cancelled.values == [.cancelled])
        #expect(!closing.accountWrites.postComment(request, completion: cancelled.record))
        window.close()
    }
}

/// 记录写入协调者交回输入卡片的发评论结局。
@MainActor
@Observable
private final class CommentOutcomeRecorder {
    private(set) var values: [CommentPostOutcome] = []

    func record(_ outcome: CommentPostOutcome) {
        values.append(outcome)
    }
}

/// 记录表态被放回的次数。
@MainActor
private final class RollbackCounter {
    private(set) var count = 0

    func record() {
        count += 1
    }
}
