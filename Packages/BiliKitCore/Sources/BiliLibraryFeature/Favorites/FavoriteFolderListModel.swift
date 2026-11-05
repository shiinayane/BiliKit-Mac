import BiliApplication
import BiliModels
import Foundation
import Observation

/// 侧栏「收藏夹」组的呈现状态。
public enum FavoriteFolderListState: Sendable, Equatable {
    case idle
    case loading
    /// 按接口顺序的收藏夹；至少含一个默认收藏夹（`FavoritesUseCase` 校验）。
    case loaded([FavoriteFolder])
    case failed(ContentApplicationError)
    /// 窗口已登录但不知道当前账户的 mid（`AccountSessionScope.signedIn(accountID: nil)`）：无法读取，需要复核或重新登录，
    /// 不给重试。
    case accountUnidentified
}

/// 当前账户自己创建的收藏夹列表：侧栏「收藏夹」组的行、夹内页面的标题与选中回落都读它。
///
/// 每个窗口一份，由 App 的窗口组装构造。拥有列表、加载 Task 与它自己的账户复核进度；不拥有选中的收藏夹与夹内内容
/// （`FavoriteFolderViewModel`，列表每次加载成功经 `onFoldersLoaded` 通知它回落选择）。mid 只从 App 注入的窗口账户
/// 范围读取（`accountScope`），adapter 不自己取账户。
///
/// 与其他资料库来源不同，它是窗口级复核参与者（不绑定来源）：列表是侧栏常驻的元数据，窗口已登录就读取，不论当前来源；
/// 首次加载由导航侧栏出现时的 `synchronize()` 触发（未解析到已登录不算账户变化，不会收到账户变化通知），账户范围变化时由
/// 收藏夹来源的描述 `reset` 后重新 `synchronize()`，关窗与其他窗口换号时 `reset`。夹内视频仍绑定收藏夹来源，不在本页时
/// 不读取（见 SECURITY-MODEL §3）。
@MainActor
@Observable
public final class FavoriteFolderListModel: AccountRevalidationParticipant {
    public private(set) var state: FavoriteFolderListState = .idle
    /// 已有列表时的后台重读正在进行：侧栏照常显示原有的行，直到新列表到达。
    ///
    /// 重读成功整体替换；凭据失败放弃旧列表（与资料库其他来源一致），其余失败保留旧列表。
    public private(set) var isRefreshing = false

    /// 读取发现凭据缺失、失效或可疑（自己视角下没有默认收藏夹）时递增；规则在共用的 `AccountRevalidationProgress`。
    public var authenticationRevalidationGeneration: Int {
        revalidation.generation
    }

    /// 本列表请求的账户复核尚未结束；侧栏据此把失败行显示为加载中。
    public var isAwaitingAuthenticationRevalidation: Bool {
        revalidation.isAwaiting
    }

    /// 已加载的收藏夹；其他状态为空。
    public var folders: [FavoriteFolder] {
        if case .loaded(let folders) = state { folders } else { [] }
    }

    /// 每次加载成功后调用一次，参数是新列表；由 `FavoriteFolderViewModel` 构造时设置一次，用来回落已不存在的选择。
    @ObservationIgnored var onFoldersLoaded: (@MainActor ([FavoriteFolder]) -> Void)?

    private var revalidation = AccountRevalidationProgress()
    @ObservationIgnored private let useCase: FavoritesUseCase
    @ObservationIgnored private let accountScope: @MainActor () -> AccountSessionScope
    /// 当前状态（加载中、列表或失败）属于哪个账户；开始读取时记录，`reset` 时清空。
    ///
    /// 账户范围换了 mid 时 `synchronize()` 先丢弃旧状态。
    @ObservationIgnored private var stateAccountID: Int64?
    /// 列表请求的最新意图 Task：新请求替换旧请求，迟到结果经 `isCurrent` 丢弃；`reset` 取消。
    @ObservationIgnored private let loadTask = LatestTask()

    /// `accountScope` 是窗口此刻可用于读取的账户范围，每次开始读取时求值，mid 取自其中；App 在认证仍在确认或其他窗口
    /// 换号、本窗口复核未完时给出 `unresolved`。
    public init(
        useCase: FavoritesUseCase,
        accountScope: @escaping @MainActor () -> AccountSessionScope
    ) {
        self.useCase = useCase
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

    /// 侧栏失败行的重试，以及夹内页面发现收藏夹已不存在时重新读取；mid 未知或未登录时不动作。
    public func reload() {
        guard case .signedIn(let accountID?) = accountScope() else { return }
        load(accountID: accountID)
    }

    /// 收藏写入成功后由 App 的写入效果路由调用：各夹的条数变了，已有列表时在后台重读、保留原有的行；其余状态不动作。
    public func refreshAfterWrite() {
        guard case .loaded = state else { return }
        reload()
    }

    /// 取消请求并从内存删除列表，供登出、换号与关窗调用；复核代次保留。
    public func reset() {
        loadTask.cancel()
        isRefreshing = false
        stateAccountID = nil
        revalidation.reset()
        state = .idle
    }

    /// 窗口的账户范围发生了已解析的变化：丢弃上一账户的列表，再按新范围对齐（已登录就重新读取，不论当前来源）。
    public func synchronizeAuthenticationSession() {
        reset()
        synchronize()
    }

    /// 账户复核确认仍已登录：本列表请求的复核在本会话内自动重载一次，其余情况只按账户范围对齐。
    public func authenticationRevalidationSucceeded() {
        if revalidation.concluded() {
            reload()
        } else {
            synchronize()
        }
    }

    /// 账户复核没能确认登录状态：本列表请求的复核或还没有列表时给出可重试的“无法读取登录状态”；未登录时不动作。
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

    /// 读取这个账户的列表：同一账户已有列表时在后台重读、保留原有的行，否则转为加载中。
    private func load(accountID: Int64) {
        let useCase = useCase
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
                let folders = try await useCase.folders(ownerID: accountID)
                guard let self, isCurrent() else { return }
                isRefreshing = false
                revalidation.loadSucceeded()
                state = .loaded(folders)
                onFoldersLoaded?(folders)
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
