import BiliApplication
import BiliModels
import Foundation
import Observation

/// 一个来源工作集的加载状态；`loaded` 里的 `FeedListing` 另带分页与原地刷新进度，`failed`
/// 只在没有可显示内容时出现。
enum FeedState: Sendable, Equatable {
    case idle
    case loading(FeedRequest)
    case loaded(FeedListing)
    case failed(request: FeedRequest, error: ContentApplicationError)
}

/// 视图读取的单个请求的工作集投影：状态、是否正在原地刷新与最近一次刷新失败；
/// 该请求不是其来源当前工作集时为 idle。
struct FeedPresentation: Sendable, Equatable {
    let state: FeedState
    let isRefreshing: Bool
    let refreshError: ContentApplicationError?
}

/// 首页推荐、热门与搜索三个来源；各自拥有独立工作集，互不共享可被污染的状态。
public enum FeedSource: Sendable, Hashable, CaseIterable {
    case recommendation
    case popular
    case search
}

extension FeedRequest {
    var source: FeedSource {
        switch self {
        case .recommendation: .recommendation
        case .popular: .popular
        case .search: .search
        }
    }
}

/// 推荐、热门与搜索共用的分页 footer 投影。
///
/// `tailIdentity` 是 `PagedVideoList` 的尾标计数，只在仍可自动加载时给出；失败、原地刷新与到底时为 nil。
struct FeedPaginationPresentation: Sendable, Equatable {
    static let unavailable = FeedPaginationPresentation(
        tailIdentity: nil,
        isLoadingMore: false,
        loadMoreError: nil
    )

    let tailIdentity: UInt64?
    let isLoadingMore: Bool
    let loadMoreError: ContentApplicationError?

    var canLoadMore: Bool { tailIdentity != nil }
}

/// 拥有首页推荐、热门与最后一次搜索三份独立工作集，以及当前路由的请求 Task。
///
/// 工作集是唯一的状态来源，路由级的 `state` 等只是当前路由工作集的投影。`LatestTask` 与
/// `activeRequestIdentity` 共同阻止已取消或已切路由的结果写回；进入播放页时普通 deactivate 会保留三份
/// 工作集，`reset` 则清空它们；不同请求会替换对应工作集。分页规则由各工作集的 `FeedListing` 承担。
/// 首页推荐工作集另记着标为「不感兴趣」的条目；标记与撤销由 App 的写入协调者乐观地改，写请求不归这里。
@MainActor
@Observable
public final class BrowseViewModel: AccountRevalidationParticipant {
    /// 首次加载、刷新或加载更多遇到需要复核账户的失败（`requiresAccountRevalidation`）时递增，
    /// 由窗口汇总后复核账户（`AccountRevalidationParticipant`）。
    public var authenticationRevalidationGeneration: Int {
        revalidation.generation
    }
    /// 本模型请求的复核进度；复核有了确定结果（仍登录或确认未登录）时，停在凭据失败页的当前来源自动重载至多一次。
    private var revalidation = AccountRevalidationProgress()
    /// 本页因凭据失败请求的复核还没结束；失败页据此决定是否说“正在重新确认”。
    public var isAwaitingAuthenticationRevalidation: Bool {
        revalidation.isAwaiting
    }
    /// 各来源原地刷新成功的次数，经 `successfulRefreshGeneration(for:)` 读出。
    private var successfulRefreshGenerations: [FeedSource: UInt64] = [:]
    /// 当前路由的第一页请求，nil 表示没有激活的路由；Task 写回前与发起时的请求比对，
    /// 不等就丢弃结果。
    private(set) var activeRequestIdentity: FeedRequest?

    @ObservationIgnored private let useCase: FeedUseCase
    /// 首次加载、刷新与加载更多共用的最新意图 Task：新请求替换旧请求；切换路由、`deactivateRoute`、
    /// `reset` 与账户会话变化时取消。
    @ObservationIgnored private let loadTask = LatestTask()
    /// 上次同步的账户会话代次：App 在账户范围变化时调用 `synchronizeAuthenticationSession`，
    /// 代次相同的重复调用直接返回，不丢弃工作集。
    @ObservationIgnored private var authenticationSessionGeneration: UInt64?
    /// 按来源保存的工作集，每个来源最多一份；同来源的新请求替换旧工作集。
    private var worksets: [FeedSource: FeedWorkset] = [:]
    /// 下一份新工作集的身份：每新建一份工作集（新请求、失败页、账户变化或 `reset` 后重建）递增，原地刷新不变。
    ///
    /// `revertRecommendationDislike` 拿它与凭据比对，不相等就丢弃回滚。
    @ObservationIgnored private var nextWorksetIdentity: UInt64 = 0

    public init(useCase: FeedUseCase) {
        self.useCase = useCase
    }

    /// 首页推荐里标为「不感兴趣」的条目，键为 BVID，值是发出的那份反馈（撤销时原样交回）。
    ///
    /// 属于推荐工作集，跟着卡片走：刷新成功后只留下新推荐里仍有的条目（服务端记着的反馈不因刷新消失，同一视频再出现时
    /// 仍是标过的样子），加载更多不动它；工作集被替换（账户变化、`reset`）时随之清空。
    var dislikedRecommendations: [String: RecommendationFeedback] {
        worksets[.recommendation]?.dislikedRecommendations ?? [:]
    }

    /// 把首页推荐里的一条标为「不感兴趣」；标上时返回回滚凭据，否则为 nil。
    ///
    /// 只标此刻推荐工作集里有、且还没标过的条目；写入协调者在发请求前调用（乐观改动），失败或被取消时把凭据交回
    /// `revertRecommendationDislike`。
    public func markRecommendationDisliked(
        _ feedback: RecommendationFeedback
    ) -> RecommendationDislikeEdit? {
        guard var workset = worksets[.recommendation], workset.canMark(feedback) else {
            return nil
        }
        workset.dislikedRecommendations[feedback.target.bvid] = feedback
        worksets[.recommendation] = workset
        return RecommendationDislikeEdit(
            feedback: feedback,
            marked: true,
            worksetIdentity: workset.identity
        )
    }

    /// 去掉一条「不感兴趣」标记；去掉时返回回滚凭据，否则为 nil。
    ///
    /// 只去掉同一份反馈：撤销必须带发出时的同一份字段，卡片已经不是标着它时（刷新后不在了、或换成了别的反馈）不撤销。
    public func unmarkRecommendationDisliked(
        _ feedback: RecommendationFeedback
    ) -> RecommendationDislikeEdit? {
        let bvid = feedback.target.bvid
        guard var workset = worksets[.recommendation],
            workset.dislikedRecommendations[bvid] == feedback
        else { return nil }
        workset.dislikedRecommendations[bvid] = nil
        worksets[.recommendation] = workset
        return RecommendationDislikeEdit(
            feedback: feedback,
            marked: false,
            worksetIdentity: workset.identity
        )
    }

    /// 写入失败或被取消的回滚：标上的去掉、去掉的标回。
    ///
    /// 只作用在改动时的同一份推荐工作集上：换了账户或 `reset` 后的新工作集可能恰好有同一视频，把上一账户的反馈标上去，
    /// 之后的撤销就会用新账户撤回旧账户的反馈。同一份工作集里也只撤回自己那一步：去掉标记只去掉同一份反馈，标回
    /// 只标此刻仍显示、且没有别的标记的卡片。
    public func revertRecommendationDislike(_ edit: RecommendationDislikeEdit) {
        let feedback = edit.feedback
        let bvid = feedback.target.bvid
        guard var workset = worksets[.recommendation],
            workset.identity == edit.worksetIdentity
        else { return }
        if edit.marked {
            guard workset.dislikedRecommendations[bvid] == feedback else { return }
            workset.dislikedRecommendations[bvid] = nil
        } else {
            guard workset.canMark(feedback) else { return }
            workset.dislikedRecommendations[bvid] = feedback
        }
        worksets[.recommendation] = workset
    }

    /// 当前路由的状态；路由停用后为 idle，工作集仍保留供返回时恢复。
    var state: FeedState {
        activeWorkset?.state ?? .idle
    }

    var isRefreshing: Bool {
        activeWorkset?.isRefreshing ?? false
    }

    var refreshError: ContentApplicationError? {
        activeWorkset?.refreshError
    }

    func activateRecommendation() {
        activateWorkset(.recommendation(continuation: nil))
    }

    /// 热门来源的分页大小；激活（`activate(_:)`）与 `PopularFeedView` 按同一请求匹配 presentation。
    ///
    /// 取 `FeedUseCase.maximumPopularPageSize`：每页条目最多、近尾翻页次数最少；超过它会被当作无效请求。
    public static let popularPageSize = FeedUseCase.maximumPopularPageSize

    func activatePopular(page: Int = 1, pageSize: Int) {
        activateWorkset(.popular(page: page, pageSize: pageSize))
    }

    func activateSearch(_ criteria: VideoSearchCriteria) {
        let request = FeedRequest.search(
            VideoSearchRequest(criteria: criteria, page: 1)
        )
        guard criteria.isValid else {
            fail(request: request, error: .invalidRequest)
            return
        }
        activateWorkset(request)
    }

    func refreshPopular(page: Int = 1, pageSize: Int) {
        refresh(.popular(page: page, pageSize: pageSize))
    }

    func refreshRecommendation() {
        refresh(.recommendation(continuation: nil))
    }

    /// 该来源刷新成功的次数；App 只在它前进时把对应网格滚回顶部。
    public func successfulRefreshGeneration(for source: FeedSource) -> UInt64 {
        successfulRefreshGenerations[source, default: 0]
    }

    /// 为当前路由的来源加载下一页；近尾自动加载与失败后的重试共用，没有其他请求时才发出。
    public func loadMore(_ source: FeedSource) {
        guard
            let baseRequest = activeRequestIdentity,
            baseRequest.source == source,
            !loadTask.isRunning,
            var workset = activeWorkset,
            case .loaded(var listing) = workset.state,
            let nextRequest = listing.beginLoadMore()
        else {
            return
        }
        workset.state = .loaded(listing)
        worksets[source] = workset
        loadTask.replace { [weak self] isCurrent in
            await self?.performAppend(
                nextRequest,
                baseRequest: baseRequest,
                isCurrent: isCurrent
            )
        }
    }

    func search(_ criteria: VideoSearchCriteria) {
        let request = FeedRequest.search(
            VideoSearchRequest(criteria: criteria, page: 1)
        )
        guard criteria.isValid else {
            fail(request: request, error: .invalidRequest)
            return
        }
        refresh(request)
    }

    /// 丢弃上一账户范围的推荐、热门与搜索工作集；当前路由会以同一请求重新开始。
    public func synchronizeAuthenticationSession(generation newGeneration: UInt64) {
        guard authenticationSessionGeneration != newGeneration else { return }
        authenticationSessionGeneration = newGeneration
        // 账户范围变化本身会重启当前来源，复核结果不再触发第二次重载。
        revalidation.reset()

        let activeRequest = activeRequestIdentity
        loadTask.cancel()
        activeRequestIdentity = nil
        worksets = [:]
        switch activeRequest {
        case .recommendation:
            activateRecommendation()
        case .popular(let page, let pageSize):
            activatePopular(page: page, pageSize: pageSize)
        case .search(let request):
            activateSearch(request.criteria)
        case nil:
            break
        }
    }

    func retry(_ request: FeedRequest) {
        guard
            case .failed(let failedRequest, _) =
                presentation(for: request).state,
            failedRequest == request
        else {
            return
        }
        refresh(request)
    }

    /// 停止当前路由工作，把工作集规范化（结束刷新与加载更多）后保留，供返回时恢复。
    func deactivateRoute() {
        revalidation.stopAwaiting()
        loadTask.cancel()
        normalizeInterruptedLoad()
        activeRequestIdentity = nil
    }

    /// 取消请求并丢弃三份内存工作集，适用于窗口关闭而非普通页面 push/pop。
    public func reset() {
        deactivateRoute()
        worksets = [:]
        revalidation.reset()
    }

    /// 复核确认仍已登录：凭据失败可能只是一时的，重载停住的失败页一次。
    public func authenticationRevalidationSucceeded() {
        reloadCredentialFailedPageAfterRevalidation()
    }

    /// 复核确认未登录：推荐、热门与搜索都能匿名读取，重载停住的失败页一次。
    ///
    /// 启动时本页的读取先于启动复核删掉了损坏或过期的凭据，复核随后看不到凭据、账户范围不变，
    /// `synchronizeAuthenticationSession` 不会重启本页；不在这里重载，失败页会一直停在“正在重新确认”。
    public func authenticationRevalidationConfirmedSignedOut() {
        reloadCredentialFailedPageAfterRevalidation()
    }

    public func authenticationRevalidationFailed() {
        _ = revalidation.failed()
    }

    func presentation(
        for request: FeedRequest
    ) -> FeedPresentation {
        let workset = workset(for: request)
        return FeedPresentation(
            state: workset?.state ?? .idle,
            isRefreshing: workset?.isRefreshing ?? false,
            refreshError: workset?.refreshError
        )
    }

    /// 分页 footer 投影；`request` 是该来源工作集的第一页请求。
    ///
    /// 原地刷新期间没有尾标：网格对同一尾标只触发一次，刷新中被忽略的近尾事件、或刷新取消的加载更多，
    /// 都要等尾标重新出现（刷新失败恢复原尾标、成功给出新尾标）才会再次布防。
    func pagination(for request: FeedRequest) -> FeedPaginationPresentation {
        guard case .loaded(let listing) = workset(for: request)?.state else {
            return .unavailable
        }
        return listing.pagination
    }

    public func waitForCurrentTask() async {
        await loadTask.wait()
    }

    /// 相同请求沿用已保存的工作集，否则以新请求替换同类工作集后再切换路由。
    private func activateWorkset(_ request: FeedRequest) {
        switchRoute(to: request)
        if case .idle = state {
            refresh(request)
        }
    }

    /// 让 `request` 成为当前路由；同类工作集属于其他请求时以新的空工作集替换。
    private func switchRoute(to request: FeedRequest) {
        if activeRequestIdentity != request {
            deactivateRoute()
            activeRequestIdentity = request
        }
        if workset(for: request) == nil {
            worksets[request.source] = makeWorkset(request: request)
        }
    }

    private func refresh(_ request: FeedRequest) {
        switchRoute(to: request)
        updateActiveWorkset { workset in
            workset.refreshError = nil
            if case .loaded(var listing) = workset.state {
                listing.beginRefresh()
                workset.state = .loaded(listing)
            } else {
                workset.state = .loading(request)
            }
        }
        loadTask.replace { [weak self] isCurrent in
            await self?.performLoad(request, isCurrent: isCurrent)
        }
    }

    private func fail(
        request: FeedRequest,
        error: ContentApplicationError
    ) {
        deactivateRoute()
        activeRequestIdentity = request
        worksets[request.source] = makeWorkset(
            request: request,
            state: .failed(request: request, error: error)
        )
    }

    private func makeWorkset(request: FeedRequest, state: FeedState = .idle) -> FeedWorkset {
        nextWorksetIdentity &+= 1
        return FeedWorkset(identity: nextWorksetIdentity, request: request, state: state)
    }

    private func performLoad(
        _ request: FeedRequest,
        isCurrent: LatestTask.IsCurrent
    ) async {
        do {
            let content = try await useCase.execute(request)
            try Task.checkCancellation()
            guard isCurrent(), activeRequestIdentity == request else { return }
            let previous = activeWorkset?.listing
            guard
                let listing = FeedListing(
                    firstPage: content,
                    for: request,
                    replacing: previous
                )
            else {
                throw ContentApplicationError.invalidResponse
            }
            updateActiveWorkset { workset in
                workset.state = .loaded(listing)
                workset.refreshError = nil
                let loaded = workset
                workset.dislikedRecommendations = loaded.dislikedRecommendations.filter {
                    loaded.showsRecommendation(bvid: $0.key)
                }
            }
            revalidation.loadSucceeded()
            if previous?.isRefreshing == true {
                successfulRefreshGenerations[request.source, default: 0] &+= 1
            }
        } catch is CancellationError {
            guard isCurrent(), activeRequestIdentity == request else { return }
            normalizeInterruptedLoad()
        } catch {
            guard isCurrent(), activeRequestIdentity == request else { return }
            handleFailure(error as? ContentApplicationError ?? .unavailable, request: request)
        }
    }

    /// 下一页只在仍属于当前路由时并入；与已加载页不衔接的响应由 `FeedListing` 记为加载更多失败。
    private func performAppend(
        _ request: FeedRequest,
        baseRequest: FeedRequest,
        isCurrent: LatestTask.IsCurrent
    ) async {
        do {
            let content = try await useCase.execute(request)
            try Task.checkCancellation()
            guard isCurrent(), activeRequestIdentity == baseRequest else { return }
            updateActiveListing { $0.append(content, for: request) }
        } catch is CancellationError {
            guard isCurrent(), activeRequestIdentity == baseRequest else { return }
            updateActiveListing { $0.cancelPendingWork() }
        } catch {
            guard isCurrent(), activeRequestIdentity == baseRequest else { return }
            let error = error as? ContentApplicationError ?? .unavailable
            updateActiveListing { $0.failLoadMore(error) }
            recordAuthenticationInvalidationIfNeeded(error)
        }
    }

    /// 已有内容时刷新失败保留内容、恢复刷新前的分页并给出刷新错误；否则进入失败页。
    private func handleFailure(
        _ error: ContentApplicationError,
        request: FeedRequest
    ) {
        recordAuthenticationInvalidationIfNeeded(error)
        updateActiveWorkset { workset in
            if case .loaded(var listing) = workset.state {
                listing.cancelPendingWork()
                workset.state = .loaded(listing)
                workset.refreshError = error
            } else {
                workset.state = .failed(request: request, error: error)
            }
        }
    }

    private func normalizeInterruptedLoad() {
        updateActiveWorkset { workset in
            workset.refreshError = nil
            switch workset.state {
            case .loading:
                workset.state = .idle
            case .loaded(var listing):
                listing.cancelPendingWork()
                workset.state = .loaded(listing)
            case .idle, .failed:
                break
            }
        }
    }

    private func recordAuthenticationInvalidationIfNeeded(
        _ error: ContentApplicationError
    ) {
        guard error.requiresAccountRevalidation else { return }
        revalidation.request()
    }

    /// 只重载当前来源停在凭据失败页的第一页；保留着卡片的刷新或加载更多失败由用户自己重试。
    private func reloadCredentialFailedPageAfterRevalidation() {
        guard case .failed(let request, let error) = activeWorkset?.state,
            error.requiresAccountRevalidation
        else {
            revalidation.stopAwaiting()
            return
        }
        if revalidation.concluded() {
            refresh(request)
        }
    }

    private var activeWorkset: FeedWorkset? {
        activeRequestIdentity.flatMap(workset(for:))
    }

    private func updateActiveWorkset(_ update: (inout FeedWorkset) -> Void) {
        guard let request = activeRequestIdentity, var workset = workset(for: request) else {
            return
        }
        update(&workset)
        worksets[request.source] = workset
    }

    private func updateActiveListing(_ update: (inout FeedListing) -> Void) {
        updateActiveWorkset { workset in
            guard case .loaded(var listing) = workset.state else { return }
            update(&listing)
            workset.state = .loaded(listing)
        }
    }

    private func workset(for request: FeedRequest) -> FeedWorkset? {
        guard let workset = worksets[request.source], workset.request == request else {
            return nil
        }
        return workset
    }
}

/// 一个来源的第一页请求及其状态；加载更多与刷新进行状态在已加载的 `FeedListing` 里。
private struct FeedWorkset {
    /// 见 `BrowseViewModel.nextWorksetIdentity`。
    let identity: UInt64
    let request: FeedRequest
    var state: FeedState = .idle
    var refreshError: ContentApplicationError?
    /// 只有首页推荐工作集会有，见 `BrowseViewModel.dislikedRecommendations`。
    var dislikedRecommendations: [String: RecommendationFeedback] = [:]

    /// 推荐工作集此刻显示着这条视频。
    func showsRecommendation(bvid: String) -> Bool {
        guard case .loaded(.recommendation(let list)) = state else { return false }
        return list.items.contains { $0.bvid == bvid }
    }

    /// 这份反馈的视频此刻显示着、且还没有标记。
    func canMark(_ feedback: RecommendationFeedback) -> Bool {
        showsRecommendation(bvid: feedback.target.bvid)
            && dislikedRecommendations[feedback.target.bvid] == nil
    }

    var listing: FeedListing? {
        guard case .loaded(let listing) = state else { return nil }
        return listing
    }

    var isRefreshing: Bool {
        listing?.isRefreshing ?? false
    }
}

/// 一次乐观标记或去掉「不感兴趣」的回滚凭据：哪份反馈、是标上还是去掉，以及改动时推荐工作集的身份；交回
/// `BrowseViewModel.revertRecommendationDislike`。
public struct RecommendationDislikeEdit: Sendable {
    fileprivate let feedback: RecommendationFeedback
    fileprivate let marked: Bool
    fileprivate let worksetIdentity: UInt64
}
