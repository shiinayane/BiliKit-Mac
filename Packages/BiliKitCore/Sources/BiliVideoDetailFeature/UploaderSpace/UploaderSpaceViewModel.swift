import BiliApplication
import BiliModels
import Foundation
import Observation

/// 空间层当前页的加载状态；`closed` 表示上下文层未打开。
public enum UploaderSpaceState: Sendable, Equatable {
    case closed
    case loading(page: Int)
    case loaded(UploaderVideoPage)
    case failed(page: Int, error: ContentApplicationError)
}

/// 拥有播放页右栏 UP 主空间层的 UP 主、排序、页码与最新请求 Task。
///
/// 按页替换，不追加；同一 UP 主再次打开保持当前页。页码、总页数与投稿数由共用的翻页状态
/// `PageReplacementPaging` 记录：取自最近一次成功的页，翻页加载或失败期间保留，页码条不会消失。账户会话在请求途中
/// 切换时直接关闭空间，不把上一个身份的状态带给下一个身份。
@MainActor
@Observable
public final class UploaderSpaceViewModel: AccountRevalidationParticipant {
    public private(set) var owner: VideoOwner?
    public private(set) var order: UploaderVideoOrder = .newest
    /// 凭据失效（而非未登录）时递增，由 App 触发账户复核。
    public private(set) var authenticationRevalidationGeneration = 0

    /// 当前页与最近一次成功的页给出的总数；换 UP 主、排序或关闭时 `reset`。
    private var paging = PageReplacementPaging<UploaderVideoPage>()

    public var state: UploaderSpaceState {
        switch paging.phase {
        case .idle:
            .closed
        case .loading(let page):
            .loading(page: page)
        case .loaded(_, let content):
            .loaded(content)
        case .failed(let page, let error):
            .failed(page: page, error: error)
        }
    }

    public var pageCount: Int {
        paging.pageCount
    }

    public var totalCount: Int {
        paging.totalCount ?? 0
    }

    public var currentPage: Int {
        paging.currentPage
    }

    public var requiresAuthentication: Bool {
        if case .failed(_, .authenticationRequired) = state {
            return true
        }
        return false
    }

    @ObservationIgnored private let useCase: UploaderVideoUseCase
    @ObservationIgnored private let profileUseCase: UploaderProfileUseCase
    @ObservationIgnored private let loadTask = LatestTask()
    @ObservationIgnored private let profileTask = LatestTask()

    public init(useCase: UploaderVideoUseCase, profileUseCase: UploaderProfileUseCase) {
        self.useCase = useCase
        self.profileUseCase = profileUseCase
    }

    /// 同一 UP 主再次打开时只更新资料（名字、头像可能已变），失败状态顺带重试。
    public func open(owner: VideoOwner) {
        guard self.owner?.id != owner.id else {
            self.owner = owner
            if case .failed = state {
                reload()
            }
            return
        }
        profileTask.cancel()
        self.owner = owner
        order = .newest
        paging.reset()
        load(page: 1)
    }

    /// 只有 MID 的入口（评论正文里的空间链接）：先以空名字打开并照常加载投稿，名片到达后补上名字
    /// 与头像。
    ///
    /// 同一 UP 主已经打开时与 `open(owner:)` 一样保持当前页。名片只是增强，失败时名字保持为空，
    /// 再次打开同一空间时重取。
    public func open(ownerID: Int64) {
        guard ownerID > 0 else { return }
        if let owner, owner.id == ownerID {
            open(owner: owner)
            if owner.name.isEmpty { loadProfile(ownerID: ownerID) }
            return
        }
        open(owner: VideoOwner(id: ownerID, name: ""))
        loadProfile(ownerID: ownerID)
    }

    private func loadProfile(ownerID: Int64) {
        let profileUseCase = profileUseCase
        profileTask.replace { [weak self] isCurrent in
            let profile: UploaderProfile?
            var failure: ContentApplicationError?
            do {
                profile = try await profileUseCase.profile(for: ownerID)
            } catch {
                profile = nil
                failure = error as? ContentApplicationError
            }
            guard let self, isCurrent() else { return }
            // 名片只是增强，失败时名字保持为空；凭据失效仍要复核。
            if let failure, failure.requiresAccountRevalidation {
                authenticationRevalidationGeneration &+= 1
            }
            guard let profile, let owner = self.owner, owner.id == ownerID else { return }
            self.owner = VideoOwner(
                id: ownerID,
                name: profile.name ?? owner.name,
                avatarURL: profile.avatarURL ?? owner.avatarURL
            )
        }
    }

    /// 协调器每次换视频都会调用；已经关闭时不再写入，避免无谓地通知观察者。
    public func close() {
        guard owner != nil || state != .closed else { return }
        loadTask.cancel()
        profileTask.cancel()
        owner = nil
        order = .newest
        paging.reset()
    }

    /// 换排序回到第 1 页。
    public func setOrder(_ order: UploaderVideoOrder) {
        guard owner != nil, self.order != order else { return }
        self.order = order
        paging.reset()
        load(page: 1)
    }

    /// 页码超出已知范围、或请求正在显示／正在加载的页时不发请求；失败的页可以再次请求。
    public func showPage(_ page: Int) {
        guard owner != nil, paging.accepts(page) else { return }
        load(page: page)
    }

    /// 重新读取当前页：失败重试，或登录状态变化后刷新。
    public func reload() {
        guard owner != nil else { return }
        load(page: currentPage)
    }

    private func load(page: Int) {
        guard owner != nil else { return }
        paging.beginLoading(page: page)
        request(page: page)
    }

    /// 发出 `page` 的请求；状态已由 `paging` 转为加载这一页。
    private func request(page: Int) {
        guard let ownerID = owner?.id else { return }
        let order = order
        let useCase = useCase
        loadTask.replace { [weak self] isCurrent in
            let result: Result<UploaderVideoPage, ContentApplicationError>
            do {
                result = .success(
                    try await useCase.page(ownerID: ownerID, order: order, page: page)
                )
            } catch is CancellationError {
                // 本任务未被取消却收到取消：认证会话在请求途中切换，空间属于上一个身份，直接关闭。
                guard let self, isCurrent() else { return }
                close()
                return
            } catch {
                result = .failure(error as? ContentApplicationError ?? .unavailable)
            }
            guard let self, isCurrent() else { return }
            apply(result, page: page)
        }
    }

    private func apply(_ result: Result<UploaderVideoPage, ContentApplicationError>, page: Int) {
        switch result {
        case .success(let loaded):
            // 总数在翻页期间变少（投稿被删或隐藏），请求的页已超出范围：`paging` 改请求最后一页。
            let outcome = paging.succeed(
                page: page,
                content: loaded,
                totalCount: loaded.totalCount,
                pageSize: loaded.pageSize
            )
            if case .request(let target) = outcome {
                request(page: target)
            }
        case .failure(let error):
            if error.requiresAccountRevalidation {
                authenticationRevalidationGeneration &+= 1
            }
            paging.fail(page: page, error: error)
        }
    }
}
