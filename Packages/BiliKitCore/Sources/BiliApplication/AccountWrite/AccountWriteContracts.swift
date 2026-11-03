import BiliModels
import Foundation

/// 用户发起的账户写入（稍后再看、收藏、点赞、投币、三连、关注与首页推荐的「不感兴趣」）共用的应用级错误。
///
/// 由 BiliAPI 的写 adapter 映射：-101、-111 与凭据账户不符为 `authenticationInvalid`；窗口以为已登录、本地却没有凭据为
/// `authenticationRequired`；Keychain 不可用为 `authenticationUnavailable`；HTTP 403／412、-352 等风控为 `restricted`；
/// 稍后再看的业务码 90000 为 `unsupportedContent`，90001 为 `listFull`，90003 与内容不存在类业务码为 `contentUnavailable`；
/// 收藏的业务码 11203 为 `listFull`，11010（收藏夹不存在）为 `contentUnavailable`；投币的 -104 为 `coinsInsufficient`，
/// 34005 为 `coinLimitReached`，34002 为 `ownVideo`，34004 为 `restricted`；点赞、投币、三连的 -403（账号异常）为
/// `declinedForClient`，三连报告的风控为 `restricted`；关注的业务码 22009（关注数已达上限）为 `listFull`；其他非零
/// 业务码为 `rejected`，不回显服务端 message；网络与无法判定结果的响应为 `unavailable`。是否复核账户只读
/// `requiresAccountRevalidation`，调用方不各自判断；提示措辞按 case 由写入结果胶囊的文案决定（写入从不自动重试，没有
/// 另一个需要“是否可重试”的调用方）。写入不自动重试、不排队、不持久化（见 SECURITY-MODEL §3）。
public enum AccountWriteError: Error, Sendable, Equatable {
    /// 请求形状不合规或授权器拒绝：客户端编程错误，不发出请求。
    case invalidRequest
    /// 窗口以为已登录，本地却没有凭据：窗口的账户状态过期。
    case authenticationRequired
    /// 凭据失效（-101、-111、凭据损坏或过期，或凭据属于另一个账户）。
    case authenticationInvalid
    /// 本地凭据读不到（Keychain 不可用）。
    case authenticationUnavailable
    /// 风控或限流。
    case restricted
    /// 稍后再看已满（业务码 90001）、收藏夹已满（业务码 11203），或关注数已达上限（业务码 22009）。
    case listFull
    /// 这个稿件不能加入（业务码 90000：付费稿件）。
    case unsupportedContent
    /// 稿件不存在或已删除。
    case contentUnavailable
    /// 硬币不足（业务码 -104）。
    case coinsInsufficient
    /// 这个视频已投满（业务码 34005）。
    case coinLimitReached
    /// 不能给自己的视频投币（业务码 34002）。
    case ownVideo
    /// B 站拒绝了这个客户端的点赞、投币或三连（业务码 -403，账号异常）。
    ///
    /// 实测按稿件出现：同一账号有的稿件能点赞、有的被拒；照网页补统计字段、视频页 Referer 与 B 站下发的 buvid 都没有
    /// 改善。网页上可以完成，所以结果里给出在浏览器中打开这个视频（`AccountWriteReport.webFallbackURL`）。
    case declinedForClient
    /// 其他业务拒绝。
    case rejected(code: Int)
    /// 网络失败或无法判定结果。
    case unavailable
}

extension AccountWriteError {
    /// 凭据失效与“已登录却没有凭据”都说明窗口的账户状态需要复核；其他失败不复核。
    ///
    /// 写入只在窗口确认已登录时才发出，所以本地没有凭据同样是窗口状态过期，与只按账户读取的资料库来源一致。
    public var requiresAccountRevalidation: Bool {
        switch self {
        case .authenticationRequired, .authenticationInvalid:
            true
        case .invalidRequest, .authenticationUnavailable, .restricted, .listFull,
            .unsupportedContent, .contentUnavailable, .coinsInsufficient, .coinLimitReached,
            .ownVideo, .declinedForClient, .rejected, .unavailable:
            false
        }
    }
}

/// 写入作用的视频：只接受合法 BVID，写接口要的 av 号由 BiliAPI 在本地换算。
public struct VideoWriteTarget: Sendable, Hashable {
    public let bvid: String

    /// BVID 不合法时为 nil：菜单与执行写入前都按卡片 ID 构造，构造失败就不发请求。
    public init?(bvid: String) {
        guard BVID.isValid(bvid) else { return nil }
        self.bvid = bvid
    }
}

/// 关注写入作用的 UP 主：只接受正数 mid。
public struct UploaderWriteTarget: Sendable, Hashable {
    public let mid: Int64

    /// mid 不是正数时为 nil，不发请求。
    public init?(mid: Int64) {
        guard mid > 0 else { return nil }
        self.mid = mid
    }
}

/// 一次成功或尝试中的账户写入改了什么。
public enum AccountWriteChange: Sendable, Hashable {
    case watchLaterAdded(VideoWriteTarget)
    case watchLaterRemoved(VideoWriteTarget)
    /// 「收藏到…」面板确认的归属改动。
    case favoriteMembershipChanged(FavoriteMembershipChange)
    /// 夹内「从此收藏夹移除」。
    case removedFromFavoriteFolder(FavoriteFolderEntry)
    /// 点赞或取消点赞。
    case likeChanged(VideoWriteTarget, isLiked: Bool)
    /// 投币；`alsoLiked` 是附带点赞的结果（尝试中为请求时的选择）。
    case coinsAdded(VideoWriteTarget, count: Int, alsoLiked: Bool)
    /// 三连；尝试中的改动没有结果，成功的效果带服务端报告的逐项结果。
    case tripled(VideoWriteTarget, VideoTripleOutcome?)
    /// 关注或取消关注 UP 主。
    case followChanged(UploaderWriteTarget, isFollowing: Bool)
    /// 对首页推荐的一条说「不感兴趣」。
    case recommendationDisliked(RecommendationFeedback)
    /// 撤销「不感兴趣」。
    case recommendationDislikeCancelled(RecommendationFeedback)
}

/// 写入成功后需要让其他视图知道的事实：哪个账户的哪项内容变了。
///
/// 由写 use case 在服务端确认成功后给出；App 的写入协调者把它交给本窗口的效果路由，并经进程级效果集线器转给其他
/// 窗口。接收方只处理与自己账户一致的效果。
public struct AccountWriteEffect: Sendable, Equatable {
    public let accountID: Int64
    public let change: AccountWriteChange

    public init(accountID: Int64, change: AccountWriteChange) {
        self.accountID = accountID
        self.change = change
    }
}

/// 一次写入的结果，供写入结果胶囊与读屏通告呈现；`failure` 为 nil 表示成功。
public struct AccountWriteReport: Sendable, Equatable {
    public let change: AccountWriteChange
    public let failure: AccountWriteError?

    public init(change: AccountWriteChange, failure: AccountWriteError?) {
        self.change = change
        self.failure = failure
    }

    /// 被 B 站拒绝、但网页上可以完成的点赞、投币或三连：要在浏览器中打开的视频网页；其他结果为 nil。
    ///
    /// 结果胶囊据此给出「在浏览器中打开」，写入协调者据此让这条结果停留更久。
    public var webFallbackURL: URL? {
        guard failure == .declinedForClient else { return nil }
        return switch change {
        case .likeChanged(let target, _), .coinsAdded(let target, _, _), .tripled(let target, _):
            BVID.webPageURL(target.bvid)
        case .watchLaterAdded, .watchLaterRemoved, .favoriteMembershipChanged,
            .removedFromFavoriteFolder, .recommendationDisliked, .recommendationDislikeCancelled,
            .followChanged:
            nil
        }
    }
}
