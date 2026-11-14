import BiliApplication
import BiliModels
import Foundation

/// 根评论分页接口（`/x/v2/reply/wbi/main`）的 data：游标、置顶、热评、本页根评论与评论区的输入限制。
///
/// 单条评论解码失败只丢弃该条；置顶与热评按 ID 与普通评论去重，未结束却没有下一页游标时
/// 整页失败。
struct CommentMainPayload: Decodable, Sendable {
    let cursor: CommentCursorPayload
    let replies: [LossyDecodable<CommentReplyPayload>]
    let topReplies: [LossyDecodable<CommentReplyPayload>]
    let top: CommentTopPayload?
    let upper: CommentUpperPayload?
    let control: CommentInputControlPayload?
    let config: CommentAreaConfigPayload?

    private enum CodingKeys: String, CodingKey {
        case cursor
        case replies
        case topReplies = "top_replies"
        case top
        case upper
        case control
        case config
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        cursor = try container.decode(CommentCursorPayload.self, forKey: .cursor)
        replies =
            try container.decodeIfPresent(
                [LossyDecodable<CommentReplyPayload>].self,
                forKey: .replies
            ) ?? []
        topReplies =
            container.decodeLossyIfPresent(
                [LossyDecodable<CommentReplyPayload>].self,
                forKey: .topReplies
            ) ?? []
        top = container.decodeLossyIfPresent(CommentTopPayload.self, forKey: .top)
        upper = container.decodeLossyIfPresent(CommentUpperPayload.self, forKey: .upper)
        control = container.decodeLossyIfPresent(CommentInputControlPayload.self, forKey: .control)
        config = container.decodeLossyIfPresent(CommentAreaConfigPayload.self, forKey: .config)
    }

    /// 评论区的输入限制；字段缺失或形状不对时按可以发处理，发出后由服务端的业务码说明。
    var inputPolicy: CommentInputPolicy {
        CommentInputPolicy(
            acceptsNewComments: control?.inputDisabled != true && config?.isReadOnly != true,
            rootPlaceholder: control?.rootInputText.flatMap(Self.nonEmpty),
            replyPlaceholder: control?.childInputText.flatMap(Self.nonEmpty)
        )
    }

    private static func nonEmpty(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func page(for subject: CommentSubjectIdentity) throws -> CommentRemoteRootPage {
        let uploaderID = upper.map { String($0.mid) }
        let adminPinnedID = top?.admin?.value?.rpid
        let uploaderPinnedID = top?.upper?.value?.rpid
        let pinnedReplies = [top?.admin?.value, top?.upper?.value].compactMap { $0 }
        let candidates =
            pinnedReplies
            + topReplies.compactMap(\.value)
            + replies.compactMap(\.value)
        var seen: Set<CommentID> = []
        var threads: [CommentThread] = []
        for payload in candidates {
            guard
                let thread = try? payload.thread(
                    subject: subject,
                    uploaderID: uploaderID,
                    adminPinnedID: adminPinnedID,
                    uploaderPinnedID: uploaderPinnedID
                ), seen.insert(thread.id).inserted
            else { continue }
            threads.append(thread)
        }

        let nextOffset = cursor.paginationReply?.nextOffset
        if !cursor.isEnd, nextOffset?.isEmpty != false {
            throw BiliAPIError.decodingFailed
        }
        return CommentRemoteRootPage(
            threads: threads,
            totalCount: max(cursor.allCount, threads.count),
            nextOffset: cursor.isEnd ? nil : nextOffset,
            isEnd: cursor.isEnd,
            inputPolicy: inputPolicy
        )
    }
}

/// 一页根评论映射后的结果：评论串、总数与下一页游标（结束时为 nil）。
struct CommentRemoteRootPage: Sendable {
    let threads: [CommentThread]
    let totalCount: Int
    let nextOffset: String?
    let isEnd: Bool
    let inputPolicy: CommentInputPolicy
}

/// 评论区输入属性：是否禁止新增评论与两种占位文字。
struct CommentInputControlPayload: Decodable, Sendable {
    let inputDisabled: Bool?
    let rootInputText: String?
    let childInputText: String?

    private enum CodingKeys: String, CodingKey {
        case inputDisabled = "input_disable"
        case rootInputText = "root_input_text"
        case childInputText = "child_input_text"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        inputDisabled = container.decodeLossyBool(forKey: .inputDisabled)
        rootInputText = container.decodeLossyIfPresent(String.self, forKey: .rootInputText)
        childInputText = container.decodeLossyIfPresent(String.self, forKey: .childInputText)
    }
}

/// 评论区配置里与发评论有关的一项：是否只读。
struct CommentAreaConfigPayload: Decodable, Sendable {
    let isReadOnly: Bool?

    private enum CodingKeys: String, CodingKey {
        case isReadOnly = "read_only"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isReadOnly = container.decodeLossyBool(forKey: .isReadOnly)
    }
}

/// 根评论分页游标：总数、是否结束与下一页偏移。
struct CommentCursorPayload: Decodable, Sendable {
    let allCount: Int
    let isEnd: Bool
    let paginationReply: CommentPaginationReplyPayload?

    private enum CodingKeys: String, CodingKey {
        case allCount = "all_count"
        case isEnd = "is_end"
        case paginationReply = "pagination_reply"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // 评论区为空时 cursor 不带 `all_count`。
        allCount = try container.decodeIfPresent(Int.self, forKey: .allCount) ?? 0
        isEnd = try container.decode(Bool.self, forKey: .isEnd)
        paginationReply = container.decodeLossyIfPresent(
            CommentPaginationReplyPayload.self,
            forKey: .paginationReply
        )
    }
}

/// 下一页偏移；接口有时给字符串、有时给整数，统一成字符串原样回传。
struct CommentPaginationReplyPayload: Decodable, Sendable {
    let nextOffset: String

    private enum CodingKeys: String, CodingKey {
        case nextOffset = "next_offset"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        nextOffset = try container.decodeIntegerText(forKey: .nextOffset)
    }
}

/// 评论区所属 UP 主的 MID，用于标出 UP 主本人的评论。
struct CommentUpperPayload: Decodable, Sendable {
    let mid: Int64
}

/// 管理员置顶与 UP 主置顶的评论，各自单独容错解码。
struct CommentTopPayload: Decodable, Sendable {
    let admin: LossyDecodable<CommentReplyPayload>?
    let upper: LossyDecodable<CommentReplyPayload>?
}
