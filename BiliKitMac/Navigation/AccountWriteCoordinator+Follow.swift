import BiliApplication
import BiliLibraryFeature
import BiliModels

/// 关注关系的写入入口：特别关注、「设置分组…」面板与关注页卡片的取消关注，共用 `start` 的在途登记、结果胶囊、关窗取消与
/// 凭据类失败的复核节流。
///
/// 关系取自窗口的 `FollowRelationStore`：只对确认已关注的人发出特别关注与设置分组（对没关注的人发出时服务端会不会顺带关注
/// 没有实测），写前关系随效果交给各窗口调整人数。特别关注与设置分组的乐观改动只在关系存储里，取消关注的乐观改动只在关注页
/// 列表里（卡片先去掉），失败或被取消时放回。
extension AccountWriteCoordinator {
    /// 同一个人的关注、取消关注、特别关注与设置分组是一族：同时只有一个在途，不分种类与方向。
    ///
    /// 它们改的是同一份关系，两个请求到达服务端的先后不可知；设置分组按完整集合覆盖，与特别关注同时在途时后到的一个会抹掉
    /// 先到的一个。播放页与空间页的关注入口也按它判断。
    static func isRelationWrite(
        _ change: AccountWriteChange,
        of uploader: UploaderWriteTarget
    ) -> Bool {
        switch change {
        case .followChanged(let other, _), .followSpecialChanged(let other, _, _),
            .followGroupsChanged(let other, _, _):
            other == uploader
        case .watchLaterAdded, .watchLaterRemoved, .favoriteMembershipChanged,
            .removedFromFavoriteFolder, .likeChanged, .coinsAdded, .tripled,
            .recommendationDisliked,
            .recommendationDislikeCancelled, .danmakuPosted, .commentReactionChanged,
            .commentPosted:
            false
        }
    }

    /// 这个人此刻是否有关系写入在途；`inFlight` 被观察，「设置分组…」面板据此禁用「完成」。
    func hasRelationWriteInFlight(mid: Int64) -> Bool {
        guard let uploader = UploaderWriteTarget(mid: mid) else { return false }
        return inFlight.keys.contains { Self.isRelationWrite($0, of: uploader) }
    }

    /// 加入（`isSpecial`）或移出特别关注；返回是否发出。
    ///
    /// 不是已知关注、不知道是否已在特别关注、已是目标状态、是窗口账户自己，或这个人已有关系写入在途时不发。分组未知也可以
    /// 发（特别关注页里的人）：效果的写前关系为 nil，各窗口宽限期后重读人数。
    @discardableResult
    func setFollowSpecial(_ isSpecial: Bool, mid: Int64) -> Bool {
        guard let uploader = UploaderWriteTarget(mid: mid), let account = currentAccount(),
            account.accountID != mid, !hasRelationWriteInFlight(mid: mid),
            let relation = followRelations.relation(of: mid), relation.isFollowing,
            let current = relation.isSpecial, current != isSpecial
        else { return false }
        let before = relation.membership
        let snapshot = followRelations.applyOptimistic(
            .settingSpecial(isSpecial, before: before),
            for: mid
        )
        start(
            .followSpecialChanged(uploader, isSpecial: isSpecial, before: before),
            account: account,
            rollback: { [followRelations] in
                if let snapshot { followRelations.restore(snapshot) }
            },
            write: { [followRelationWrite] in
                try await followRelationWrite.setSpecial(
                    isSpecial,
                    uploader: uploader,
                    accountID: account.accountID,
                    before: before
                )
            }
        )
        return true
    }

    /// 关注页卡片菜单的取消关注：先在关注页列表里去掉卡片，失败或被取消时放回；返回是否发出。
    ///
    /// 卡片在关注页列表里本身就说明已关注，所以不要求关系存储已知（与菜单的可用条件一致）；不在列表里、是窗口账户自己，
    /// 或这个人已有关系写入在途时不发。不碰播放页的互动状态：成功后由效果路由让正在显示这位 UP 主的播放页重读、空间页取
    /// 确认的状态。
    @discardableResult
    func unfollow(mid: Int64) -> Bool {
        guard let uploader = UploaderWriteTarget(mid: mid), let account = currentAccount(),
            account.accountID != mid, !hasRelationWriteInFlight(mid: mid),
            let removal = followSession.removeUser(mid: mid)
        else { return false }
        start(
            .followChanged(uploader, isFollowing: false),
            account: account,
            rollback: { [followSession] in followSession.model.restoreItem(removal) },
            write: { [engagement] in
                try await engagement.setFollowing(
                    false,
                    uploader: uploader,
                    accountID: account.accountID
                )
            }
        )
        return true
    }

    /// 正在显示的「设置分组…」面板，nil 时不显示；`AppShellView` 以它呈现 sheet。
    var followGroupPicker: FollowGroupPickerModel? { followGroupPickerPanel.model }

    /// 打开这个人的「设置分组…」面板；不是已知关注或是窗口账户自己时不打开。
    ///
    /// 已有面板时换成新的。每次打开都让存储读一次单人关系作面板的底（关注页那一页可能已经过时），读到之前不能提交；读到
    /// 这个人已经没有关注时面板关闭（`followDidEnd`）。
    func chooseFollowGroups(mid: Int64) {
        guard let account = currentAccount(), mid > 0, account.accountID != mid,
            followRelations.relation(of: mid)?.isFollowing == true
        else { return }
        let picker = FollowGroupPickerModel(
            mid: mid,
            base: { [followRelations] in Self.pickerBase(followRelations, mid: mid) },
            groups: { [followGroupList] in followGroupList.groups },
            isWriteInFlight: { [weak self] in self?.hasRelationWriteInFlight(mid: mid) ?? false }
        )
        followGroupPickerPanel.open(picker, account: account)
        followRelations.prefetch(mid, refresh: true)
    }

    /// 关系存储记下这个人已经没有关注（读到的、或任一窗口的写入确认）：正在为他打开的「设置分组…」面板关闭。
    func followDidEnd(mid: Int64) {
        guard followGroupPicker?.mid == mid else { return }
        followGroupPickerPanel.close()
    }

    /// 面板的取消，以及 sheet 被系统关闭。
    func dismissFollowGroupPicker() {
        followGroupPickerPanel.close()
    }

    /// 读不到底时的重试：窗口账户已不是打开面板时的账户就关闭面板（规则在 `AccountBoundPanel`），否则再读一次。
    func retryFollowGroupPicker() {
        guard let picker = followGroupPickerPanel.modelForRetry(currentAccount: currentAccount())
        else { return }
        followRelations.prefetch(picker.mid, refresh: true)
    }

    /// 面板的确认：关闭面板；窗口账户仍是打开面板时的账户、勾选与底不同时，提交完整的分组集合。
    func confirmFollowGroupPicker() {
        guard
            let (picker, _) = followGroupPickerPanel.closeForConfirmation(
                currentAccount: currentAccount()
            ),
            let membership = picker.submission
        else { return }
        assignFollowGroups(membership, mid: picker.mid)
    }

    /// 让这个人恰好在 `membership` 的分组里（含特别关注）；返回是否发出。
    ///
    /// 关系存储里这个人的完整分组（面板的底）必须已知，且与 `membership` 不同；是窗口账户自己或已有关系写入在途时不发。
    @discardableResult
    func assignFollowGroups(_ membership: FollowMembership, mid: Int64) -> Bool {
        guard let uploader = UploaderWriteTarget(mid: mid), let account = currentAccount(),
            account.accountID != mid, !hasRelationWriteInFlight(mid: mid),
            case .following(let before) = followRelations.relation(of: mid),
            membership != before
        else { return false }
        let snapshot = followRelations.applyOptimistic(.following(membership), for: mid)
        start(
            .followGroupsChanged(uploader, before: before, after: membership),
            account: account,
            rollback: { [followRelations] in
                if let snapshot { followRelations.restore(snapshot) }
            },
            write: { [followRelationWrite] in
                try await followRelationWrite.assignGroups(
                    membership,
                    uploader: uploader,
                    accountID: account.accountID,
                    before: before
                )
            }
        )
        return true
    }

    /// 面板的底：这次打开的读取还没落地时是加载中，读取失败、或只知道一部分时不能提交，否则是已知的完整分组（读到的，
    /// 宽限期内按写入确认值纠正）。
    private static func pickerBase(
        _ relations: FollowRelationStore,
        mid: Int64
    ) -> FollowGroupPickerModel.Base {
        switch relations.readPhase(of: mid) {
        case .loading: return .loading
        case .failed: return .unavailable
        case nil: return relations.relation(of: mid)?.membership.map { .loaded($0) } ?? .unavailable
        }
    }
}
