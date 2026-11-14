import BiliApplication
import BiliModels

/// 一次乐观表态改了哪条评论、从什么改成什么，以及改动时的评论工作集身份；回滚据此判断还能不能放回。
public struct PlaybackCommentReactionEdit: Sendable, Equatable {
    let subject: CommentSubjectIdentity
    let rootGeneration: Int
    public let commentID: CommentID
    public let previous: CommentReaction
    public let applied: CommentReaction
    let previousLikeCount: Int64
    let appliedLikeCount: Int64
}

/// 评论区的本地改动：乐观的点赞、点踩与回滚，以及把刚发出的评论插进列表。
///
/// 同一条评论可能同时出现在根评论、楼中楼预览、楼中楼当前页与「查看对话」里，改动与回滚对所有出现处一起进行。改动绑定
/// 当时的评论对象与 `rootGeneration`：之后换了视频、排序或重载，回滚就丢弃（重载带回的是服务端状态）；评论此刻已不是
/// 乐观改动后的样子（期间楼中楼重读）时同样不放回。
extension PlaybackCommentsViewModel {
    /// 此刻能否在这个评论区发评论：接口没有禁止新增，评论区也没有关闭（关闭时根评论读取以 `.closed` 失败）。
    ///
    /// 评论入口据此决定是否显示。换排序或重载期间沿用上一页的限制、不随加载中消失：入口被移除会让正在打字的输入框连焦点
    /// 一起不见。
    public var acceptsNewComments: Bool {
        guard subject != nil, rootState != .failed(.closed) else { return false }
        return inputPolicy.acceptsNewComments
    }

    /// 这条评论此刻的表态；评论不在已加载的内容里或不可见时为 nil。
    public func reaction(of commentID: CommentID) -> CommentReaction? {
        guard case .available(let details) = comment(withID: commentID)?.payload else {
            return nil
        }
        return details.viewerReaction
    }

    /// 把这条评论乐观地改成 `reaction`，同时调整点赞数（踩不显示计数）；没有这条评论或已是这个表态时为 nil。
    public func applyReaction(
        _ reaction: CommentReaction,
        to commentID: CommentID
    ) -> PlaybackCommentReactionEdit? {
        guard let subject,
            case .available(let details) = comment(withID: commentID)?.payload,
            details.viewerReaction != reaction
        else { return nil }
        let likeCount = max(
            0,
            details.likeCount + (reaction == .liked ? 1 : 0)
                - (details.viewerReaction == .liked ? 1 : 0)
        )
        let edit = PlaybackCommentReactionEdit(
            subject: subject,
            rootGeneration: rootGeneration,
            commentID: commentID,
            previous: details.viewerReaction,
            applied: reaction,
            previousLikeCount: details.likeCount,
            appliedLikeCount: likeCount
        )
        updateComment(commentID) { details in
            details.viewerReaction = reaction
            details.likeCount = likeCount
        }
        return edit
    }

    /// 写入失败或被取消时放回改动前的表态与点赞数；工作集已换掉或评论已不是改动后的样子时不动。
    public func revertReaction(_ edit: PlaybackCommentReactionEdit) {
        guard subject == edit.subject, rootGeneration == edit.rootGeneration,
            case .available(let details) = comment(withID: edit.commentID)?.payload,
            details.viewerReaction == edit.applied, details.likeCount == edit.appliedLikeCount
        else { return }
        updateComment(edit.commentID) { details in
            details.viewerReaction = edit.previous
            details.likeCount = edit.previousLikeCount
        }
    }

    /// 把刚发出成功的评论插进列表并标为自己发的。
    ///
    /// 楼层评论放在最前；回复放在所属楼中楼的最前（展开时进当前页，正在看它所在的对话时接在对话末尾，收起时进预览），
    /// 根评论的回复数加一。评论对象已换掉、根评论正在重载（换排序或重试时列表已清空，新的一页随后才到）或找不到所属的楼时
    /// 不插入，刷新后由服务端列表带回；与在途的下一页撞上同一条时由 `appendRootBatch` 按当时的列表去重。
    public func insertPostedComment(
        _ comment: BiliModels.Comment,
        subject postedSubject: CommentSubjectIdentity
    ) {
        guard subject == postedSubject, rootState == .loaded || rootState == .empty,
            self.comment(withID: comment.id) == nil
        else { return }
        var comment = comment
        if case .available(var details) = comment.payload {
            details.provenance.append(.postedByViewer)
            comment.payload = .available(details)
        }
        guard let rootID = comment.rootID else {
            threads.insert(CommentThread(root: comment), at: 0)
            totalCount += 1
            if rootState == .empty { rootState = .loaded }
            return
        }
        guard let index = threads.firstIndex(where: { $0.id == rootID }) else { return }
        if case .available(var root) = threads[index].root.payload {
            root.replyCount += 1
            threads[index].root.payload = .available(root)
        }
        if var state = replyStates[rootID] {
            // 正在看的对话就是这条回复所在的对话：接在对话末尾（对话按楼层排列）；否则放进当前页的最前，关掉对话后能看到。
            // 收起的楼也保留着已读的那页，展开时直接显示它，所以同样插进去，不只放进预览。
            if state.isExpanded, var dialog = state.dialog, comment.dialogID == dialog.dialogID {
                dialog.replies.append(comment)
                state.dialog = dialog
            } else if state.isExpanded || !state.replies.isEmpty {
                state.replies.insert(comment, at: 0)
            }
            state.totalCount += 1
            replyStates[rootID] = state
        }
        if replyStates[rootID]?.isExpanded != true {
            // 预览的契约是至多 2 条（`CommentThread`），新回复挤掉最旧的那条。
            threads[index].replyPreview = Array(
                ([comment] + threads[index].replyPreview).prefix(2)
            )
        }
    }

    /// 已加载内容里的这条评论（根评论、预览、楼中楼当前页或对话里的第一处）。
    private func comment(withID commentID: CommentID) -> BiliModels.Comment? {
        for thread in threads {
            if thread.root.id == commentID { return thread.root }
            if let reply = thread.replyPreview.first(where: { $0.id == commentID }) {
                return reply
            }
        }
        for state in replyStates.values {
            if let reply = state.replies.first(where: { $0.id == commentID }) { return reply }
            if let reply = state.dialog?.replies.first(where: { $0.id == commentID }) {
                return reply
            }
        }
        return nil
    }

    /// 对这条评论的每一处出现执行同一改动；不可见的评论没有可改的字段，跳过。
    private func updateComment(
        _ commentID: CommentID,
        _ transform: (inout CommentDetails) -> Void
    ) {
        func apply(_ comment: inout BiliModels.Comment) {
            guard comment.id == commentID, case .available(var details) = comment.payload else {
                return
            }
            transform(&details)
            comment.payload = .available(details)
        }
        for index in threads.indices {
            apply(&threads[index].root)
            for replyIndex in threads[index].replyPreview.indices {
                apply(&threads[index].replyPreview[replyIndex])
            }
        }
        for rootID in Array(replyStates.keys) {
            guard var state = replyStates[rootID] else { continue }
            for replyIndex in state.replies.indices { apply(&state.replies[replyIndex]) }
            if var dialog = state.dialog {
                for replyIndex in dialog.replies.indices { apply(&dialog.replies[replyIndex]) }
                state.dialog = dialog
            }
            replyStates[rootID] = state
        }
    }
}
