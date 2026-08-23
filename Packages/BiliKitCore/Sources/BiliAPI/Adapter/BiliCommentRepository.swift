import BiliApplication
import BiliModels
import Foundation

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
                isEnd: page.isEnd
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

    private func token(for cursor: Cursor) -> CommentContinuation {
        if let token = tokenByCursor[cursor] { return token }
        let token = CommentContinuation(rawValue: UUID().uuidString)
        if cursorOrder.count == 128, let oldest = cursorOrder.first {
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
        if error is CancellationError { return CancellationError() }
        guard let error = error as? BiliAPIError else {
            return CommentReadError.unavailable
        }
        switch error {
        case .transportFailure:
            return CommentReadError.transportFailure
        case .httpStatus(403), .httpStatus(412),
            .apiRejected(code: -352, _), .apiRejected(code: -403, _),
            .apiRejected(code: -412, _):
            return CommentReadError.requestRestricted
        case .apiRejected(let code, _):
            return CommentReadError.serviceRejected(code: code)
        case .responseTooLarge, .nonJSONResponse, .decodingFailed, .missingData,
            .invalidWBIKey, .signingFailed, .invalidRequest:
            return CommentReadError.invalidResponse
        case .authorizationRequired, .authenticationInvalid:
            return CommentReadError.authenticationInvalid
        case .httpStatus, .authorizationUnavailable, .nonProtobufResponse,
            .invalidMediaData, .invalidSubtitleData, .untrustedSubtitleOrigin,
            .invalidDanmakuData, .noAVCVideo, .noAACAudio,
            .unsupportedProgressiveMedia, .noPlayableMedia:
            return CommentReadError.unavailable
        }
    }
}
