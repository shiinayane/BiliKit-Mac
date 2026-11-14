import BiliApplication
import BiliModels
import Foundation

/// `CommentRepository` 的 B 站实现：根评论、楼中楼与对话读取、错误映射，以及根评论分页游标与
/// continuation 的映射。
///
/// 每个窗口一个（`WindowAdapters.live`）。actor 拥有游标表：服务端 offset 不越过 adapter，
/// Application 只见随机 UUID continuation；同一游标复用同一 token，表按发出顺序最多保留
/// `maximumRetainedCursors` 条。continuation 必须与发出时的评论对象和排序一致，不认识（含已被淘汰）
/// 或不一致时按 `invalidResponse` 失败。请求的取消与旧结果隔离不在这里，归评论 ViewModel。
public actor BiliCommentRepository: CommentRepository {
    private struct Cursor: Sendable, Equatable, Hashable {
        let subject: CommentSubjectIdentity
        let sort: CommentSort
        let offset: String
    }

    private let client: BiliAPIClient
    private var cursorByToken: [CommentContinuation: Cursor] = [:]
    private var tokenByCursor: [Cursor: CommentContinuation] = [:]
    private var cursorOrder: [CommentContinuation] = []

    public init(client: BiliAPIClient) {
        self.client = client
    }

    public func rootComments(
        for subject: CommentSubjectIdentity,
        sort: CommentSort,
        after continuation: CommentContinuation?
    ) async throws -> CommentRootPage {
        let offset: String?
        if let continuation {
            guard let cursor = cursorByToken[continuation],
                cursor.subject == subject, cursor.sort == sort
            else { throw CommentReadError.invalidResponse }
            offset = cursor.offset
        } else {
            offset = nil
        }

        do {
            let page = try await client.commentRootPage(
                for: subject,
                sort: sort,
                offset: offset
            )
            let next = page.nextOffset.map {
                token(for: Cursor(subject: subject, sort: sort, offset: $0))
            }
            return CommentRootPage(
                threads: page.threads,
                totalCount: page.totalCount,
                continuation: next,
                isEnd: page.isEnd,
                inputPolicy: page.inputPolicy
            )
        } catch {
            throw map(error)
        }
    }

    public func replies(
        for subject: CommentSubjectIdentity,
        rootID: CommentID,
        page: Int,
        pageSize: Int
    ) async throws -> CommentReplyPage {
        do {
            let response = try await client.commentReplyPage(
                for: subject,
                rootID: rootID,
                page: page,
                pageSize: pageSize
            )
            return CommentReplyPage(
                rootID: response.rootID,
                replies: response.replies,
                pageNumber: response.pageNumber,
                pageSize: response.pageSize,
                totalCount: response.totalCount
            )
        } catch {
            throw map(error)
        }
    }

    /// 对话按楼层分页，楼层只是公开的整数，不像根评论 offset 那样需要换成 continuation。
    public func dialog(
        for subject: CommentSubjectIdentity,
        rootID: CommentID,
        dialogID: CommentID,
        fromFloor: Int?,
        pageSize: Int
    ) async throws -> CommentDialogPage {
        do {
            let response = try await client.commentDialogPage(
                for: subject,
                rootID: rootID,
                dialogID: dialogID,
                fromFloor: fromFloor,
                pageSize: pageSize
            )
            return CommentDialogPage(
                rootID: response.rootID,
                dialogID: response.dialogID,
                replies: response.replies,
                nextFloor: response.nextFloor
            )
        } catch {
            throw map(error)
        }
    }

    private func token(for cursor: Cursor) -> CommentContinuation {
        if let token = tokenByCursor[cursor] { return token }
        let token = CommentContinuation(rawValue: UUID().uuidString)
        if cursorOrder.count == Self.maximumRetainedCursors, let oldest = cursorOrder.first {
            cursorOrder.removeFirst()
            if let removed = cursorByToken.removeValue(forKey: oldest) {
                tokenByCursor.removeValue(forKey: removed)
            }
        }
        cursorByToken[token] = cursor
        tokenByCursor[cursor] = token
        cursorOrder.append(token)
        return token
    }

    private func map(_ error: any Error) -> any Error {
        BiliAPIError.domainError(
            for: error,
            fallback: CommentReadError.unavailable,
            Self.readError
        )
    }

    /// 评论区已关闭时 reply endpoint 返回的业务码。
    private static let closedCommentsCode = 12002
    /// 评论分页游标与 continuation 的映射上限；超出时丢弃最早发出的。
    ///
    /// 被丢弃的 continuation 再用时加载失败；调小会让较早发出、仍在使用的 continuation 更早失效，
    /// 调大只多占少量内存。
    private static let maximumRetainedCursors = 128

    private static func readError(
        _ failure: BiliAPIError.Failure
    ) -> CommentReadError {
        switch failure {
        case .authorizationRequired:
            .authenticationRequired
        case .authenticationInvalid:
            .authenticationInvalid
        case .authorizationUnavailable:
            .authenticationUnavailable
        case .restricted:
            .requestRestricted
        case .rejected(let code) where code == closedCommentsCode:
            .closed
        case .rejected(let code):
            .serviceRejected(code: code)
        case .contentUnavailable:
            .contentUnavailable
        case .transport:
            .transportFailure
        case .invalidRequest:
            .invalidRequest
        case .invalidResponse:
            .invalidResponse
        case .unexpectedHTTPStatus, .unsupportedMedia, .noPlayableMedia:
            .unavailable
        }
    }
}
