import BiliApplication
import BiliModels
import Foundation
import Observation

/// 侧栏里按账户读取的一组行（收藏夹、关注分组）的呈现状态。
public enum LibrarySidebarListState<Value: Sendable & Equatable>: Sendable, Equatable {
    case idle
    case loading
    case loaded(Value)
    case failed(ContentApplicationError)
    /// 窗口已登录但不知道当前账户的 mid（`AccountSessionScope.signedIn(accountID: nil)`）：无法读取，需要复核或重新登录，
    /// 不给重试。
    case accountUnidentified
}

/// 侧栏里按账户读取的一组行：「收藏夹」组的收藏夹列表、「关注」组的分组与人数共用的加载、账户绑定与复核规则。
///
/// 每个窗口每组一份，由 App 的窗口组装构造。拥有读到的值、加载 Task 与它自己的账户复核进度；不拥有选中的行与行对应的
/// 页面内容（各来源的页面模型，每次加载成功经 `onLoaded` 通知它回落选择）。mid 只从 App 注入的窗口账户范围读取
/// （`accountScope`），adapter 不自己取账户。
///
/// 它是窗口级复核参与者（不绑定来源）：这些行是侧栏常驻的元数据，窗口已登录就读取，不论当前来源；首次加载由导航侧栏
/// 出现时的 `synchronize()` 触发（未解析到已登录不算账户变化，不会收到账户变化通知），账户范围变化时由来源的描述 `reset`
/// 后重新 `synchronize()`，关窗与其他窗口换号时 `reset`。行对应的页面内容仍绑定来源，不在本页时不读取（见 SECURITY-MODEL
/// §3）。
///
/// 写入成功后条数在本地增减（`adjustAfterWrite`）：写后立刻重读到的条数可能还是写前的旧值，宽限期
/// （`countReadLagGrace`）内落地的后台重读一律丢弃，宽限期结束时由本模型持有的唯一一个 Task 补读一次。
@MainActor
@Observable
public final class LibrarySidebarListModel<Value: Sendable & Equatable>:
    AccountRevalidationParticipant
{
    public private(set) var state: LibrarySidebarListState<Value> = .idle
    /// 已有列表时的后台重读正在进行：侧栏照常显示原有的行，直到新列表到达。
    ///
    /// 重读成功整体替换；凭据失败放弃旧列表（与资料库其他来源一致），其余失败保留旧列表。
    public private(set) var isRefreshing = false

    /// 读取发现凭据缺失、失效或可疑（由各组的读取判断，如自己视角下没有默认收藏夹）时递增；规则在共用的
    /// `AccountRevalidationProgress`。
    public var authenticationRevalidationGeneration: Int {
        revalidation.generation
    }

    /// 本列表请求的账户复核尚未结束；侧栏据此把失败行显示为加载中。
    public var isAwaitingAuthenticationRevalidation: Bool {
        revalidation.isAwaiting
    }

    /// 已加载的值；其他状态为 nil。
    public var loadedValue: Value? {
        if case .loaded(let value) = state { value } else { nil }
    }

    /// 每次加载成功后调用一次，参数是新值；由行对应的页面模型构造时设置一次，用来回落已不存在的选择。
    @ObservationIgnored var onLoaded: (@MainActor (Value) -> Void)?

    private var revalidation = AccountRevalidationProgress()
    @ObservationIgnored private let read: @Sendable (_ accountID: Int64) async throws -> Value
    @ObservationIgnored private let accountScope: @MainActor () -> AccountSessionScope
    /// 写入之后多久内不信任后台重读到的条数。
    ///
    /// 关注分组的人数实测写后立刻读到旧值、几秒内一致（与 `FollowRelationLedger.relationReadLagGrace` 同一次实测）；收藏夹
    /// 条数实机上同样迟到，没有单独量过，沿用同一取值。调长时宽限期内条数更久不随服务端变化、补读更晚；调短时迟到的旧值
    /// 会在宽限期结束后把条数改回写前。
    static var countReadLagGrace: Duration { .seconds(15) }

    /// 最近一次写入的宽限期结束时刻；`adjustAfterWrite` 设置（新的写入延长），补读或 `reset` 时清空。
    @ObservationIgnored private var countGraceEnd: ContinuousClock.Instant?
    /// 等到宽限期结束再补读的 Task；新的写入替换它，`reset` 取消。
    @ObservationIgnored private var graceReread: Task<Void, Never>?
    /// 当前状态（加载中、值或失败）属于哪个账户；开始读取时记录，`reset` 时清空。
    ///
    /// 账户范围换了 mid 时 `synchronize()` 先丢弃旧状态。
    @ObservationIgnored private var stateAccountID: Int64?
    /// 读取的最新意图 Task：新请求替换旧请求，迟到结果经 `isCurrent` 丢弃；`reset` 取消。
    @ObservationIgnored private let loadTask = LatestTask()

    /// 由各组的构造入口调用（收藏夹、关注分组）。
    ///
    /// `accountScope` 是窗口此刻可用于读取的账户范围，每次开始读取时求值，mid 取自其中；App 在认证仍在确认或其他窗口
    /// 换号、本窗口复核未完时给出 `unresolved`。`read` 读取这个 mid 的值，失败抛出 `ContentApplicationError`。
    init(
        accountScope: @escaping @MainActor () -> AccountSessionScope,
        read: @escaping @Sendable (_ accountID: Int64) async throws -> Value
    ) {
        self.read = read
        self.accountScope = accountScope
    }

    /// 按窗口此刻的账户范围对齐列表：已登录且 mid 已知时，列表不属于这个 mid 就丢弃，空闲时加载；mid 未知时显示说明；
    /// 未登录时丢弃；范围无法确认（`unresolved`）时不动作。
    ///
    /// 导航侧栏出现与账户范围变化时调用（`.task(id:)`），复核结束后也经它恢复；已加载或加载中时不重复请求。
    public func synchronize() {
        switch accountScope() {
        case .signedIn(let accountID?):
            if stateAccountID != accountID {
                reset()
            }
            guard state == .idle else { return }
            load(accountID: accountID)
        case .signedIn(nil):
            reset()
            state = .accountUnidentified
        case .signedOut:
            reset()
        case .unresolved:
            // 账户范围此刻无法确认（仍在确认登录，或其他窗口换号、本窗口复核未完）：既不读取也不丢弃，复核结束后由
            // 复核结果或账户变化重新对齐。
            break
        }
    }

    /// 侧栏的重试，以及页面发现选中的行已不存在时重新读取；mid 未知或未登录时不动作。
    public func reload() {
        guard case .signedIn(let accountID?) = accountScope() else { return }
        load(accountID: accountID)
    }

    /// 写入成功后由各组的入口调用（App 的写入效果路由经它们转来）：已加载时按 `transform` 在本地改条数，并开始或延长宽限期。
    ///
    /// `transform` 返回 nil 表示这次写入改了哪些行不知道（如三连收藏），只等宽限期后补读。还没有已加载的值时也开始宽限期：
    /// 首次读取可能在写入前已经发出，落地的是写前的条数，而首次读取不在宽限期里丢弃，靠宽限期后的补读纠正。调用方先核对
    /// 写入属于本窗口的账户。
    func adjustAfterWrite(_ transform: (Value) -> Value?) {
        if case .loaded(let value) = state, let adjusted = transform(value) {
            state = .loaded(adjusted)
        }
        let graceEnd = ContinuousClock.now.advanced(by: Self.countReadLagGrace)
        countGraceEnd = graceEnd
        graceReread?.cancel()
        graceReread = Task { [weak self] in
            try? await Task.sleep(until: graceEnd, clock: .continuous)
            guard let self, !Task.isCancelled else { return }
            graceReread = nil
            countGraceEnd = nil
            guard case .loaded = state else { return }
            reload()
        }
    }

    /// 取消请求并从内存删除读到的值，供登出、换号与关窗调用；复核代次保留。
    public func reset() {
        loadTask.cancel()
        graceReread?.cancel()
        graceReread = nil
        countGraceEnd = nil
        isRefreshing = false
        stateAccountID = nil
        revalidation.reset()
        state = .idle
    }

    /// 窗口的账户范围发生了已解析的变化：丢弃上一账户的值，再按新范围对齐（已登录就重新读取，不论当前来源）。
    public func synchronizeAuthenticationSession() {
        reset()
        synchronize()
    }

    /// 账户复核确认仍已登录：本组请求的复核在本会话内自动重载一次，其余情况只按账户范围对齐。
    public func authenticationRevalidationSucceeded() {
        if revalidation.concluded() {
            reload()
        } else {
            synchronize()
        }
    }

    /// 账户复核没能确认登录状态：本组请求的复核或还没有值时给出可重试的“无法读取登录状态”；未登录时不动作。
    public func authenticationRevalidationFailed() {
        let requestedRevalidation = revalidation.failed()
        guard case .signedIn(_?) = accountScope() else { return }
        switch state {
        case .idle:
            state = .failed(.authenticationUnavailable)
        case .failed where requestedRevalidation:
            state = .failed(.authenticationUnavailable)
        case .loading, .loaded, .failed, .accountUnidentified:
            break
        }
    }

    /// 读取这个账户的值：同一账户已有值时在后台重读、保留原有的行，否则转为加载中。
    private func load(accountID: Int64) {
        let read = read
        let refreshesInPlace: Bool
        if case .loaded = state, stateAccountID == accountID {
            refreshesInPlace = true
        } else {
            refreshesInPlace = false
            state = .loading
        }
        stateAccountID = accountID
        isRefreshing = refreshesInPlace
        loadTask.replace { [weak self] isCurrent in
            do {
                let value = try await read(accountID)
                guard let self, isCurrent() else { return }
                isRefreshing = false
                revalidation.loadSucceeded()
                // 宽限期内的后台重读可能是写前的旧条数，会盖掉本地改过的值；宽限期结束时另有补读。
                if refreshesInPlace, let countGraceEnd, ContinuousClock.now < countGraceEnd {
                    return
                }
                state = .loaded(value)
                onLoaded?(value)
            } catch is CancellationError {
                // 本任务未被取消却收到取消：认证会话在请求途中切换。后台重读保留原有的行，其余回到空闲，由账户范围变化
                // 或复核结果重新对齐。
                guard let self, isCurrent() else { return }
                isRefreshing = false
                if !refreshesInPlace { state = .idle }
            } catch {
                guard let self, isCurrent() else { return }
                isRefreshing = false
                let failure = error as? ContentApplicationError ?? .unavailable
                let isCredentialFailure = LibraryAccountRevalidation.isCredentialFailure(failure)
                if refreshesInPlace, !isCredentialFailure { return }
                if isCredentialFailure {
                    revalidation.request()
                }
                state = .failed(failure)
            }
        }
    }
}
