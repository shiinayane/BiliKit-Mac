import BiliApplication
import BiliModels
import Foundation
import Testing

@testable import BiliVideoDetailFeature

/// 评论输入的写入契约：回复楼中楼里的回复时正文前加「回复 @昵称 : 」并带上被回复者的 @ 提及，直接回复根评论不加；
/// 发出成功后插进列表、清空草稿并要求收起，发送期间改过的草稿不清；失败保留草稿并说明；换视频后草稿与回复对象作废，
/// 不会发到另一个视频的评论区。
@Suite(.timeLimit(.minutes(1)))
@MainActor
struct PlaybackCommentWriteModelTests {
    @Test
    func replyToASubReplyCarriesPrefixMentionAndUploader() async throws {
        let fixture = try await Fixture()

        fixture.model.beginReply(to: fixture.subReply)
        fixture.model.draft = "好"
        fixture.model.send()
        let toSubReply = try #require(fixture.sent.last)
        fixture.complete(.cancelled)
        fixture.model.beginReply(to: fixture.root)
        fixture.model.send()
        let toRoot = try #require(fixture.sent.last)

        #expect(toSubReply.message == "回复 @回复者 : 好")
        #expect(toSubReply.mentions == ["回复者": 8])
        #expect(toSubReply.replyTarget?.rootID == CommentID(rawValue: 1))
        #expect(toSubReply.replyTarget?.parentID == CommentID(rawValue: 2))
        #expect(toSubReply.uploaderID == 42)
        #expect(toRoot.message == "好")
        #expect(toRoot.mentions.isEmpty)
        #expect(toRoot.replyTarget?.parentID == CommentID(rawValue: 1))
    }

    @Test
    func successInsertsClearsAndCollapsesButKeepsTextTypedWhileSending() async throws {
        let fixture = try await Fixture()
        fixture.model.expand()
        fixture.model.draft = "第一条"
        fixture.model.send()
        fixture.complete(.posted(fixture.posted(id: 90)))

        #expect(fixture.model.draft.isEmpty)
        #expect(fixture.model.collapseRequestID == 1)
        #expect(fixture.comments.threads.first?.id == CommentID(rawValue: 90))

        fixture.model.draft = "第二条"
        fixture.model.send()
        fixture.model.draft = "第二条，还在写"
        fixture.complete(.posted(fixture.posted(id: 91)))

        #expect(fixture.model.draft == "第二条，还在写")
        #expect(fixture.model.collapseRequestID == 1)

        fixture.model.send()
        fixture.complete(.failed(.restricted))
        #expect(fixture.model.draft == "第二条，还在写")
        guard case .failed(.write(let report)) = fixture.model.phase else {
            Issue.record("失败应停在说明上")
            return
        }
        #expect(report.failure == .restricted)
    }

    @Test
    func changingTheVideoDropsTheDraftAndReplyTarget() async throws {
        let fixture = try await Fixture()
        fixture.model.beginReply(to: fixture.subReply)
        fixture.model.draft = "给上一个视频的回复"

        fixture.comments.activate(subject: .video(aid: 999))
        fixture.model.subjectDidChange()

        #expect(fixture.model.draft.isEmpty)
        #expect(fixture.model.activeReplyContext == nil)
        #expect(!fixture.model.isExpanded)
    }

    /// 记下交给协调者的请求与它的结局回调。
    @MainActor
    private final class PostRecorder {
        var sent: [CommentPostRequest] = []
        var pending: (@MainActor (CommentPostOutcome) -> Void)?
    }

    /// 一个视频评论区（根评论 1 与它的回复 2）、记录请求的写入模型与手动给出的结局。
    @MainActor
    private final class Fixture {
        let comments: PlaybackCommentsViewModel
        let model: PlaybackCommentWriteModel
        let root: BiliModels.Comment
        let subReply: BiliModels.Comment
        private let recorder = PostRecorder()
        var sent: [CommentPostRequest] { recorder.sent }

        init() async throws {
            root = Self.comment(1, rootID: nil, mid: "7", name: "楼主")
            subReply = Self.comment(2, rootID: 1, mid: "8", name: "回复者")
            let page = CommentRootPage(
                threads: [CommentThread(root: root, replyPreview: [subReply])],
                totalCount: 1,
                continuation: nil,
                isEnd: true,
                inputPolicy: .open
            )
            let comments = PlaybackCommentsViewModel(
                useCase: CommentUseCase(repository: CommentRepositoryStub(rootPages: [page]))
            )
            comments.activate(subject: .video(aid: 700_001))
            await comments.waitForCurrentRootTask()
            self.comments = comments
            model = PlaybackCommentWriteModel(
                comments: comments,
                canWrite: { true },
                uploaderID: { _ in 42 },
                post: { [recorder] request, completion in
                    recorder.sent.append(request)
                    recorder.pending = completion
                    return true
                },
                react: { _, _ in false }
            )
        }

        func complete(_ outcome: CommentPostOutcome) {
            let pending = recorder.pending
            recorder.pending = nil
            pending?(outcome)
        }

        func posted(id: Int64) -> BiliModels.Comment {
            Self.comment(id, rootID: nil, mid: "42", name: "我")
        }

        private static func comment(
            _ id: Int64,
            rootID: Int64?,
            mid: String,
            name: String
        ) -> BiliModels.Comment {
            BiliModels.Comment(
                id: CommentID(rawValue: id),
                rootID: rootID.map(CommentID.init(rawValue:)),
                parentID: rootID.map(CommentID.init(rawValue:)),
                payload: .available(
                    CommentDetails(
                        author: CommentAuthor(id: CommentAuthorID(rawValue: mid), name: name),
                        content: CommentContent(message: "正文"),
                        createdAt: Date(timeIntervalSince1970: 0),
                        likeCount: 0,
                        replyCount: rootID == nil ? 1 : 0
                    )
                )
            )
        }
    }
}
