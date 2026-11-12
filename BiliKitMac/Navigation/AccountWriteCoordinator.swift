import BiliApplication
import BiliBrowseFeature
import BiliLibraryFeature
import BiliVideoDetailFeature
import Observation

/// 一个窗口里用户发起的账户写入的 owner：卡片菜单（含首页推荐的「不感兴趣」）、读屏操作、⌘⌫、「收藏到…」面板、
/// 播放页的点赞、投币、三连按钮与快捷键、播放侧栏的关注按钮，以及播放器输入胶囊发出的弹幕都交给它。
///
/// 拥有每个在途写入的 Task（同一改动同时只有一个）、正在显示的「收藏到…」面板（`favoritePicker`，同时只有一个；归属的
/// 读取 Task 归面板模型）、写入结果胶囊显示的最新结果与它的消失计时，以及窗口复核的参与者代次。不拥有门槛的判断
/// （`writableAccount` 由 `WindowComposition` 按窗口账户算出）、写请求本身（`WatchLaterWriteUseCase`、
/// `FavoritesWriteUseCase`、`VideoEngagementUseCase`、`RecommendationFeedbackUseCase`、`DanmakuPostUseCase`）、列表与互动状态（乐观改动与回滚在
/// `WatchLaterViewModel`、`FavoriteFolderViewModel`、`VideoEngagementModel`、`BrowseViewModel`），也不直接刷新其他视图（效果交给本窗口的
/// `AccountWriteEffectRouter`，并经进程级集线器转给其他窗口）。
///
/// 每次执行都重新核对：卡片 ID 必须是合法 BVID、窗口此刻满足写入门槛，否则不发请求（菜单项可能是在门槛变化前构造的）。
/// 失败不重试、不排队；凭据类失败（`requiresAccountRevalidation`）递增一次复核代次，此后在同一账户与会话代次里直到下一次
/// 写入成功都不再自动复核，避免“复核 → 仍失败 → 再复核”；换号或登出再登录后会话代次变化，节流随之作废。面板绑定打开时
/// 的窗口账户（含会话代次）：窗口账户一变（`writableAccountDidChange`）就关闭，重试与确认前再核对一次，面板里的收藏夹
/// 与归属不会在另一个账户下显示、重读或提交。`close()`（关窗）关闭面板、取消全部在途写入与计时，之后不再接受意图；
/// 被取消的写入照常回滚本地的乐观改动、不显示结果。
@MainActor
@Observable
final class AccountWriteCoordinator: AccountRevalidationParticipant {
    /// 写入结果胶囊停留的时长。
    ///
    /// 够读完两行说明；读屏另有通告，不依赖胶囊停留。调长会让连续操作时旧结果盖住新内容更久。
    static let reportDisplayDuration: Duration = .seconds(4)
    /// 带「在浏览器中打开」的结果停留的时长（`AccountWriteReport.webFallbackURL`）。
    ///
    /// 要留出读完说明、再把指针移过去点按的时间；调短来不及点，调长会久久盖住相关推荐。
    static let actionableReportDisplayDuration: Duration = .seconds(8)

    /// 胶囊显示的最新结果；nil 时不显示。
    private(set) var report: AccountWriteReport?
    /// 每出现一条新结果递增；胶囊据此在相同结果连续出现时也重新通告。
    private(set) var reportSequence: UInt64 = 0
    /// 写入遇到凭据类失败时递增（`AccountRevalidationParticipant`），窗口汇总后复核一次。
    private(set) var authenticationRevalidationGeneration = 0
    /// 正在显示的「收藏到…」面板，nil 时不显示。
    ///
    /// `AppShellView` 以它呈现 sheet。
    private(set) var favoritePicker: FavoritePickerModel?

    @ObservationIgnored private let watchLater: WatchLaterWriteUseCase
    @ObservationIgnored private let watchLaterModel: WatchLaterViewModel
    @ObservationIgnored private let favoritesWrite: FavoritesWriteUseCase
    /// 面板读取归属用的读取 use case。
    @ObservationIgnored private let favorites: FavoritesUseCase
    @ObservationIgnored private let favoriteFolders: FavoriteFolderViewModel
    @ObservationIgnored private let engagement: VideoEngagementUseCase
    @ObservationIgnored private let engagementModel: VideoEngagementModel
    @ObservationIgnored private let recommendationFeedback: RecommendationFeedbackUseCase
    @ObservationIgnored private let danmakuPost: DanmakuPostUseCase
    @ObservationIgnored private let browseModel: BrowseViewModel
    @ObservationIgnored private let writableAccount: @MainActor () -> WritableAccount?
    @ObservationIgnored private let publish:
        @MainActor (AccountWriteEffectDelivery, _ appliedLocally: Bool) -> Void
    /// 在途写入，按改动去重；完成、失败或取消时移除。
    @ObservationIgnored private var inFlight: [AccountWriteChange: Task<Void, Never>] = [:]
    @ObservationIgnored private var reportDismissal: Task<Void, Never>?
    /// 因凭据类失败请求过复核时的账户与会话代次；此后还没有写入成功。
    ///
    /// 失败时的账户与它相同就不再递增复核代次；写入成功时清空，账户或会话代次不同（换号、登出再登录）时视为作废，避免
    /// 上一会话的节流让新会话的写入再也不复核。
    @ObservationIgnored private var revalidationRequestedFor: WritableAccount?
    /// 打开面板时的窗口账户；面板关闭时清空。
    @ObservationIgnored private var favoritePickerAccount: WritableAccount?
    @ObservationIgnored private var isClosed = false

    /// `publish` 把成功的效果交给本窗口的效果路由与其他窗口（`WindowComposition` 接线）。
    init(
        watchLater: WatchLaterWriteUseCase,
        watchLaterModel: WatchLaterViewModel,
        favoritesWrite: FavoritesWriteUseCase,
        favorites: FavoritesUseCase,
        favoriteFolders: FavoriteFolderViewModel,
        engagement: VideoEngagementUseCase,
        engagementModel: VideoEngagementModel,
        recommendationFeedback: RecommendationFeedbackUseCase,
        danmakuPost: DanmakuPostUseCase,
        browseModel: BrowseViewModel,
        writableAccount: @escaping @MainActor () -> WritableAccount?,
        publish: @escaping @MainActor (AccountWriteEffectDelivery, _ appliedLocally: Bool) -> Void
    ) {
        self.watchLater = watchLater
        self.watchLaterModel = watchLaterModel
        self.favoritesWrite = favoritesWrite
        self.favorites = favorites
        self.favoriteFolders = favoriteFolders
        self.engagement = engagement
        self.engagementModel = engagementModel
        self.recommendationFeedback = recommendationFeedback
        self.danmakuPost = danmakuPost
        self.browseModel = browseModel
        self.writableAccount = writableAccount
        self.publish = publish
    }

    /// 写入门槛：窗口已确认登录且 mid 已知、不在复核中、没有待复核的外部换号，且窗口未关闭；菜单项据此启用或禁用。
    var isWritable: Bool {
        !isClosed && writableAccount() != nil
    }

    /// 窗口此刻的写入账户；`AppShellView` 观察它的变化并调用 `writableAccountDidChange`。
    var currentWritableAccount: WritableAccount? {
        currentAccount()
    }

    /// 加入稍后再看；返回是否发出（BVID 不合法、没有写入账户或同一视频已在途时不发）。
    @discardableResult
    func addToWatchLater(bvid: String) -> Bool {
        guard let target = VideoWriteTarget(bvid: bvid), let account = currentAccount(),
            inFlight[.watchLaterAdded(target)] == nil
        else { return false }
        start(.watchLaterAdded(target), account: account) { [watchLater] in
            try await watchLater.add(target, accountID: account.accountID)
        }
        return true
    }

    /// 先在本窗口的稍后再看列表里乐观移除，失败或被取消时放回原位（列表此间被整体替换时由模型丢弃这次回滚）。
    func removeFromWatchLater(bvid: String) {
        guard let target = VideoWriteTarget(bvid: bvid), let account = currentAccount() else {
            return
        }
        let change = AccountWriteChange.watchLaterRemoved(target)
        guard inFlight[change] == nil else { return }
        let removal = watchLaterModel.removeItem(bvid: bvid)
        start(
            change,
            account: account,
            appliedLocally: { removal != nil },
            rollback: { [watchLaterModel] in
                if let removal { watchLaterModel.restoreItem(removal) }
            },
            write: { [watchLater] in
                try await watchLater.remove(target, accountID: account.accountID)
            }
        )
    }

    /// 点赞或取消：先在播放页的互动状态里乐观改动，失败或被取消时放回（此间状态被重读、换掉或有投币三连写回时由模型
    /// 丢弃这次回滚）；返回是否发出。
    ///
    /// 写入成功时页面是否仍是乐观改动后的样子在那一刻判断（`stillShows`）：期间有读取落地或在途，就让效果路由重读。
    @discardableResult
    func setLiked(_ isLiked: Bool, bvid: String) -> Bool {
        guard let target = VideoWriteTarget(bvid: bvid), let account = currentAccount(),
            !hasEngagementWriteInFlight(for: target)
        else { return false }
        let snapshot = engagementModel.applyLike(isLiked, bvid: bvid)
        start(
            .likeChanged(target, isLiked: isLiked),
            account: account,
            appliedLocally: { [engagementModel] in
                snapshot.map(engagementModel.stillShows) ?? false
            },
            rollback: { [engagementModel] in
                if let snapshot { engagementModel.restore(snapshot) }
            },
            write: { [engagement] in
                try await engagement.setLiked(isLiked, target: target, accountID: account.accountID)
            }
        )
        return true
    }

    /// 投币：成功后才改播放页的已投数与计数（不可撤回，不做乐观改动）；返回是否发出。
    ///
    /// 枚数超过播放页此刻算出的可投数（含转载只能投 1 枚）时不发；失败或被取消时重读互动状态：服务端可能已经扣了币，
    /// 只是没拿到可判定的结果。
    @discardableResult
    func addCoins(_ count: Int, alsoLike: Bool, bvid: String) -> Bool {
        guard let target = VideoWriteTarget(bvid: bvid), let account = currentAccount(),
            !hasEngagementWriteInFlight(for: target),
            engagementModel.bvid == bvid, count >= 1, count <= engagementModel.remainingCoins
        else { return false }
        start(
            .coinsAdded(target, count: count, alsoLiked: alsoLike),
            account: account,
            appliedLocally: { true },
            rollback: { [engagementModel] in engagementModel.markNeedsReload(bvid: bvid) },
            write: { [engagement, engagementModel] in
                let effect = try await engagement.addCoins(
                    count,
                    alsoLike: alsoLike,
                    target: target,
                    accountID: account.accountID
                )
                if case .coinsAdded(_, let added, let liked) = effect.change {
                    engagementModel.applyCoins(added, alsoLiked: liked, bvid: bvid)
                }
                return effect
            }
        )
        return true
    }

    /// 三连：成功后按服务端逐项结果改播放页的状态，收藏进默认收藏夹，由效果路由刷新收藏夹；返回是否发出。
    ///
    /// 失败或被取消时重读互动状态，理由同投币。
    @discardableResult
    func triple(bvid: String) -> Bool {
        guard let target = VideoWriteTarget(bvid: bvid), let account = currentAccount(),
            !hasEngagementWriteInFlight(for: target)
        else { return false }
        start(
            .tripled(target, nil),
            account: account,
            appliedLocally: { true },
            rollback: { [engagementModel] in engagementModel.markNeedsReload(bvid: bvid) },
            write: { [engagement, engagementModel] in
                let effect = try await engagement.triple(
                    target: target,
                    accountID: account.accountID
                )
                if case .tripled(_, let outcome?) = effect.change {
                    engagementModel.applyTriple(outcome, bvid: bvid)
                }
                return effect
            }
        )
        return true
    }

    /// 关注或取消关注播放页此刻显示的视频的 UP 主：先在互动状态里乐观改动，失败或被取消时放回，成功时的判断同点赞；
    /// 返回是否发出。
    ///
    /// UP 主取自互动状态（`bvid` 必须仍是它正在显示的视频），按钮不给 mid。关注状态未知、已是目标状态、UP 主就是窗口账户
    /// 自己，或播放页还有互动写入在途时不发（理由见 `hasEngagementWriteInFlight`）。
    @discardableResult
    func setFollowing(_ isFollowing: Bool, bvid: String) -> Bool {
        guard engagementModel.bvid == bvid,
            let uploader = engagementModel.uploaderID.flatMap(UploaderWriteTarget.init(mid:)),
            let account = currentAccount(), account.accountID != uploader.mid,
            !inFlight.keys.contains(where: Self.isEngagementWrite),
            let snapshot = engagementModel.applyFollow(isFollowing, bvid: bvid)
        else { return false }
        start(
            .followChanged(uploader, isFollowing: isFollowing),
            account: account,
            appliedLocally: { [engagementModel] in engagementModel.stillShows(snapshot) },
            rollback: { [engagementModel] in engagementModel.restore(snapshot) },
            write: { [engagement] in
                try await engagement.setFollowing(
                    isFollowing,
                    uploader: uploader,
                    accountID: account.accountID
                )
            }
        )
        return true
    }

    /// 同一视频的点赞、投币、三连同时只发一个，关注在途时它们一个也不发。
    ///
    /// 它们都可能改点赞，两个请求到达服务端的先后不可知，最终状态可能与界面相反；两次投币同时在途也可能超过可投数。关注
    /// 也只在它们都不在途时发：互动状态的乐观改动与回滚按整份快照进行，同时在途时一方失败的回滚会抹掉另一方的乐观改动。
    private func hasEngagementWriteInFlight(for target: VideoWriteTarget) -> Bool {
        inFlight.keys.contains { change in
            switch change {
            case .likeChanged(let other, _), .coinsAdded(let other, _, _), .tripled(let other, _):
                other == target
            case .followChanged:
                true
            case .watchLaterAdded, .watchLaterRemoved, .favoriteMembershipChanged,
                .removedFromFavoriteFolder, .recommendationDisliked,
                .recommendationDislikeCancelled, .danmakuPosted:
                false
            }
        }
    }

    /// 写播放页互动状态的写入：点赞、投币、三连与关注。
    private static func isEngagementWrite(_ change: AccountWriteChange) -> Bool {
        switch change {
        case .likeChanged, .coinsAdded, .tripled, .followChanged:
            true
        case .watchLaterAdded, .watchLaterRemoved, .favoriteMembershipChanged,
            .removedFromFavoriteFolder, .recommendationDisliked, .recommendationDislikeCancelled,
            .danmakuPosted:
            false
        }
    }

    /// 首页推荐的「不感兴趣」：先在推荐网格里乐观标上，失败或被取消时去掉标记。
    ///
    /// 推荐工作集里没有这一条、或已经标过时不发；此间推荐工作集被换掉、或标记已不是这一份时由模型丢弃这次回滚。
    func dislikeRecommendation(_ feedback: RecommendationFeedback) {
        guard let account = currentAccount(),
            !hasRecommendationFeedbackInFlight(for: feedback.target),
            let edit = browseModel.markRecommendationDisliked(feedback)
        else { return }
        start(
            .recommendationDisliked(feedback),
            account: account,
            rollback: { [browseModel] in browseModel.revertRecommendationDislike(edit) },
            write: { [recommendationFeedback] in
                try await recommendationFeedback.dislike(feedback, accountID: account.accountID)
            }
        )
    }

    /// 撤销「不感兴趣」：先去掉标记，失败或被取消时标回。
    ///
    /// 卡片已不是标着这份反馈时不发：撤销必须带发出时的同一份字段。标回只在同一份推荐工作集里、卡片仍显示时进行，换了
    /// 账户后的新推荐即使有同一视频也不会被标上旧账户的反馈。
    func cancelRecommendationDislike(_ feedback: RecommendationFeedback) {
        guard let account = currentAccount(),
            !hasRecommendationFeedbackInFlight(for: feedback.target),
            let edit = browseModel.unmarkRecommendationDisliked(feedback)
        else { return }
        start(
            .recommendationDislikeCancelled(feedback),
            account: account,
            rollback: { [browseModel] in browseModel.revertRecommendationDislike(edit) },
            write: { [recommendationFeedback] in
                try await recommendationFeedback.cancelDislike(
                    feedback,
                    accountID: account.accountID
                )
            }
        )
    }

    /// 同一视频的「不感兴趣」与撤销同时只发一个：两者到达服务端的先后不可知，最终状态可能与卡片相反。
    ///
    /// 菜单不随在途写入禁用（与点赞、投币、三连相同）：在途时再点同一视频的反馈项不发、也不提示，等它结束即可再操作。
    private func hasRecommendationFeedbackInFlight(for target: VideoWriteTarget) -> Bool {
        inFlight.keys.contains { change in
            switch change {
            case .recommendationDisliked(let feedback),
                .recommendationDislikeCancelled(let feedback):
                feedback.target == target
            case .watchLaterAdded, .watchLaterRemoved, .favoriteMembershipChanged,
                .removedFromFavoriteFolder, .likeChanged, .coinsAdded, .tripled, .followChanged,
                .danmakuPosted:
                false
            }
        }
    }

    /// 发一条弹幕；返回是否发出：BVID 不合法、没有写入账户，或本窗口已有一条弹幕在途时不发。
    ///
    /// 结局交给 `completion`（输入胶囊据此上屏或在胶囊下方说明），不进写入结果胶囊：全屏时看不到窗口底部的胶囊，窗口下
    /// 两处同时说明又重复；也不产生跨视图效果。同一窗口同时只有一条在途，不按正文区分，免得连按回车发出两条。
    @discardableResult
    func postDanmaku(
        _ request: DanmakuPostRequest,
        completion: @escaping @MainActor (DanmakuPostOutcome) -> Void
    ) -> Bool {
        guard let target = VideoWriteTarget(bvid: request.identity.bvid),
            let account = currentAccount(),
            !inFlight.keys.contains(where: Self.isDanmakuPost)
        else { return false }
        run(
            .danmakuPosted(target),
            account: account,
            write: { [danmakuPost] in
                try await danmakuPost.post(request, accountID: account.accountID)
            },
            finished: { outcome in
                switch outcome {
                case .succeeded(let receipt): completion(.posted(receipt))
                case .failed(let error): completion(.failed(error))
                case .cancelled: completion(.cancelled)
                }
            }
        )
        return true
    }

    private static func isDanmakuPost(_ change: AccountWriteChange) -> Bool {
        if case .danmakuPosted = change { true } else { false }
    }

    /// 打开这个视频的「收藏到…」面板并读取归属。
    ///
    /// 已有面板时换成新的（旧面板的读取取消）；门槛不满足时不打开。
    func chooseFavoriteFolders(bvid: String) {
        guard let target = VideoWriteTarget(bvid: bvid), let account = currentAccount() else {
            return
        }
        favoritePicker?.cancel()
        let picker = FavoritePickerModel(
            target: target,
            accountID: account.accountID,
            useCase: favorites,
            onCredentialFailure: { [weak self] in self?.requestRevalidation(for: account) }
        )
        favoritePicker = picker
        favoritePickerAccount = account
        picker.load()
    }

    /// 面板的取消，以及 sheet 被系统关闭。
    func dismissFavoritePicker() {
        favoritePicker?.cancel()
        favoritePicker = nil
        favoritePickerAccount = nil
    }

    /// 面板读取失败后的重试：窗口账户已不是打开面板时的账户就关闭面板，否则重读。
    ///
    /// 面板的读取固定用打开时的 mid；账户变了还重读，就会用新账户的 Cookie 读旧账户的 mid（见 SECURITY-MODEL §3）。
    func retryFavoritePicker() {
        guard let picker = favoritePicker else { return }
        guard currentAccount() == favoritePickerAccount else {
            dismissFavoritePicker()
            return
        }
        picker.load()
    }

    /// 窗口的写入账户变了（登出、换号、其他窗口换号待复核、会话代次变化）：属于旧账户的面板立即关闭，它列出的收藏夹
    /// 与归属不再显示。
    func writableAccountDidChange() {
        guard favoritePicker != nil, currentAccount() != favoritePickerAccount else { return }
        dismissFavoritePicker()
    }

    /// 面板的确认：关闭面板，有改动时提交。
    ///
    /// 窗口账户此刻必须仍是打开面板时的账户：换号或登出后面板里的归属属于上一账户，按它提交会改动错的账户，直接丢弃。
    func confirmFavoritePicker() {
        guard let picker = favoritePicker else { return }
        let pickerAccount = favoritePickerAccount
        dismissFavoritePicker()
        guard let change = picker.change,
            let account = currentAccount(),
            account == pickerAccount
        else { return }
        start(.favoriteMembershipChanged(change), account: account) { [favoritesWrite] in
            try await favoritesWrite.update(change, accountID: account.accountID)
        }
    }

    /// 收藏夹页的「从此收藏夹移除」：先在显示中的收藏夹里乐观移除，失败或被取消时放回原位（此间内容被整体替换时由模型
    /// 丢弃这次回滚）。
    ///
    /// 写入成功时页面是否仍是移除后的样子在那一刻判断：期间刷新落地（或仍在途）会带回写入前的快照，这时要让效果路由
    /// 重读，不能沿用开始时“已在本地改过”的结论。
    func removeFromFavoriteFolder(_ entry: FavoriteFolderEntry) {
        guard let account = currentAccount() else { return }
        let change = AccountWriteChange.removedFromFavoriteFolder(entry)
        guard inFlight[change] == nil else { return }
        let removal = favoriteFolders.removeItem(entry)
        start(
            change,
            account: account,
            appliedLocally: { [favoriteFolders] in
                removal.map(favoriteFolders.stillShowsRemoval) ?? false
            },
            rollback: { [favoriteFolders] in
                if let removal { favoriteFolders.restoreItem(removal) }
            },
            write: { [favoritesWrite] in
                try await favoritesWrite.remove(entry, accountID: account.accountID)
            }
        )
    }

    /// 关窗：关闭面板，取消全部在途写入与胶囊计时，之后不再接受意图；不可逆。
    func close() {
        dismissFavoritePicker()
        isClosed = true
        for task in inFlight.values { task.cancel() }
        inFlight.removeAll()
        reportDismissal?.cancel()
        reportDismissal = nil
        report = nil
    }

    private func currentAccount() -> WritableAccount? {
        guard !isClosed else { return nil }
        return writableAccount()
    }

    /// `appliedLocally` 在写入成功时求值：本窗口的视图此刻是否已经是写入后的样子。
    ///
    /// 结果进写入结果胶囊，成功的效果交给效果路由与其他窗口；写入没有成功（失败或被取消）时先 `rollback`。
    private func start(
        _ change: AccountWriteChange,
        account: WritableAccount,
        appliedLocally: @escaping @MainActor () -> Bool = { false },
        rollback: @escaping @MainActor () -> Void = {},
        write: @escaping @MainActor () async throws -> AccountWriteEffect
    ) {
        run(change, account: account, write: write) { [weak self] outcome in
            switch outcome {
            case .succeeded(let effect):
                // 按服务端确认的改动说明结果：投币附带的点赞没有成立时不说“并点赞”。
                self?.show(AccountWriteReport(change: effect.change, failure: nil))
                self?.publish(
                    AccountWriteEffectDelivery(
                        effect: effect,
                        sessionGeneration: account.sessionGeneration
                    ),
                    appliedLocally()
                )
            case .failed(let error):
                rollback()
                self?.show(AccountWriteReport(change: change, failure: error))
            case .cancelled:
                rollback()
            }
        }
    }

    /// 一次写入的结局，交给发起方的处理。
    private enum Outcome<Value> {
        case succeeded(Value)
        case failed(AccountWriteError)
        /// 被取消（关窗、认证会话在请求途中切换时 API 按取消结束），或失败时窗口已关闭：不说明结果。
        case cancelled
    }

    /// 所有写入共用的在途登记：同一改动同时只有一个；结束时移除登记，凭据类失败按节流请求复核，写入成功清除节流。
    ///
    /// 窗口关闭后成功的写入不交给 `finished`（视图已不在），失败的按 `cancelled` 交出，发起方照常回滚本地改动。
    private func run<Value>(
        _ change: AccountWriteChange,
        account: WritableAccount,
        write: @escaping @MainActor () async throws -> Value,
        finished: @escaping @MainActor (Outcome<Value>) -> Void
    ) {
        guard inFlight[change] == nil else { return }
        inFlight[change] = Task { [weak self] in
            do {
                let value = try await write()
                self?.inFlight[change] = nil
                guard let self, !self.isClosed else { return }
                self.revalidationRequestedFor = nil
                finished(.succeeded(value))
            } catch is CancellationError {
                self?.inFlight[change] = nil
                finished(.cancelled)
            } catch {
                self?.inFlight[change] = nil
                guard let self, !self.isClosed else {
                    finished(.cancelled)
                    return
                }
                let error = error as? AccountWriteError ?? .unavailable
                if error.requiresAccountRevalidation {
                    self.requestRevalidation(for: account)
                }
                finished(.failed(error))
            }
        }
    }

    /// 写入或面板读取遇到凭据类失败：同一账户与会话代次里只请求一次复核，直到下一次写入成功。
    private func requestRevalidation(for account: WritableAccount) {
        guard !isClosed, revalidationRequestedFor != account else { return }
        revalidationRequestedFor = account
        authenticationRevalidationGeneration &+= 1
    }

    private func show(_ report: AccountWriteReport) {
        self.report = report
        reportSequence &+= 1
        let sequence = reportSequence
        reportDismissal?.cancel()
        reportDismissal = Task { [weak self] in
            try? await Task.sleep(
                for: report.webFallbackURL == nil
                    ? Self.reportDisplayDuration : Self.actionableReportDisplayDuration
            )
            guard !Task.isCancelled, let self, self.reportSequence == sequence else { return }
            self.report = nil
        }
    }
}
