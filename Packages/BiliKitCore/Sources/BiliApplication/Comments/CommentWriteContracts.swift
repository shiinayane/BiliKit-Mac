import BiliModels
import Foundation

/// 表态或回复作用的一条评论：评论区对象加评论 ID；只接受视频评论区与正数 ID。
public struct CommentWriteTarget: Sendable, Hashable {
    public let subject: CommentSubjectIdentity
    public let commentID: CommentID

    /// 不是视频评论区、`oid` 或评论 ID 不是正数时为 nil，不发请求。
    public init?(subject: CommentSubjectIdentity, commentID: CommentID) {
        guard subject.type == 1, subject.oid > 0, commentID.rawValue > 0 else { return nil }
        self.subject = subject
        self.commentID = commentID
    }
}

/// 一次表态在接口上的样子：点赞接口（`reply/action`）或点踩接口（`reply/hate`），打开或取消。
///
/// 由 `CommentWriteUseCase.operation(from:to:)` 从表态前后两态算出；赞与踩互斥由服务端保证（点赞同时取消点踩），所以从
/// 已踩改为已赞只发一次点赞。
public struct CommentReactionOperation: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        case like
        case dislike
    }

    public let target: CommentWriteTarget
    public let kind: Kind
    public let isOn: Bool
}

/// 发一条评论时回复的对象：根评论加被回复的那一条（直接回复根评论时两者相同）。
public struct CommentReplyTarget: Sendable, Equatable, Hashable {
    public let rootID: CommentID
    public let parentID: CommentID

    public init?(rootID: CommentID, parentID: CommentID) {
        guard rootID.rawValue > 0, parentID.rawValue > 0 else { return nil }
        self.rootID = rootID
        self.parentID = parentID
    }
}

/// 发一条评论的请求：评论区、回复对象（nil 为楼层评论）与已规整的正文。
///
/// 只由 `CommentWriteUseCase.request(...)` 构造。
public struct CommentPostRequest: Sendable, Equatable {
    public let subject: CommentSubjectIdentity
    public let replyTarget: CommentReplyTarget?
    public let message: String
    /// 正文里「@昵称」对应的用户 mid，发送为 `at_name_to_mid`，服务端据此把这段 @ 关联到用户。
    ///
    /// 每个昵称都以「@昵称」出现在正文里（`CommentPostMentions.isValid`）；回复楼中楼里的回复时就是被回复者，与官方客户端
    /// 一致（实测官方的「回复 @某人 :」回复都在 `members` 里带着被回复者）。
    public let mentions: [String: Int64]
    /// 这个评论区所属视频的 UP 主 mid，不发给服务端：只用来在服务端给回的条目上标出 UP 主（给回的正文里没有 UP 主 mid）。
    public let uploaderID: Int64?
}

/// 发评论时附带的 @ 提及的上限与校验；写授权器按同一规则校验 `at_name_to_mid`。
public enum CommentPostMentions {
    /// 一条评论最多关联的 @ 用户数：远多于回复一个人所需，超出说明请求构造有误。
    public static let maximumCount = 10

    /// 数量不超过上限，mid 都是正数，每个昵称非空、不含控制字符，并以「@昵称」出现在正文里。
    public static func isValid(_ mentions: [String: Int64], in message: String) -> Bool {
        mentions.count <= maximumCount
            && mentions.allSatisfy { name, mid in
                mid > 0 && !name.isEmpty
                    && !name.unicodeScalars.contains { $0.properties.generalCategory == .control }
                    && message.contains("@\(name)")
            }
    }
}

/// 一次发评论的结局，由窗口的写入协调者交回评论输入框。
public enum CommentPostOutcome: Sendable, Equatable {
    /// 服务端收下了；给回的那条评论按评论列表的同一映射解码，解不出或不可见时为 nil（照样算发出成功，只是不在本地插入）。
    case posted(BiliModels.Comment?)
    case failed(AccountWriteError)
    /// 关窗或认证会话在请求途中切换：不说明结果，服务端可能已经收下。
    case cancelled
}

/// 评论表态与发评论 port，实现是 BiliAPI 的 `BiliCommentWriteRepository`，只经 `CommentWriteUseCase` 调用。
///
/// 失败抛出 `AccountWriteError`，取消原样传播；写入不自动重试。
public protocol CommentWriteRepository: Sendable {
    func apply(_ operation: CommentReactionOperation, accountID: Int64) async throws
    func post(_ request: CommentPostRequest, accountID: Int64) async throws -> BiliModels.Comment?
}

/// 评论正文的规整与上限。
public enum CommentPostText {
    /// 一条评论最多的字符数：接口文档写明的上限，超出服务端以 12025 拒绝。
    public static let maximumLength = 1_000
    /// 一条评论最多的 UTF-8 字节数：1000 个中文字是 3000 字节，常见表情 4 字节；肤色、国旗、组合表情一个“字”可达几十字节，
    /// 不设这个上限时 1000 字的正文百分号编码后会超出写授权器给发评论的正文上限（16 KiB），只能报成笼统的失败。
    ///
    /// 写授权器的正文上限按它推出（每字节编码后最多 3 字节，加上其余字段）；调大这里要同时调大那边。
    public static let maximumUTF8Length = 4_000

    /// 去掉首尾空白；为空、超长（字数或 UTF-8 字节数），或含换行以外的控制字符时为 nil。
    ///
    /// 评论可以多行，换行原样保留。
    public static func normalized(_ raw: String) -> String? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= maximumLength, text.utf8.count <= maximumUTF8Length,
            !text.unicodeScalars.contains(where: { scalar in
                scalar != "\n" && scalar.properties.generalCategory == .control
            })
        else { return nil }
        return text
    }
}

/// 评论的表态与发评论。
public struct CommentWriteUseCase: Sendable {
    private let repository: any CommentWriteRepository

    public init(repository: any CommentWriteRepository) {
        self.repository = repository
    }

    /// 从 `current` 改为 `desired` 要发的那一次请求；两者相同时为 nil。
    public static func operation(
        for target: CommentWriteTarget,
        from current: CommentReaction,
        to desired: CommentReaction
    ) -> CommentReactionOperation? {
        switch (current, desired) {
        case (.liked, .liked), (.disliked, .disliked), (.none, .none):
            nil
        case (_, .liked):
            CommentReactionOperation(target: target, kind: .like, isOn: true)
        case (_, .disliked):
            CommentReactionOperation(target: target, kind: .dislike, isOn: true)
        case (.liked, .none):
            CommentReactionOperation(target: target, kind: .like, isOn: false)
        case (.disliked, .none):
            CommentReactionOperation(target: target, kind: .dislike, isOn: false)
        }
    }

    /// 规整正文并构造请求；正文不合规或评论区对象无效时为 nil，不发出请求。
    public static func request(
        message: String,
        subject: CommentSubjectIdentity,
        replyTarget: CommentReplyTarget?,
        mentions: [String: Int64],
        uploaderID: Int64?
    ) -> CommentPostRequest? {
        guard subject.type == 1, subject.oid > 0,
            let message = CommentPostText.normalized(message),
            CommentPostMentions.isValid(mentions, in: message)
        else { return nil }
        return CommentPostRequest(
            subject: subject,
            replyTarget: replyTarget,
            message: message,
            mentions: mentions,
            uploaderID: uploaderID.flatMap { $0 > 0 ? $0 : nil }
        )
    }

    public func apply(_ operation: CommentReactionOperation, accountID: Int64) async throws {
        guard accountID > 0 else { throw AccountWriteError.invalidRequest }
        try await repository.apply(operation, accountID: accountID)
    }

    public func post(
        _ request: CommentPostRequest,
        accountID: Int64
    ) async throws -> BiliModels.Comment? {
        guard accountID > 0 else { throw AccountWriteError.invalidRequest }
        return try await repository.post(request, accountID: accountID)
    }
}
