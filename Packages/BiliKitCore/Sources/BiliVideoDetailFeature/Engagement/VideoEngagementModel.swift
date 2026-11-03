import BiliApplication
import BiliModels
import Observation

/// 播放页点赞、投币、收藏按钮与侧栏关注按钮的状态：当前账户对正在播放的视频做过什么（是否点赞、投了几枚币、是否收藏、
/// 是否关注了它的 UP 主），按钮旁的计数，以及投币面板是否打开。
///
/// 每个窗口一份，由 App 的窗口组装构造。拥有互动状态的读取 Task（`present` 换视频或换账户时、`reload` 时发出，新读取
/// 替换旧读取，`reset` 取消）、本地对计数的增减与复核代次；不拥有写入（写入 Task 归 App 的写入协调者，它在写入前后调用
/// `applyLike`、`applyFollow`、`restore`、`applyCoins`、`applyTriple` 改这里的状态）。关注状态与点赞同一次读取（同一个账户、
/// 同一套复核），粉丝数不在这里：它是名片读到时的数，关注后不在本地增减。账户只从 App 注入的 `accountID` 闭包读取：它为
/// nil（未登录、认证仍在确认、其他窗口换号待复核）时不读取，按钮显示为禁用、计数照常。
@MainActor
@Observable
public final class VideoEngagementModel: AccountRevalidationParticipant {
    /// 互动状态的读取进度。
    public enum Phase: Sendable, Equatable {
        /// 没有可写入的账户或没有视频：不读取。
        case unavailable
        case loading
        case loaded(VideoEngagementState)
        case failed(ContentApplicationError)
    }

    /// 写入前的状态快照；写入失败或被取消时交回 `restore`。
    public struct Snapshot: Sendable {
        let bvid: String
        let generation: UInt64
        let state: VideoEngagementState
        let adjustment: CountAdjustment
    }

    /// 本地写入对接口计数的增减；换视频或拿到新详情时清零（新详情已含这些写入）。
    struct CountAdjustment: Sendable, Equatable {
        var likes: Int64 = 0
        var coins: Int64 = 0
        var favorites: Int64 = 0
    }

    public private(set) var phase = Phase.unavailable
    /// 正在显示的视频；没有时为 nil。
    public private(set) var bvid: String?
    /// 正在显示的视频的 UP 主 mid；没有视频时为 nil。
    public private(set) var uploaderID: Int64?
    /// 投币面板是否打开；按钮与快捷键 W 打开，面板关闭或投币后清除。
    public var isCoinPanelPresented = false
    public private(set) var authenticationRevalidationGeneration = 0

    private var summary = VideoEngagementSummary()
    private var baseLikeCount: Int64?
    private var adjustment = CountAdjustment()
    @ObservationIgnored private let useCase: VideoEngagementUseCase
    @ObservationIgnored private let accountID: @MainActor () -> Int64?
    @ObservationIgnored private let loadTask = LatestTask()
    /// 读取所属的账户；`present` 发现账户变了就重读。
    @ObservationIgnored private var loadedAccountID: Int64?
    /// 每次换视频、换账户或读取成功时递增；写入前的快照记下它，不符时 `restore` 不放回。
    @ObservationIgnored private var generation: UInt64 = 0
    /// 读取因凭据失败请求的复核进度：请求后等待；复核确认仍登录后自动重读一次，此后直到成功读取或换视频、换账户都不再
    /// 请求，挡住“复核 → 重读 → 失效 → 复核”的循环。
    @ObservationIgnored private var revalidation = RevalidationProgress.none

    private enum RevalidationProgress {
        case none
        case awaiting
        case reloaded
    }

    /// `accountID` 每次读取前求值，给出窗口此刻可写入的账户 mid（与写入门槛同一规则）。
    public init(useCase: VideoEngagementUseCase, accountID: @escaping @MainActor () -> Int64?) {
        self.useCase = useCase
        self.accountID = accountID
    }

    /// 已登录、读到了状态：按钮可用。
    public var engagement: VideoEngagementState? {
        if case .loaded(let state) = phase { state } else { nil }
    }

    public var likeCount: Int64? { baseLikeCount.map { max(0, $0 + adjustment.likes) } }
    public var coinCount: Int64? { summary.coinCount.map { max(0, $0 + adjustment.coins) } }
    public var favoriteCount: Int64? {
        summary.favoriteCount.map { max(0, $0 + adjustment.favorites) }
    }

    /// 是否关注了 UP 主；状态未知（未登录、还没读到、接口没给出）时为 nil。
    public var isFollowingUploader: Bool? { engagement?.isFollowingUploader }

    /// 是否显示关注按钮：有 UP 主，且不是窗口此刻的账户自己（自己的视频没有关注可言）；未登录时显示、由按钮自己禁用。
    public var showsFollowButton: Bool {
        guard let uploaderID, uploaderID > 0 else { return false }
        return uploaderID != accountID()
    }

    /// 还能投几枚；状态未知时为 0。
    public var remainingCoins: Int {
        guard let engagement else { return 0 }
        return VideoCoinRule.remainingCoins(
            isReposted: summary.isReposted,
            coinCount: engagement.coinCount
        )
    }

    /// 播放页出现、换视频、换分 P 或窗口账户变化时调用：视频或账户变了就丢弃旧状态并重读；同一视频拿到新详情时只换
    /// 计数（此前写入留下的快照随之作废：它记的增减是相对旧计数的）；同一视频上次读取失败时再读一次。
    public func present(_ detail: VideoDetail?) {
        let account = accountID()
        guard let detail else {
            reset()
            return
        }
        let detailChanged =
            detail.bvid != bvid || detail.engagementSummary != summary
            || detail.statistics.likeCount != baseLikeCount
        if detailChanged {
            summary = detail.engagementSummary
            baseLikeCount = detail.statistics.likeCount
            adjustment = CountAdjustment()
            generation &+= 1
        }
        guard detail.bvid != bvid || account != loadedAccountID else {
            if case .failed = phase { reload() }
            return
        }
        bvid = detail.bvid
        uploaderID = detail.owner.id
        isCoinPanelPresented = false
        revalidation = .none
        load(account: account, keepingState: false)
    }

    /// 别处的写入改了这个视频的互动（另一窗口点赞、「收藏到…」改了收藏），或本窗口的写入失败、服务端可能已部分生效：
    /// 正在显示它就重读，已有状态时保持显示到新结果到达。
    public func markNeedsReload(bvid: String) {
        guard bvid == self.bvid else { return }
        reloadIfPresented()
    }

    /// 别处关注或取消关注了 `uploaderID`：正在显示他的视频就重读，规则同 `markNeedsReload(bvid:)`。
    public func markNeedsReload(uploaderID: Int64) {
        guard uploaderID == self.uploaderID else { return }
        reloadIfPresented()
    }

    /// 失败后的重试（快捷键在状态未知时也经这里）与外部变化后的重读；已有状态时保持显示，新状态到达时计数按状态的
    /// 变化增减（别处点了赞、改了收藏），重读失败（凭据失效除外）也保留原来的状态。
    public func reload() {
        load(account: accountID(), keepingState: true)
    }

    /// 乐观点赞或取消：改状态与计数，返回写入失败时用来放回的快照；状态未知或不是这个视频时为 nil。
    ///
    /// 不取消在途的读取（它可能是为别处的改动发出的）；它带回写入前的状态时，`stillShows` 在写入成功时报告 false，
    /// 由效果路由再读一次。
    public func applyLike(_ isLiked: Bool, bvid: String) -> Snapshot? {
        guard let snapshot = snapshot(for: bvid), snapshot.state.isLiked != isLiked else {
            return nil
        }
        var state = snapshot.state
        state.isLiked = isLiked
        adjustment.likes += isLiked ? 1 : -1
        phase = .loaded(state)
        return snapshot
    }

    /// 乐观关注或取消关注正在显示的视频的 UP 主，规则同 `applyLike`；关注状态未知或已是目标状态时为 nil。
    ///
    /// 快照与回滚是整份状态：写入协调者让关注与点赞、投币、三连不同时在途，回滚才不会抹掉另一项的乐观改动。
    public func applyFollow(_ isFollowing: Bool, bvid: String) -> Snapshot? {
        guard let snapshot = snapshot(for: bvid),
            let current = snapshot.state.isFollowingUploader, current != isFollowing
        else { return nil }
        var state = snapshot.state
        state.isFollowingUploader = isFollowing
        phase = .loaded(state)
        return snapshot
    }

    /// 写入失败的回滚；此间换了视频、换了账户、拿到新详情、开始或完成过重读，或者有投币、三连写回过时不放回：那之后的
    /// 状态不是这次乐观改动之上的状态，整份放回会抹掉它们。
    public func restore(_ snapshot: Snapshot) {
        guard snapshot.bvid == bvid, snapshot.generation == generation else { return }
        adjustment = snapshot.adjustment
        phase = .loaded(snapshot.state)
    }

    /// 写入成功时，显示的仍是这次乐观点赞或关注之后的状态：此间没有作废快照的变化，也没有在途的读取（它会带回写入前的
    /// 状态）。
    public func stillShows(_ snapshot: Snapshot) -> Bool {
        snapshot.bvid == bvid && snapshot.generation == generation && !loadTask.isRunning
    }

    /// 投币成功：已投数（不超过单个稿件的上限）与计数加上这次的枚数，附带点赞成立时一并点赞。
    public func applyCoins(_ count: Int, alsoLiked: Bool, bvid: String) {
        guard var state = snapshot(for: bvid)?.state else { return }
        let added = addedCoins(count, to: state)
        state.coinCount += added
        adjustment.coins += Int64(added)
        if alsoLiked, !state.isLiked {
            state.isLiked = true
            adjustment.likes += 1
        }
        applyWrite(state)
    }

    /// 三连成功：按服务端逐项结果补上此前没做的点赞与收藏，投币加上实际投出的枚数（不超过上限）。
    public func applyTriple(_ outcome: VideoTripleOutcome, bvid: String) {
        guard var state = snapshot(for: bvid)?.state else { return }
        if outcome.isLiked, !state.isLiked {
            state.isLiked = true
            adjustment.likes += 1
        }
        if outcome.isFavorited, !state.isFavorited {
            state.isFavorited = true
            adjustment.favorites += 1
        }
        let added = addedCoins(outcome.addedCoinCount, to: state)
        state.coinCount += added
        adjustment.coins += Int64(added)
        applyWrite(state)
    }

    /// 离开播放页、登出与关窗：取消读取并丢弃状态。
    public func reset() {
        loadTask.cancel()
        generation &+= 1
        bvid = nil
        uploaderID = nil
        loadedAccountID = nil
        summary = VideoEngagementSummary()
        baseLikeCount = nil
        adjustment = CountAdjustment()
        isCoinPanelPresented = false
        revalidation = .none
        phase = .unavailable
    }

    /// 窗口复核确认仍已登录：本模型请求的复核在下一次成功读取前只自动重读一次。
    public func authenticationRevalidationSucceeded() {
        guard revalidation == .awaiting else { return }
        revalidation = .reloaded
        reload()
    }

    private func reloadIfPresented() {
        switch phase {
        case .loaded, .failed: reload()
        case .unavailable, .loading: break
        }
    }

    /// 不可撤回的写入（投币、三连）成功后的状态：此前的快照作废，挡住更早的点赞失败把它放回；在途的读取是写入之前
    /// 发出的，会带回写入前的状态，换成写入之后的一次重读。
    private func applyWrite(_ state: VideoEngagementState) {
        phase = .loaded(state)
        if loadTask.isRunning {
            reload()
        } else {
            generation &+= 1
        }
    }

    /// 这次实际能加上的币数：已投数不超过单个稿件的上限。
    private func addedCoins(_ count: Int, to state: VideoEngagementState) -> Int {
        max(
            0,
            min(count, VideoCoinRule.remainingCoins(isReposted: false, coinCount: state.coinCount))
        )
    }

    /// 同一视频的状态变了（别处的写入）：计数随之增减，接口计数要到下次拿到详情才更新。
    private func adjustCounts(from previous: VideoEngagementState, to state: VideoEngagementState) {
        adjustment.likes += Int64((state.isLiked ? 1 : 0) - (previous.isLiked ? 1 : 0))
        adjustment.coins += Int64(state.coinCount - previous.coinCount)
        adjustment.favorites += Int64((state.isFavorited ? 1 : 0) - (previous.isFavorited ? 1 : 0))
    }

    private func snapshot(for bvid: String) -> Snapshot? {
        guard bvid == self.bvid, let engagement else { return nil }
        return Snapshot(
            bvid: bvid,
            generation: generation,
            state: engagement,
            adjustment: adjustment
        )
    }

    /// `keepingState` 为 false（换视频、换账户）时先丢掉旧状态，避免把上一个视频或账户的状态当成这一个的。
    private func load(account: Int64?, keepingState: Bool) {
        loadTask.cancel()
        generation &+= 1
        loadedAccountID = account
        guard let account, account > 0, let bvid, let target = VideoWriteTarget(bvid: bvid) else {
            phase = .unavailable
            return
        }
        if !keepingState || engagement == nil { phase = .loading }
        let useCase = useCase
        loadTask.replace { [weak self] isCurrent in
            do {
                let state = try await useCase.engagement(of: target)
                guard let self, isCurrent() else { return }
                if let previous = engagement {
                    adjustCounts(from: previous, to: state)
                }
                generation &+= 1
                revalidation = .none
                phase = .loaded(state)
            } catch is CancellationError {
                // 本任务未被取消却收到取消：认证会话在请求途中切换，由账户变化重新 `present`。
                guard let self, isCurrent() else { return }
                if engagement == nil { phase = .unavailable }
            } catch {
                guard let self, isCurrent() else { return }
                let failure = error as? ContentApplicationError ?? .unavailable
                let isCredentialFailure =
                    failure == .authenticationRequired || failure.requiresAccountRevalidation
                // 已有状态时的重读失败保留原来的状态；凭据失效时不再显示这个账户的状态。
                if keepingState, engagement != nil, !isCredentialFailure { return }
                phase = .failed(failure)
                if isCredentialFailure, revalidation == .none {
                    revalidation = .awaiting
                    authenticationRevalidationGeneration &+= 1
                }
            }
        }
    }
}
