import BiliApplication
import BiliModels
import Foundation
import Observation

/// 空间层第一批的加载状态；`closed` 表示上下文层未打开。
public enum UploaderSpaceState: Sendable, Equatable {
    case closed
    case loading
    case loaded([UploaderVideo])
    case failed(ContentApplicationError)
}

/// 已加载列表底部的状态。
public enum UploaderSpaceFooter: Sendable, Equatable {
    /// 已到底，或列表不在已加载状态。
    case none
    /// 还有下一批，近尾时自动加载。
    case loadMore
    case loading
    /// 加载下一批失败；不再自动加载，由用户重试同一游标。
    case failed(ContentApplicationError)
}

/// 拥有侧栏 UP 主空间层的 UP 主、排序、已提交的搜索词、已加载的投稿与最新请求 Task。
///
/// 投稿按游标累积（`PagedVideoList`，按 BVID 去重，无进展即停止），滚动到底时由列表调用 `loadMore` 取下一批；同一
/// UP 主再次打开保持已加载的内容，换 UP 主或排序从第一批重来。有搜索词时列表换成空间内搜索结果（顺序由服务端决定，
/// 排序不生效），清空搜索从投稿第一批重新读取；换 UP 主或关闭时清掉搜索词。未登录也能读取（App 端匿名签名），所以
/// 没有登录提示。
///
/// 第一批与下一批共用一个 `LatestTask`：新意图替换旧请求，迟到结果经 `isCurrent` 丢弃；`close` 取消。请求途中收到
/// 并非自己被取消的取消，说明认证会话已切换，空间属于上一个身份，直接关闭。凭据失效时请求一次账户复核，复核有了确定
/// 结果后停在失败页的第一批自动重载至多一次（`AccountRevalidationProgress`）。
@MainActor
@Observable
public final class UploaderSpaceViewModel: AccountRevalidationParticipant {
    public private(set) var owner: VideoOwner?
    public private(set) var order: UploaderVideoOrder = .newest
    /// 已提交的空间内搜索词（已规范化）；nil 表示在看投稿列表。
    public private(set) var searchKeyword: String?
    /// 服务端给出的投稿总数；第一批成功前、换 UP 主或关闭后为 nil。
    public private(set) var totalCount: Int?

    public var authenticationRevalidationGeneration: Int {
        revalidation.generation
    }

    /// 第一批的加载阶段；已加载的投稿与翻页状态在 `list`。
    private enum Phase: Equatable {
        case closed
        case loading
        case loaded
        case failed(ContentApplicationError)
    }

    private var phase: Phase = .closed
    /// 只在 `phase == .loaded` 时显示；开始新的第一批（换 UP 主、排序、重载）与关闭时换成空列表。
    private var list = PagedVideoList<UploaderVideo, UploaderVideoCursor>(stallPolicy: .stop)
    private var revalidation = AccountRevalidationProgress()

    public var state: UploaderSpaceState {
        switch phase {
        case .closed: .closed
        case .loading: .loading
        case .loaded: .loaded(list.items)
        case .failed(let error): .failed(error)
        }
    }

    public var footer: UploaderSpaceFooter {
        guard phase == .loaded else { return .none }
        if list.isLoadingMore { return .loading }
        if let error = list.loadMoreError { return .failed(error) }
        return list.nextCursor == nil ? .none : .loadMore
    }

    /// 近尾自动加载的尾标：可以自动加载下一批时为当前尾标计数，否则 nil；每并入新投稿就变化，列表据此每个尾部只请求一次。
    public var loadMoreTailIdentity: UInt64? {
        phase == .loaded ? list.tailIdentity : nil
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
            if case .failed = phase {
                reload()
            }
            return
        }
        profileTask.cancel()
        self.owner = owner
        order = .newest
        searchKeyword = nil
        totalCount = nil
        reload()
    }

    /// 只有 MID 的入口（评论正文里的空间链接）：先以空名字打开并照常加载投稿，名片到达后补上名字
    /// 与头像。
    ///
    /// 同一 UP 主已经打开时与 `open(owner:)` 一样保持已加载的内容。名片只是增强，失败时名字保持为空，
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
                revalidation.request()
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
        guard owner != nil || phase != .closed else { return }
        loadTask.cancel()
        profileTask.cancel()
        owner = nil
        order = .newest
        searchKeyword = nil
        totalCount = nil
        phase = .closed
        list = PagedVideoList(stallPolicy: .stop)
        revalidation.reset()
    }

    /// 换排序从第一批重来；搜索时排序不生效、控件也不显示，不动作。
    public func setOrder(_ order: UploaderVideoOrder) {
        guard owner != nil, searchKeyword == nil, self.order != order else { return }
        self.order = order
        reload()
    }

    /// 提交搜索框里的词：规范化后为空等于清空搜索；超过长度上限不动作；与当前搜索词相同时重新搜索。
    public func submitSearch(_ text: String) {
        guard owner != nil else { return }
        let keyword = SearchText.normalized(text)
        guard !keyword.isEmpty else {
            clearSearch()
            return
        }
        guard SearchText.isWithinLimit(keyword) else { return }
        searchKeyword = keyword
        totalCount = nil
        reload()
    }

    /// 退出搜索，从投稿第一批重新读取；没有在搜索时不动作。
    public func clearSearch() {
        guard owner != nil, searchKeyword != nil else { return }
        searchKeyword = nil
        totalCount = nil
        reload()
    }

    /// 从第一批重新读取：失败重试，或换 UP 主、排序、搜索词之后。
    public func reload() {
        guard owner != nil else { return }
        let fetch = fetcher()
        phase = .loading
        list = PagedVideoList(stallPolicy: .stop)
        loadTask.replace { [weak self] isCurrent in
            do {
                let batch = try await fetch(nil)
                guard let self, isCurrent() else { return }
                list.replaceFirstPage(Self.page(batch), bvid: \.bvid)
                totalCount = batch.totalCount
                phase = .loaded
                revalidation.loadSucceeded()
            } catch is CancellationError {
                // 本任务未被取消却收到取消：认证会话在请求途中切换，空间属于上一个身份，直接关闭。
                guard let self, isCurrent() else { return }
                close()
            } catch {
                guard let self, isCurrent() else { return }
                let failure = error as? ContentApplicationError ?? .unavailable
                if failure.requiresAccountRevalidation {
                    revalidation.request()
                }
                phase = .failed(failure)
            }
        }
    }

    /// 近尾自动加载与加载失败后的重试共用：请求列表给出的同一游标；没有下一批或正在加载时不动作。
    public func loadMore() {
        guard phase == .loaded, owner != nil, let cursor = list.beginLoadMore() else {
            return
        }
        let fetch = fetcher()
        loadTask.replace { [weak self] isCurrent in
            do {
                let batch = try await fetch(cursor)
                guard let self, isCurrent() else { return }
                list.apply(Self.page(batch), requested: cursor, bvid: \.bvid)
                totalCount = batch.totalCount
            } catch is CancellationError {
                guard let self, isCurrent() else { return }
                close()
            } catch {
                guard let self, isCurrent() else { return }
                let failure = error as? ContentApplicationError ?? .unavailable
                if failure.requiresAccountRevalidation {
                    revalidation.request()
                }
                list.failLoadMore(failure)
            }
        }
    }

    public func authenticationRevalidationSucceeded() {
        reloadFailedFirstBatchAfterRevalidation()
    }

    public func authenticationRevalidationConfirmedSignedOut() {
        reloadFailedFirstBatchAfterRevalidation()
    }

    public func authenticationRevalidationFailed() {
        _ = revalidation.failed()
    }

    /// 只重载停在凭据失败页的第一批，且每轮复核至多一次；加载下一批失败由用户自己重试。
    private func reloadFailedFirstBatchAfterRevalidation() {
        guard case .failed(let error) = phase, error.requiresAccountRevalidation else {
            revalidation.stopAwaiting()
            return
        }
        if revalidation.concluded() {
            reload()
        }
    }

    /// 按此刻的 UP 主、排序与搜索词取一批的请求；在发起时捕获，之后改动这些状态不影响已发出的请求。
    private func fetcher() -> @Sendable (UploaderVideoCursor?) async throws -> UploaderVideoBatch {
        let useCase = useCase
        let ownerID = owner?.id ?? 0
        let order = order
        if let keyword = searchKeyword {
            return { cursor in
                try await useCase.search(ownerID: ownerID, keyword: keyword, after: cursor)
            }
        }
        return { cursor in try await useCase.batch(ownerID: ownerID, order: order, after: cursor) }
    }

    private static func page(
        _ batch: UploaderVideoBatch
    ) -> VideoListPage<UploaderVideo, UploaderVideoCursor> {
        VideoListPage(items: batch.videos, nextCursor: batch.nextCursor)
    }
}
