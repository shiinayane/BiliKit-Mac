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

/// 拥有一份 UP 主空间的 UP 主、排序、已提交的搜索词与搜索框草稿、已加载的投稿、名片与最新请求 Task。
///
/// 每个窗口两份：侧栏上的空间预览（`open(owner:)`）与右侧的整页空间页（`open(owner:order:searchKeyword:)`），互不共享
/// 内容。整页总取名片（头部要签名与粉丝数）；预览只在凭 MID 打开、名字未知时取，用来补名字与头像。
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
    /// 名片（签名、粉丝与投稿数），整页空间页的头部用；换 UP 主或关闭时清空，读取失败时保持 nil。
    public private(set) var profile: UploaderProfile?
    /// 空间内搜索框里还没提交的文字；换 UP 主或关闭时清空，整页按给定搜索词打开时取那个词。
    public var searchDraft = ""
    /// 窗口此刻的账户是否关注了这位 UP 主（整页空间页的关注按钮）；未知时为 nil。
    ///
    /// 未知：名片还没到、读取没带凭据，或读取发出后窗口账户变了。换 UP 主或关闭时清空。乐观改动与回滚经
    /// `applyFollow`／`restoreFollow`，由写入协调者调用。
    public private(set) var viewerFollows: Bool?

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
    @ObservationIgnored private let accountID: @MainActor () -> Int64?
    /// 关注状态的代次，隔离迟到的回滚与名片读取。
    ///
    /// 换 UP 主、关闭、名片落地与写入成功（`followDidChange`）时递增。写入失败的回滚只在代次未变时放回；名片读取发出时
    /// 记下代次，落地时代次已变（读取在途时写入成功了）就不采用名片里的关注状态：它可能早于那次写入。
    @ObservationIgnored private var followGeneration: UInt64 = 0

    /// `accountID` 给出窗口此刻可写入的账户 mid（与写入门槛同一规则）；名片读取发出与落地时各求值一次，不一致时关注
    /// 状态按未知。
    public init(
        useCase: UploaderVideoUseCase,
        profileUseCase: UploaderProfileUseCase,
        accountID: @escaping @MainActor () -> Int64?
    ) {
        self.useCase = useCase
        self.profileUseCase = profileUseCase
        self.accountID = accountID
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
        searchDraft = ""
        totalCount = nil
        profile = nil
        clearViewerFollows()
        reload()
    }

    /// 整页空间页打开或回到历史里的某一项：按给定的排序与搜索词从第一批重新读取，并取名片。
    ///
    /// 与 `open(owner:)` 不同，同一 UP 主也从第一批重来：回到更早的空间项时要按那一项记下的条件重建，不能沿用刚才
    /// 另一项留下的内容。同一 UP 主已有名片时不重取。搜索词按 `submitSearch` 的规则规范化，规范化后为空等于不搜索。
    public func open(owner: VideoOwner, order: UploaderVideoOrder, searchKeyword: String?) {
        let changesOwner = self.owner?.id != owner.id
        if changesOwner {
            profileTask.cancel()
            profile = nil
            clearViewerFollows()
        }
        // 同一 UP 主时入口给的可能只有 MID（名字为空、没有头像）：保留已补全的名字与头像，名片不会再取。
        let current = changesOwner ? nil : self.owner
        self.owner = VideoOwner(
            id: owner.id,
            name: owner.name.isEmpty ? current?.name ?? "" : owner.name,
            avatarURL: owner.avatarURL ?? current?.avatarURL
        )
        self.order = order
        let keyword = searchKeyword.map(SearchText.normalized) ?? ""
        self.searchKeyword = keyword.isEmpty ? nil : keyword
        searchDraft = keyword
        totalCount = nil
        reload()
        if profile == nil {
            loadProfile(ownerID: owner.id)
        }
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
        let account = accountID()
        let generation = followGeneration
        profileTask.replace { [weak self] isCurrent in
            let card: UploaderCard?
            var failure: ContentApplicationError?
            do {
                card = try await profileUseCase.card(for: ownerID)
            } catch {
                card = nil
                failure = error as? ContentApplicationError
            }
            guard let self, isCurrent() else { return }
            // 名片只是增强，失败时名字保持为空；凭据失效仍要复核。
            if let failure, failure.requiresAccountRevalidation {
                revalidation.request()
            }
            guard let card, let owner = self.owner, owner.id == ownerID else { return }
            let profile = card.profile
            self.profile = profile
            // 关注状态属于发出读取时的账户：落地时窗口账户已不是它，按未知。
            if followGeneration == generation {
                followGeneration &+= 1
                viewerFollows = account != nil && account == accountID() ? card.viewerFollows : nil
            }
            self.owner = VideoOwner(
                id: ownerID,
                name: profile.name ?? owner.name,
                avatarURL: profile.avatarURL ?? owner.avatarURL
            )
        }
    }

    /// 整页空间页头部关注按钮的状态：看自己的空间时为 nil（不显示）；`isWritable` 是窗口此刻能否写入（未登录、复核中时
    /// 不能），关注状态未知时禁用。
    public func followButton(isWritable: Bool) -> VideoUploaderFollowContent? {
        guard let owner, owner.id != accountID() else { return nil }
        return VideoUploaderFollowContent(
            isFollowing: viewerFollows ?? false,
            isEnabled: isWritable && viewerFollows != nil
        )
    }

    /// 写入失败时放回的关注状态。
    public struct FollowSnapshot: Sendable, Equatable {
        let ownerID: Int64
        let viewerFollows: Bool
        let generation: UInt64
    }

    /// 乐观关注或取消关注正在显示的 UP 主，返回写入失败时用来放回的快照；关注状态未知、已是目标状态或不是这位 UP 主
    /// 时为 nil。
    public func applyFollow(_ isFollowing: Bool, ownerID: Int64) -> FollowSnapshot? {
        guard owner?.id == ownerID, let current = viewerFollows, current != isFollowing else {
            return nil
        }
        let snapshot = FollowSnapshot(
            ownerID: ownerID,
            viewerFollows: current,
            generation: followGeneration
        )
        viewerFollows = isFollowing
        return snapshot
    }

    /// 写入失败的回滚；此间换了 UP 主、关闭、名片重读落地或别处的写入成功过时不放回：那之后的状态不是这次乐观改动之上
    /// 的状态。
    public func restoreFollow(_ snapshot: FollowSnapshot) {
        guard owner?.id == snapshot.ownerID, followGeneration == snapshot.generation else { return }
        viewerFollows = snapshot.viewerFollows
    }

    /// 关注或取消关注成功（本窗口或其他窗口）：正在显示这位 UP 主时直接取服务端确认的状态。
    public func followDidChange(ownerID: Int64, isFollowing: Bool) {
        guard owner?.id == ownerID else { return }
        followGeneration &+= 1
        viewerFollows = isFollowing
    }

    private func clearViewerFollows() {
        followGeneration &+= 1
        viewerFollows = nil
    }

    /// 协调器每次换视频都会调用；已经关闭时不再写入，避免无谓地通知观察者。
    public func close() {
        guard owner != nil || phase != .closed else { return }
        loadTask.cancel()
        profileTask.cancel()
        owner = nil
        order = .newest
        searchKeyword = nil
        searchDraft = ""
        totalCount = nil
        profile = nil
        clearViewerFollows()
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
