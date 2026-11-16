import BiliApplication
import BiliModels
import Observation

/// 一个窗口里当前账户与每个人的关注关系：关注页卡片的「已关注」菜单与特别关注标记、「设置分组…」面板的底、关系写入的
/// 前置条件与写前关系都只从这里取。
///
/// 每个窗口一个，由 `WindowComposition` 构造。拥有按 mid 的已知关系（`relations`：单人关系的读取、关注页每一页说明的关系、
/// 写入确认的值与乐观改动；没有这一项就是不知道）、单人关系读取的 Task 与状态、写入确认的 `FollowRelationLedger`，以及
/// 宽限期结束时把关注页标记为过期的那一个 Task。不拥有写入（`AccountWriteCoordinator`）、侧栏人数（`FollowGroupListModel`
/// 自己在写入后的宽限期里丢弃旧人数、补读）与关注页列表（`FollowListSession`，经 `markFollowPageStale` 交给它）。
///
/// 关系属于窗口的写入账户（含会话代次）：账户一变（`synchronizeAccount`，或下一次读写时发现）就全部丢弃、取消读取与补读；
/// 读取落地时账户已变的结果丢弃，关注页的一页只记在读取它的账户名下。时刻取 `ContinuousClock.now`。`reset()`（关窗）
/// 取消全部 Task，之后不再读取。单人关系读取只在调用方确认已登录、已关注时发起（`prefetch`）。
@MainActor
@Observable
final class FollowRelationStore {
    /// 单人关系读取的状态；没有这一项表示没有在读、也没有失败过。
    enum ReadPhase: Equatable {
        case loading
        case failed
    }

    /// 乐观改动的凭据：交回 `restore` 放回改动前的关系。
    struct Snapshot {
        fileprivate let mid: Int64
        fileprivate let previous: FollowRelation?
        fileprivate let applied: FollowRelation
        fileprivate let account: WritableAccount
    }

    private var relations: [Int64: FollowRelation] = [:]
    private var reads: [Int64: ReadPhase] = [:]

    /// 宽限期结束时把关注页标记为过期（下次出现时原地刷新）；`WindowComposition` 在关注页构造之后接上一次。
    @ObservationIgnored var markFollowPageStale: @MainActor () -> Void = {}
    /// 记下这个人已经没有关注时（单人关系读到、或写入确认）调用。
    ///
    /// 正在为他打开的「设置分组…」面板随之关闭，不停在“无法读取”。`WindowComposition` 在写入协调者构造之后接上一次。
    @ObservationIgnored var followDidEnd: @MainActor (_ mid: Int64) -> Void = { _ in }

    @ObservationIgnored private let useCase: FollowListUseCase
    @ObservationIgnored private let writableAccount: @MainActor () -> WritableAccount?
    @ObservationIgnored private var ledger = FollowRelationLedger()
    /// `relations`、`reads` 与 `ledger` 属于哪个账户；与此刻的写入账户不同时视为全部作废。
    @ObservationIgnored private var account: WritableAccount?
    @ObservationIgnored private var readTasks: [Int64: Task<Void, Never>] = [:]
    /// 等到宽限期结束再补读的 Task；有新的确认时替换（宽限期随之延长），账户变化与 `reset` 时取消。
    @ObservationIgnored private var graceRecheck: Task<Void, Never>?
    /// 宽限期里欠着关注页的补读：有关系变化，或宽限期里落地过任何一页（那一页可能是写前的旧值，纠正只去掉确认已离开的人，
    /// 刚加入的人不会被插入）。
    @ObservationIgnored private var owesFollowPageRead = false
    @ObservationIgnored private var isClosed = false

    init(useCase: FollowListUseCase, writableAccount: @escaping @MainActor () -> WritableAccount?) {
        self.useCase = useCase
        self.writableAccount = writableAccount
    }

    /// 此刻已知的关系；不知道、或已不是这些关系所属的账户时为 nil。
    func relation(of mid: Int64) -> FollowRelation? {
        guard writableAccount() == account else { return nil }
        return relations[mid]
    }

    /// 单人关系读取的状态；没有在读、也没失败过时为 nil。
    func readPhase(of mid: Int64) -> ReadPhase? {
        guard writableAccount() == account else { return nil }
        return reads[mid]
    }

    /// 是否在特别关注：只对已知关注的人给出（菜单与卡片标记），其余为 nil。
    func specialState(of mid: Int64) -> Bool? {
        guard let relation = relation(of: mid), relation.isFollowing else { return nil }
        return relation.isSpecial
    }

    /// 读一次这个人的单人关系；调用方确认已登录且这个人已关注。
    ///
    /// `refresh` 为 true 时（「设置分组…」面板打开与重试）总是读：面板以它为完整集合的底，关注页那一页可能已经过时。否则
    /// （「已关注」菜单的预读）只在不知道完整分组、上次读取失败，或存储记着没有关注（与调用方矛盾，例如在网页上重新关注了）
    /// 时读。正在读时都不再发。
    ///
    /// 宽限期内读到的旧值由 `ledger` 按确认值纠正。读取失败只记为失败、由调用方给出重试，不在这里请求账户复核：凭据真的
    /// 失效时，写入与常驻的侧栏读取会请求。
    func prefetch(_ mid: Int64, refresh: Bool = false) {
        synchronizeAccount()
        guard !isClosed, let account, mid > 0, reads[mid] != .loading else { return }
        guard refresh || reads[mid] == .failed || relations[mid]?.membership == nil else { return }
        reads[mid] = .loading
        let useCase = useCase
        readTasks[mid] = Task { [weak self] in
            do {
                let membership = try await useCase.relation(to: mid)
                guard let self, !Task.isCancelled, self.account == account else { return }
                let read = self.ledger.reconciled(
                    FollowRelation(read: membership),
                    for: mid,
                    at: .now
                )
                self.relations[mid] = read
                self.reads[mid] = nil
                self.readTasks[mid] = nil
                if read == .notFollowing { self.followDidEnd(mid) }
            } catch {
                guard let self, !Task.isCancelled, self.account == account else { return }
                self.reads[mid] = .failed
                self.readTasks[mid] = nil
            }
        }
    }

    /// 写入确认这个人的关系（效果路由在每个窗口调用）：记进 ledger，取代已知的关系，并在宽限期后让关注页重读（刚关注或刚
    /// 加入某个分组的人不会被插入）。
    func confirm(_ relation: FollowRelation, for mid: Int64) {
        synchronizeAccount()
        guard !isClosed, account != nil else { return }
        ledger.confirm(relation, for: mid, at: .now)
        relations[mid] = relation
        owesFollowPageRead = true
        scheduleGraceRecheck()
        if relation == .notFollowing { followDidEnd(mid) }
    }

    /// 关注页每一页落地时调用（`FollowListViewModel` 的 `reconcile`）：按 ledger 纠正这一页，记下这一页说明的关系，宽限期
    /// 里落地的页在宽限期后重读。
    ///
    /// 在列表核对这一页是否仍是最新意图之前调用，所以先按 `ownerID`（读取这一页用的账户 mid）核对：请求途中窗口换了号，
    /// 迟到的页原样交回、什么都不记，否则上一账户的关系会记到新账户名下。
    func reconcile(
        _ users: [FollowedUser],
        in query: FollowListQuery,
        ownerID: Int64
    ) -> [FollowedUser] {
        synchronizeAccount()
        guard account?.accountID == ownerID else { return users }
        let now = ContinuousClock.now
        let reconciled = ledger.reconciled(users, in: query, at: now)
        for user in reconciled {
            relations[user.id] = FollowRelation.merging(
                ledger.reconciled(.implied(by: user, in: query), for: user.id, at: now),
                over: relations[user.id],
                in: query
            )
        }
        if ledger.graceEnd(at: now) != nil {
            owesFollowPageRead = true
            scheduleGraceRecheck()
        }
        return reconciled
    }

    /// 关系写入的乐观改动（特别关注与设置分组）；账户不符时为 nil。
    ///
    /// 失败或被取消时交回 `restore`。
    func applyOptimistic(_ relation: FollowRelation, for mid: Int64) -> Snapshot? {
        synchronizeAccount()
        guard let account else { return nil }
        let snapshot = Snapshot(
            mid: mid,
            previous: relations[mid],
            applied: relation,
            account: account
        )
        relations[mid] = relation
        return snapshot
    }

    /// 放回乐观改动前的关系；此间账户变了、或这个人的关系已被别的值取代（读取落地、写入确认）时不放回。
    func restore(_ snapshot: Snapshot) {
        guard account == snapshot.account, relations[snapshot.mid] == snapshot.applied else {
            return
        }
        relations[snapshot.mid] = snapshot.previous
    }

    /// 窗口的写入账户变了：丢弃上一账户的关系、读取与补读。
    func synchronizeAccount() {
        let current = writableAccount()
        guard current != account else { return }
        clear()
        account = current
    }

    /// 关窗：取消全部读取与补读，丢弃关系，之后不再读取；不可逆。
    func reset() {
        isClosed = true
        clear()
    }

    private func clear() {
        for task in readTasks.values { task.cancel() }
        readTasks.removeAll()
        graceRecheck?.cancel()
        graceRecheck = nil
        relations.removeAll()
        reads.removeAll()
        ledger = FollowRelationLedger()
        owesFollowPageRead = false
    }

    /// 等到宽限期结束（此间有新的确认就等到新的结束时刻），再做欠着的补读。
    private func scheduleGraceRecheck() {
        guard let graceEnd = ledger.graceEnd(at: .now) else {
            performOwedRereads()
            return
        }
        graceRecheck?.cancel()
        graceRecheck = Task { [weak self] in
            try? await Task.sleep(until: graceEnd, clock: .continuous)
            guard let self, !Task.isCancelled else { return }
            self.scheduleGraceRecheck()
        }
    }

    private func performOwedRereads() {
        graceRecheck = nil
        if owesFollowPageRead {
            owesFollowPageRead = false
            markFollowPageStale()
        }
    }
}
