import BiliModels
import BiliNetworking
import Foundation

/// App 端首页推荐（`/x/v2/feed/index`）的 `data`，由 `BiliAPIClient.recommendations` 映射为 `RecommendationPage`。
///
/// 单个条目形状不对只丢这一条，不让整批失败。
struct AppFeedPayload: Decodable, Sendable {
    let items: [AppFeedItemPayload]

    private enum CodingKeys: String, CodingKey {
        case items
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        items = try container.decode([LossyDecodable<AppFeedItemPayload>].self, forKey: .items)
            .compactMap(\.value)
    }
}

/// 推荐流的一张卡片，只有普通视频映射为 `RecommendedVideo`。
///
/// 丢弃：`goto` 不是 `av`；`card_goto` 含 `ad` 或带 `ad_info`（商业推广）；没有 `player_args`（参考实现观察到充电专属
/// 稿件没有它，不能直接播放）；av 号、标题、UP 主或时长缺失。BV 号优先用 `bvid`，没有时由 av 号本地换算。
struct AppFeedItemPayload: Decodable, Sendable {
    let goto: String?
    let cardGoto: String?
    let hasAdInfo: Bool
    let param: String?
    let bvid: String?
    let title: String?
    let cover: String?
    let uploaderID: Int64?
    let uploaderName: String?
    let avatar: String?
    let durationSeconds: Int?
    let hasPlayerArguments: Bool
    let coverTexts: [String]
    let description: String?
    let reasons: [String]
    /// 续传游标；整批里最后一张卡片的值就是下一批请求的 `idx`。
    let index: Int64?

    private enum CodingKeys: String, CodingKey {
        case goto
        case cardGoto = "card_goto"
        case adInfo = "ad_info"
        case param
        case bvid
        case title
        case cover
        case args
        case avatar
        case playerArgs = "player_args"
        case coverLeftText1 = "cover_left_text_1"
        case coverLeftText2 = "cover_left_text_2"
        case coverLeftText3 = "cover_left_text_3"
        case desc
        case bottomReason = "bottom_rcmd_reason"
        case topReason = "top_rcmd_reason"
        case reason = "rcmd_reason"
        case index = "idx"
    }

    private struct Arguments: Decodable, Sendable {
        let upID: Int64?
        let upName: String?

        private enum CodingKeys: String, CodingKey {
            case upID = "up_id"
            case upName = "up_name"
        }
    }

    private struct Avatar: Decodable, Sendable {
        let cover: String?
    }

    private struct PlayerArguments: Decodable, Sendable {
        let duration: Int?
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        goto = container.decodeLossyIfPresent(String.self, forKey: .goto)
        cardGoto = container.decodeLossyIfPresent(String.self, forKey: .cardGoto)
        if container.contains(.adInfo) {
            hasAdInfo = (try? container.decodeNil(forKey: .adInfo)) != true
        } else {
            hasAdInfo = false
        }
        param = container.decodeLossyIfPresent(String.self, forKey: .param)
        bvid = container.decodeLossyIfPresent(String.self, forKey: .bvid)
        title = container.decodeLossyIfPresent(String.self, forKey: .title)
        cover = container.decodeLossyIfPresent(String.self, forKey: .cover)
        let arguments = container.decodeLossyIfPresent(Arguments.self, forKey: .args)
        uploaderID = arguments?.upID
        uploaderName = arguments?.upName
        avatar = container.decodeLossyIfPresent(Avatar.self, forKey: .avatar)?.cover
        let playerArguments = container.decodeLossyIfPresent(
            PlayerArguments.self,
            forKey: .playerArgs
        )
        hasPlayerArguments = playerArguments != nil
        durationSeconds = playerArguments?.duration
        coverTexts = [.coverLeftText1, .coverLeftText2, .coverLeftText3].compactMap {
            container.decodeLossyIfPresent(String.self, forKey: $0)
        }
        description = container.decodeLossyIfPresent(String.self, forKey: .desc)
        reasons = [.bottomReason, .topReason, .reason].compactMap {
            container.decodeLossyIfPresent(String.self, forKey: $0)
        }
        index = container.decodeLossyIfPresent(Int64.self, forKey: .index)
    }

    /// `now` 是收到这批响应的时刻，相对日期（“3小时前”“昨天”）以它为准。
    func model(receivedAt now: Date) -> RecommendedVideo? {
        guard goto == "av",
            !(cardGoto ?? "").contains("ad"),
            !hasAdInfo,
            hasPlayerArguments,
            let aid = param.flatMap(Int64.init),
            let bvid = bvid.flatMap({ BVID.isValid($0) ? $0 : nil })
                ?? BiliVideoAID.bvid(fromAID: aid),
            let title, !title.isEmpty,
            let uploaderID, uploaderID > 0,
            let uploaderName, !uploaderName.isEmpty,
            let durationSeconds, durationSeconds >= 0
        else {
            return nil
        }
        let counts = AppFeedCardText.counts(in: coverTexts)
        let reason = reasons.lazy
            .map { RemoteHTMLText.plainText($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        return RecommendedVideo(
            bvid: bvid,
            title: RemoteHTMLText.plainText(title),
            coverURL: cover.flatMap(WebImageURL.parse),
            owner: VideoOwner(
                id: uploaderID,
                name: uploaderName,
                avatarURL: avatar.flatMap(WebImageURL.parse)
            ),
            viewCount: counts.views,
            danmakuCount: counts.danmaku,
            durationSeconds: durationSeconds,
            publishedAt: description.flatMap {
                AppFeedCardText.publishedDate(inDescription: $0, now: now)
            },
            recommendationReason: reason
        )
    }
}
