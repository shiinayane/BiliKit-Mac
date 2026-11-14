import BiliApplication
import BiliModels
import Foundation
import Observation

/// 评论区的写入状态：底部常驻输入框的草稿、回复对象、发送进度与失败说明，以及评论行上点赞、点踩的派发。
///
/// 每窗口一个，由 `WindowComposition` 构造并在关窗时 `reset()`。不拥有在途写入：请求经 `post`／`react` 交给窗口的写入协调者
/// （它持有 Task、窗口内只放一条评论在途、同一条评论只放一次表态在途、关窗时取消、凭据类失败时请求复核），结局经回调交回。
/// 不拥有评论列表：乐观表态、回滚与插入刚发出的评论都在 `PlaybackCommentsViewModel`（按评论对象与工作集身份丢弃过期改动）。
/// 回复对象绑定发起时的评论对象，换视频后自动作废，草稿不会作为回复发到另一个视频的评论区。写入不自动重试。
@MainActor
@Observable
public final class PlaybackCommentWriteModel {
    /// 不能发出或发出失败的原因。
    public enum Failure: Equatable, Sendable {
        /// 窗口没有可写入的账户（未登录、复核中或窗口账户已过期）。
        case signInRequired
        /// 正文为空、超长或含控制字符。
        case invalidText
        /// 服务端或网络失败；文案由写入结果胶囊的同一套措辞给出（`AccountWriteStatusText`）。
        case write(AccountWriteReport)
    }

    public enum Phase: Equatable, Sendable {
        case editing
        case sending
        case failed(Failure)
    }

    /// 正在回复的那条评论：所属评论区、根评论与被回复者，以及显示用的昵称。
    public struct ReplyContext: Equatable, Sendable {
        public let subject: CommentSubjectIdentity
        public let target: CommentReplyTarget
        public let authorName: String
        /// 被回复者的 mid；接口给的不是正整数时为 nil，这时「回复 @昵称」只是文字、不关联用户。
        public let authorMid: Int64?
    }

    public var draft = ""
    public private(set) var phase = Phase.editing
    public private(set) var replyContext: ReplyContext?
    /// 输入卡片是否展开；收起时只剩一枚浮动按钮。
    ///
    /// 默认收起，点按钮或评论行的「回复」展开。
    public private(set) var isExpanded = false
    /// 每次要求输入框取得焦点（展开、点「回复」）时递增；视图据此聚焦，并经 `consumeFocusRequest()` 只聚焦一次。
    public private(set) var focusRequestID: UInt64 = 0
    /// 最近一次焦点请求还没被视图用掉。
    ///
    /// 视图被重新挂上（被 UP 主空间盖住后露出、重载期间）时据此不再抢焦点。
    @ObservationIgnored private var hasPendingFocusRequest = false
    /// 发出成功后要求收起时递增；视图先放下焦点再收起（见 `PlaybackCommentComposerView`）。
    public private(set) var collapseRequestID: UInt64 = 0

    @ObservationIgnored private let comments: PlaybackCommentsViewModel
    @ObservationIgnored private let canWrite: @MainActor () -> Bool
    @ObservationIgnored private let uploaderID: @MainActor (CommentSubjectIdentity) -> Int64?
    @ObservationIgnored private let post:
        @MainActor (CommentPostRequest, @escaping @MainActor (CommentPostOutcome) -> Void) -> Bool
    @ObservationIgnored private let react:
        @MainActor (CommentReactionOperation, @escaping @MainActor () -> Void) -> Bool

    /// `canWrite` 是窗口此刻能否写入（写入协调者的门槛）；`uploaderID` 给出评论区所属视频的 UP 主 mid（视频页已换掉时为
    /// nil），只用来在刚发出的评论上标出 UP 主；`post` 与 `react` 把请求交给写入协调者，返回是否发出。
    public init(
        comments: PlaybackCommentsViewModel,
        canWrite: @escaping @MainActor () -> Bool,
        uploaderID: @escaping @MainActor (CommentSubjectIdentity) -> Int64?,
        post:
            @escaping @MainActor (
                CommentPostRequest, @escaping @MainActor (CommentPostOutcome) -> Void
            ) -> Bool,
        react:
            @escaping @MainActor (CommentReactionOperation, @escaping @MainActor () -> Void) -> Bool
    ) {
        self.comments = comments
        self.canWrite = canWrite
        self.uploaderID = uploaderID
        self.post = post
        self.react = react
    }

    public var isSending: Bool { phase == .sending }

    /// 这次发出时正文的字数：回复楼中楼里的回复时含「回复 @昵称 : 」前缀，去掉首尾空白，与发出前的校验
    /// （`CommentPostText`）按同一段文字计；输入卡片的字数显示用它。
    public var messageLength: Int {
        (messagePrefix + draft.trimmingCharacters(in: .whitespacesAndNewlines)).count
    }

    /// 回复的是楼中楼里的回复（不是根评论本身）时的回复对象：只有这时正文要加前缀并关联被回复者。
    private var subReplyContext: ReplyContext? {
        activeReplyContext.flatMap { $0.target.parentID != $0.target.rootID ? $0 : nil }
    }

    /// 回复楼中楼里的回复时正文前的「回复 @昵称 : 」。
    ///
    /// 与官方网页一致（服务端不会自己加）；同时随请求带上
    /// `at_name_to_mid`，服务端才会把这段 @ 关联到被回复者（官方客户端也这样做）。这段是给服务端的固定格式，不本地化。
    private var messagePrefix: String {
        subReplyContext.map { "回复 @\($0.authorName) : " } ?? ""
    }
    /// 评论区的输入限制与接口给的占位文字（`PlaybackCommentsViewModel.inputPolicy`）。
    public var inputPolicy: CommentInputPolicy { comments.inputPolicy }
    public var isWritable: Bool { canWrite() }

    /// 此刻有效的回复对象：评论区已换掉时为 nil，输入框回到发楼层评论。
    public var activeReplyContext: ReplyContext? {
        guard let replyContext, replyContext.subject == comments.subject else { return nil }
        return replyContext
    }

    /// 点评论行上的「回复」：输入框改为回复这条评论并取得焦点；草稿保留。
    ///
    /// 回复落在这条评论所在的楼：根评论自己就是楼（`comment.rootID` 为 nil），回复的楼取它的 `rootID`。评论区不接受新评论
    /// （`PlaybackCommentsViewModel.acceptsNewComments`）时不展开。
    public func beginReply(to comment: BiliModels.Comment) {
        guard comments.acceptsNewComments, let subject = comments.subject,
            case .available(let details) = comment.payload,
            let target = CommentReplyTarget(
                rootID: comment.rootID ?? comment.id,
                parentID: comment.id
            )
        else { return }
        replyContext = ReplyContext(
            subject: subject,
            target: target,
            authorName: details.author.name,
            authorMid: details.author.id.memberID
        )
        if case .failed = phase { phase = .editing }
        isExpanded = true
        requestFocus()
    }

    /// 视图聚焦前调用：有尚未用掉的焦点请求时返回 true 并用掉它。
    public func consumeFocusRequest() -> Bool {
        defer { hasPendingFocusRequest = false }
        return hasPendingFocusRequest
    }

    private func requestFocus() {
        hasPendingFocusRequest = true
        focusRequestID &+= 1
    }

    /// 点收起状态的按钮：展开输入卡片并聚焦；草稿与回复对象保留。
    public func expand() {
        isExpanded = true
        requestFocus()
    }

    /// 收起输入卡片；草稿保留，回复对象与已经看过的失败说明清掉。
    ///
    /// 由视图在放下焦点之后调用，不直接由模型触发：卡片在收起动画结束前还挂着，焦点要先放下，播放器快捷键才马上恢复。
    public func collapse() {
        isExpanded = false
        replyContext = nil
        if case .failed = phase { phase = .editing }
    }

    /// × 或 Esc：回到发楼层评论；草稿保留。
    public func cancelReply() {
        replyContext = nil
        if case .failed = phase { phase = .editing }
    }

    /// 发出草稿；成功时插进列表、清空草稿并回到发楼层评论，失败时停在输入框下方说明原因、草稿保留。
    public func send() {
        guard phase != .sending else { return }
        guard canWrite() else {
            phase = .failed(.signInRequired)
            return
        }
        let reply = subReplyContext
        let prefix = messagePrefix
        let mentions: [String: Int64] =
            reply.flatMap { reply in reply.authorMid.map { [reply.authorName: $0] } } ?? [:]
        guard let subject = comments.subject,
            CommentPostText.normalized(draft) != nil,
            let request = CommentWriteUseCase.request(
                message: prefix + draft,
                subject: subject,
                replyTarget: activeReplyContext?.target,
                mentions: mentions,
                uploaderID: uploaderID(subject)
            )
        else {
            phase = .failed(.invalidText)
            return
        }
        let sentDraft = draft
        let issued = post(request) { [weak self] outcome in
            self?.finish(request, sentDraft: sentDraft, outcome: outcome)
        }
        // 协调者没有发出：门槛在这一刻变了（另一条在途时 `phase` 已是 `.sending`，到不了这里）。
        phase = issued ? .sending : .failed(.signInRequired)
    }

    /// 评论行上的赞或踩：已是这个表态时取消，否则改成它；先在列表里乐观改动，失败或被取消时放回。
    public func toggle(_ reaction: CommentReaction, on commentID: CommentID) {
        guard reaction != .none, let subject = comments.subject,
            let target = CommentWriteTarget(subject: subject, commentID: commentID),
            let current = comments.reaction(of: commentID)
        else { return }
        let desired: CommentReaction = current == reaction ? .none : reaction
        guard canWrite(),
            let operation = CommentWriteUseCase.operation(for: target, from: current, to: desired),
            let edit = comments.applyReaction(desired, to: commentID)
        else { return }
        let issued = react(operation) { [comments] in comments.revertReaction(edit) }
        if !issued { comments.revertReaction(edit) }
    }

    /// 评论区对象变了（换视频、离开播放页）：清空草稿、回复对象与说明，免得上一个视频的草稿按回车发到这个视频。
    ///
    /// 由侧栏在评论 ViewModel 的 `subject` 变化时调用。在途的发送照常完成，插入时按评论对象丢弃。
    public func subjectDidChange() {
        draft = ""
        replyContext = nil
        isExpanded = false
        if case .failed = phase { phase = .editing }
    }

    /// 关窗时调用：清空草稿、回复对象与说明；在途的发送由写入协调者在关窗时取消。
    public func reset() {
        draft = ""
        phase = .editing
        replyContext = nil
        isExpanded = false
    }

    private func finish(
        _ request: CommentPostRequest,
        sentDraft: String,
        outcome: CommentPostOutcome
    ) {
        switch outcome {
        case .posted where comments.subject != request.subject:
            // 换视频后才到达的结果：评论已经发出，但输入卡片此刻属于另一个视频，不清它的草稿、不收起。
            phase = .editing
        case .posted(let comment):
            if let comment { comments.insertPostedComment(comment, subject: request.subject) }
            // 发送期间改过的草稿不清，免得吞掉新写的字。
            if draft == sentDraft { draft = "" }
            if activeReplyContext?.target == request.replyTarget { replyContext = nil }
            phase = .editing
            // 草稿在发送期间又写了字就不收起，免得把正在写的内容藏起来。
            if draft.isEmpty { collapseRequestID &+= 1 }
        case .failed where comments.subject != request.subject:
            phase = .editing
        case .failed(let error):
            phase = .failed(
                .write(AccountWriteReport(change: .commentPosted(request.subject), failure: error))
            )
        case .cancelled:
            phase = .editing
        }
    }
}
