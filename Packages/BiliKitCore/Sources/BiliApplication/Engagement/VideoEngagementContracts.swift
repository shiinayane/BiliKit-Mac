import BiliModels

/// 当前账户对一个视频做过的互动：是否点赞、投了几枚币、是否收藏（在任一收藏夹里），以及是否关注了它的 UP 主。
///
/// 由 BiliAPI 映射 `/x/web-interface/archive/relation`；播放页的点赞、投币、收藏按钮据此显示实心与否，投币面板据此算还能
/// 投几枚，侧栏 UP 主行的关注按钮据此显示「关注」或「已关注」。
public struct VideoEngagementState: Sendable, Equatable {
    public var isLiked: Bool
    /// 本人已投的硬币数（0–2）。
    public var coinCount: Int
    public var isFavorited: Bool
    /// 是否关注了这个视频的 UP 主；接口没给出时为 nil，关注按钮禁用，不影响点赞、投币与收藏。
    public var isFollowingUploader: Bool?

    public init(
        isLiked: Bool,
        coinCount: Int,
        isFavorited: Bool,
        isFollowingUploader: Bool? = nil
    ) {
        self.isLiked = isLiked
        self.coinCount = coinCount
        self.isFavorited = isFavorited
        self.isFollowingUploader = isFollowingUploader
    }
}

/// 三连的结果：服务端逐项报告点赞、投币、收藏是否成立（已经做过的也报成立），以及这次实际投了几枚币。
///
/// 收藏只进默认收藏夹。
public struct VideoTripleOutcome: Sendable, Hashable {
    public let isLiked: Bool
    public let isCoined: Bool
    public let isFavorited: Bool
    /// 这次实际投出的硬币数；此前已投满时为 0。
    public let addedCoinCount: Int

    public init(isLiked: Bool, isCoined: Bool, isFavorited: Bool, addedCoinCount: Int) {
        self.isLiked = isLiked
        self.isCoined = isCoined
        self.isFavorited = isFavorited
        self.addedCoinCount = addedCoinCount
    }
}

/// 投币数量的规则，播放页面板、快捷键与写入共用。
public enum VideoCoinRule {
    /// 单个稿件最多投 2 枚；转载稿件最多 1 枚（服务端以 34005 兜底）。
    public static func maximumCoins(isReposted: Bool) -> Int {
        isReposted ? 1 : 2
    }

    /// 还能投几枚：上限减去已投数，不小于 0。
    public static func remainingCoins(isReposted: Bool, coinCount: Int) -> Int {
        max(0, maximumCoins(isReposted: isReposted) - coinCount)
    }
}

/// 点赞、投币、三连与关注 UP 主的读写 port：读当前账户对视频的互动，以及四种写入。
///
/// 实现是 BiliAPI 的 `BiliVideoEngagementRepository`，只经 `VideoEngagementUseCase` 调用。读取只按账户读取，失败抛出
/// `ContentApplicationError`；写入的 `accountID` 交给写授权器做账户绑定，失败抛出 `AccountWriteError`。取消原样传播；
/// 不重试、不排队。
public protocol VideoEngagementRepository: Sendable {
    func engagement(of target: VideoWriteTarget) async throws -> VideoEngagementState
    func setLiked(_ isLiked: Bool, target: VideoWriteTarget, accountID: Int64) async throws
    /// 关注（`isFollowing`）或取消关注；服务端已是目标状态时按成功返回。
    func setFollowing(
        _ isFollowing: Bool,
        uploader: UploaderWriteTarget,
        accountID: Int64
    ) async throws
    /// 返回附带的点赞是否成立（`alsoLike` 为 false 时为 false）。
    func addCoins(
        _ count: Int,
        alsoLike: Bool,
        target: VideoWriteTarget,
        accountID: Int64
    ) async throws -> Bool
    func triple(target: VideoWriteTarget, accountID: Int64) async throws -> VideoTripleOutcome
}

/// 点赞、投币、三连与关注；校验账户与数量后执行，成功时给出要分发的效果。
public struct VideoEngagementUseCase: Sendable {
    private let repository: any VideoEngagementRepository

    public init(repository: any VideoEngagementRepository) {
        self.repository = repository
    }

    public func engagement(of target: VideoWriteTarget) async throws -> VideoEngagementState {
        try await repository.engagement(of: target)
    }

    /// 账户 mid 不是正数时不发请求（`invalidRequest`）。
    public func setLiked(
        _ isLiked: Bool,
        target: VideoWriteTarget,
        accountID: Int64
    ) async throws -> AccountWriteEffect {
        guard accountID > 0 else { throw AccountWriteError.invalidRequest }
        try await repository.setLiked(isLiked, target: target, accountID: accountID)
        return AccountWriteEffect(
            accountID: accountID,
            change: .likeChanged(target, isLiked: isLiked)
        )
    }

    /// 关注或取消关注 UP 主；账户 mid 不是正数、或 UP 主就是这个账户时不发请求（`invalidRequest`）。
    public func setFollowing(
        _ isFollowing: Bool,
        uploader: UploaderWriteTarget,
        accountID: Int64
    ) async throws -> AccountWriteEffect {
        guard accountID > 0, uploader.mid != accountID else {
            throw AccountWriteError.invalidRequest
        }
        try await repository.setFollowing(isFollowing, uploader: uploader, accountID: accountID)
        return AccountWriteEffect(
            accountID: accountID,
            change: .followChanged(uploader, isFollowing: isFollowing)
        )
    }

    /// 投 1 或 2 枚；数量或账户不合法时不发请求（`invalidRequest`）。
    ///
    /// 效果里的 `alsoLiked` 是服务端报告的附带点赞结果。
    public func addCoins(
        _ count: Int,
        alsoLike: Bool,
        target: VideoWriteTarget,
        accountID: Int64
    ) async throws -> AccountWriteEffect {
        guard accountID > 0, (1...VideoCoinRule.maximumCoins(isReposted: false)).contains(count)
        else { throw AccountWriteError.invalidRequest }
        let liked = try await repository.addCoins(
            count,
            alsoLike: alsoLike,
            target: target,
            accountID: accountID
        )
        return AccountWriteEffect(
            accountID: accountID,
            change: .coinsAdded(target, count: count, alsoLiked: liked)
        )
    }

    /// 账户 mid 不是正数时不发请求（`invalidRequest`）。
    public func triple(
        target: VideoWriteTarget,
        accountID: Int64
    ) async throws -> AccountWriteEffect {
        guard accountID > 0 else { throw AccountWriteError.invalidRequest }
        let outcome = try await repository.triple(target: target, accountID: accountID)
        return AccountWriteEffect(accountID: accountID, change: .tripled(target, outcome))
    }
}
