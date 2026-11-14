import BiliApplication
import BiliModels
import Foundation

/// 评论的点赞、点踩与发评论。
///
/// 点赞与点踩（`BiliAccountWritePath.commentLike`／`commentDislike`）经网页端表单写入管线 `postForm` 与账户写授权器发出；
/// 发评论（`BiliAppWritePath.commentAdd`）经 App 端表单写入管线 `postAppForm` 与 App 写授权器发出，理由见那个 path 的说明。
extension BiliAPIClient {
    /// 评论点赞与点踩的 Referer：与其他网页端写入一样用固定的站点首页，与授权器 schema 表一致。
    private static let commentReactionReferer = "https://www.bilibili.com/"
    /// 发评论的响应上限：成功正文带回整条评论（作者、正文、表情表等），实测约 6 KB，1000 字的正文还要再加几 KB；
    /// 太小会把已经发出的评论说成失败、诱导用户重发，所以比只有状态的写响应宽得多。
    private static let maximumCommentPostResponseSize = 64 * 1_024

    /// 以 `accountID` 的身份对一条评论点赞、点踩或取消。
    public func applyCommentReaction(
        _ operation: CommentReactionOperation,
        accountID: Int64
    ) async throws {
        guard hasAccountWriteAuthorizer else {
            throw BiliAPIError.authorizationRequired
        }
        guard accountID > 0 else { throw BiliAPIError.invalidRequest }
        let target = operation.target
        try await postForm(
            url: try endpoint(
                path: operation.kind == .like
                    ? BiliAccountWritePath.commentLike : BiliAccountWritePath.commentDislike
            ),
            fields: [
                ("type", String(target.subject.type)),
                ("oid", String(target.subject.oid)),
                ("rpid", String(target.commentID.rawValue)),
                ("action", operation.isOn ? "1" : "0")
            ],
            referer: Self.commentReactionReferer,
            origin: Self.accountWriteOrigin,
            access: .accountWrite(expectedAccountID: accountID)
        )
    }

    /// 以 `accountID` 的身份发一条评论或回复，返回服务端给回的那条评论。
    ///
    /// 状态码为 0 就是发出成功：给回的条目按评论列表的同一映射解码（评论区对象必须与请求一致；UP 主 mid 不在这份正文里，
    /// 由调用方给出 `uploaderID` 才能标出 UP 主），解不出、缺失或不可见（`state` 非 0）时返回 nil，不能报成失败，否则用户会
    /// 重发一条已经发出的评论。
    public func postComment(
        _ request: CommentPostRequest,
        accountID: Int64
    ) async throws -> BiliModels.Comment? {
        guard hasAppWriteAuthorizer else {
            throw BiliAPIError.authorizationRequired
        }
        guard accountID > 0, request.subject.type == 1, request.subject.oid > 0 else {
            throw BiliAPIError.invalidRequest
        }
        var fields = [
            ("type", String(request.subject.type)),
            ("oid", String(request.subject.oid))
        ]
        if let reply = request.replyTarget {
            fields.append(("root", String(reply.rootID.rawValue)))
            fields.append(("parent", String(reply.parentID.rawValue)))
        }
        fields.append(("message", request.message))
        fields.append(("plat", "2"))
        if !request.mentions.isEmpty {
            // 键排序后编码，同一组提及总是同一份正文。
            let data = try JSONSerialization.data(
                withJSONObject: request.mentions,
                options: [.sortedKeys, .withoutEscapingSlashes]
            )
            guard let json = String(data: data, encoding: .utf8) else {
                throw BiliAPIError.invalidRequest
            }
            fields.append(("at_name_to_mid", json))
        }
        let body = try await postAppForm(
            url: try endpoint(path: BiliAppWritePath.commentAdd),
            fields: fields,
            access: .appWrite(expectedAccountID: accountID),
            maximumResponseSize: Self.maximumCommentPostResponseSize
        )
        guard
            let payload = try? decoder.decode(CommentPostEnvelope.self, from: body).data?.reply,
            let comment = try? payload.model(
                subject: request.subject,
                uploaderID: request.uploaderID.map(String.init),
                adminPinnedID: nil,
                uploaderPinnedID: nil
            ),
            case .available = comment.payload
        else { return nil }
        return comment
    }
}

private struct CommentPostEnvelope: Decodable, Sendable {
    let data: CommentPostPayload?
}

/// 发评论成功的 `data`：只解码 `reply`；`success_toast`、`need_captcha`、`emote` 等不读。
private struct CommentPostPayload: Decodable, Sendable {
    let reply: CommentReplyPayload?
}
