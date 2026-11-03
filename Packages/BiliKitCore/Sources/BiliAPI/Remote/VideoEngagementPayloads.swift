import BiliApplication
import Foundation

/// 当前账户对视频的互动（`/x/web-interface/archive/relation` 的 `data`），映射为 `VideoEngagementState`。
///
/// `like`、`coin`、`favorite` 缺失或形状不对时整份按解码失败：不知道是否已赞、已投几枚，按钮就给不出正确的状态，点赞
/// 可能发成取消。已投数夹在单个稿件的上限内。`attention`（是否关注了 UP 主）缺失或形状不对时只让关注状态未知
/// （关注按钮禁用），不拖累其余三项。
struct VideoRelationPayload: Decodable, Sendable {
    let like: Bool?
    let coin: Int?
    let favorite: Bool?
    let attention: Bool?

    private enum CodingKeys: String, CodingKey {
        case like, coin, favorite, attention
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        like = container.decodeLossyBool(forKey: .like)
        coin = container.decodeLossyIfPresent(Int.self, forKey: .coin)
        favorite = container.decodeLossyBool(forKey: .favorite)
        attention = container.decodeLossyBool(forKey: .attention)
    }

    func model() throws -> VideoEngagementState {
        guard let like, let coin, let favorite else { throw BiliAPIError.decodingFailed }
        return VideoEngagementState(
            isLiked: like,
            coinCount: min(max(0, coin), VideoCoinRule.maximumCoins(isReposted: false)),
            isFavorited: favorite,
            isFollowingUploader: attention
        )
    }
}

/// 投币响应的 `data`：附带的点赞是否成立。
struct VideoCoinPayload: Decodable, Sendable {
    let like: Bool?

    private enum CodingKeys: String, CodingKey {
        case like
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        like = container.decodeLossyBool(forKey: .like)
    }
}

/// 三连响应的 `data`，映射为 `VideoTripleOutcome`。
///
/// 实测：已经做过的项也报 true，`multiply` 是这次实际投出的币数（此前已投满时为 0）。`is_risk` 为 true 或
/// `gaia_res_type` 非 0 是风控验证，按风控失败；`like`、`coin`、`fav` 缺失时整份按解码失败。
struct VideoTriplePayload: Decodable, Sendable {
    let like: Bool?
    let coin: Bool?
    let fav: Bool?
    let multiply: Int?
    let isRisk: Bool?
    let gaiaResType: Int?

    private enum CodingKeys: String, CodingKey {
        case like, coin, fav, multiply
        case isRisk = "is_risk"
        case gaiaResType = "gaia_res_type"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        like = container.decodeLossyBool(forKey: .like)
        coin = container.decodeLossyBool(forKey: .coin)
        fav = container.decodeLossyBool(forKey: .fav)
        multiply = container.decodeLossyIfPresent(Int.self, forKey: .multiply)
        isRisk = container.decodeLossyBool(forKey: .isRisk)
        gaiaResType = container.decodeLossyIfPresent(Int.self, forKey: .gaiaResType)
    }

    func model() throws -> VideoTripleOutcome {
        guard isRisk != true, (gaiaResType ?? 0) == 0 else {
            throw BiliAPIError.riskControlVoucher
        }
        guard let like, let coin, let fav else { throw BiliAPIError.decodingFailed }
        return VideoTripleOutcome(
            isLiked: like,
            isCoined: coin,
            isFavorited: fav,
            addedCoinCount: min(
                max(0, multiply ?? 0),
                VideoCoinRule.maximumCoins(isReposted: false)
            )
        )
    }
}
