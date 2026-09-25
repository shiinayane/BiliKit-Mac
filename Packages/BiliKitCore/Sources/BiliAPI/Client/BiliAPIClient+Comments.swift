import BiliApplication
import BiliModels
import BiliNetworking
import Foundation

/// 主评论（WBI 签名）与楼中楼分页。
extension BiliAPIClient {
    private static let maximumCommentPageSize = 2 * 1_024 * 1_024

    func commentRootPage(
        for subject: CommentSubjectIdentity,
        sort: CommentSort,
        offset: String?
    ) async throws -> CommentRemoteRootPage {
        guard subject.type == 1, subject.oid > 0 else {
            throw BiliAPIError.invalidRequest
        }
        return try await withWBIKeyRefresh(retryingHTTPForbidden: false) { forceKeyRefresh in
            try await signedCommentRootPage(
                for: subject,
                sort: sort,
                offset: offset,
                forceKeyRefresh: forceKeyRefresh
            )
        }
    }

    func commentReplyPage(
        for subject: CommentSubjectIdentity,
        rootID: CommentID,
        page: Int,
        pageSize: Int
    ) async throws -> CommentRemoteReplyPage {
        guard subject.type == 1, subject.oid > 0,
            rootID.rawValue > 0, page > 0, pageSize == 10
        else { throw BiliAPIError.invalidRequest }
        let payload: CommentReplyListPayload = try await get(
            url: try endpoint(
                path: "/x/v2/reply/reply",
                queryItems: [
                    URLQueryItem(name: "type", value: String(subject.type)),
                    URLQueryItem(name: "oid", value: String(subject.oid)),
                    URLQueryItem(name: "root", value: String(rootID.rawValue)),
                    URLQueryItem(name: "pn", value: String(page)),
                    URLQueryItem(name: "ps", value: String(pageSize))
                ]
            ),
            referer: "https://www.bilibili.com/",
            access: .accountRead(
                missingCredential: .useAnonymousRequest,
                mapsAuthenticationInvalidation: true
            ),
            maximumResponseSize: Self.maximumCommentPageSize
        )
        return try payload.page(subject: subject, rootID: rootID)
    }

    private func signedCommentRootPage(
        for subject: CommentSubjectIdentity,
        sort: CommentSort,
        offset: String?,
        forceKeyRefresh: Bool
    ) async throws -> CommentRemoteRootPage {
        let paginationData = try JSONSerialization.data(
            withJSONObject: ["offset": offset ?? ""],
            options: [.sortedKeys]
        )
        guard let pagination = String(data: paginationData, encoding: .utf8) else {
            throw BiliAPIError.invalidRequest
        }
        let keys = try await wbiKey(forceRefresh: forceKeyRefresh)
        let query = try wbiSigner.sign(
            parameters: [
                "type": String(subject.type),
                "oid": String(subject.oid),
                "mode": sort == .hot ? "3" : "2",
                "pagination_str": pagination
            ],
            keys: keys,
            timestamp: timestampProvider()
        )
        let payload: CommentMainPayload = try await get(
            url: try endpoint(
                path: "/x/v2/reply/wbi/main",
                percentEncodedQuery: query
            ),
            referer: "https://www.bilibili.com/",
            access: .accountRead(
                missingCredential: .useAnonymousRequest,
                mapsAuthenticationInvalidation: true
            ),
            maximumResponseSize: Self.maximumCommentPageSize
        )
        return try payload.page(for: subject)
    }
}
