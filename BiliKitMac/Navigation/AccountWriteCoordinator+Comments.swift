import BiliApplication
import BiliModels

/// 评论区的写入入口：点赞、点踩与发评论，共用 `run` 的在途登记、关窗取消与凭据类失败的复核节流。
///
/// 乐观改动与回滚在 `PlaybackCommentsViewModel`，由评论写入模型经 `rollback` 交来；这里不持有评论状态。
extension AccountWriteCoordinator {
    /// 对一条评论点赞、点踩或取消；返回是否发出：没有写入账户，或这条评论已有一次表态在途时不发。
    ///
    /// 同一条评论同时只有一次在途：赞与踩互斥，两次请求到达服务端的先后不可知。成功不提示、不分发效果；失败先 `rollback`，
    /// 再在写入结果胶囊里说明；被取消时只 `rollback`。
    @discardableResult
    func setCommentReaction(
        _ operation: CommentReactionOperation,
        rollback: @escaping @MainActor () -> Void
    ) -> Bool {
        guard let account = currentAccount(),
            !inFlight.keys.contains(where: { Self.isReaction($0, on: operation.target) })
        else { return false }
        let change = AccountWriteChange.commentReactionChanged(operation)
        run(
            change,
            account: account,
            write: { [commentWrite] in
                try await commentWrite.apply(operation, accountID: account.accountID)
            },
            finished: { [weak self] outcome in
                switch outcome {
                case .succeeded:
                    break
                case .failed(let error):
                    rollback()
                    self?.show(AccountWriteReport(change: change, failure: error))
                case .cancelled:
                    rollback()
                }
            }
        )
        return true
    }

    /// 发一条评论或回复；返回是否发出：没有写入账户，或本窗口已有一条评论在途时不发。
    ///
    /// 结局交给 `completion`（输入框据此插入列表或说明失败），不进写入结果胶囊，也不产生跨视图效果。同一窗口同时只有一条
    /// 在途，不按正文区分，免得连按回车发出两条。
    @discardableResult
    func postComment(
        _ request: CommentPostRequest,
        completion: @escaping @MainActor (CommentPostOutcome) -> Void
    ) -> Bool {
        guard let account = currentAccount(),
            !inFlight.keys.contains(where: Self.isCommentPost)
        else { return false }
        run(
            .commentPosted(request.subject),
            account: account,
            write: { [commentWrite] in
                try await commentWrite.post(request, accountID: account.accountID)
            },
            finished: { outcome in
                switch outcome {
                case .succeeded(let comment): completion(.posted(comment))
                case .failed(let error): completion(.failed(error))
                case .cancelled: completion(.cancelled)
                }
            }
        )
        return true
    }

    private static func isReaction(
        _ change: AccountWriteChange,
        on target: CommentWriteTarget
    )
        -> Bool
    {
        if case .commentReactionChanged(let other) = change {
            other.target == target
        } else {
            false
        }
    }

    private static func isCommentPost(_ change: AccountWriteChange) -> Bool {
        if case .commentPosted = change { true } else { false }
    }
}
