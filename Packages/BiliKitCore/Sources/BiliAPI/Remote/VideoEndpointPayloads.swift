import BiliApplication
import BiliModels
import BiliNetworking
import Foundation

/// 热门（`/x/web-interface/popular`）的 `data`，由 `BiliAPIClient.popular` 映射为 `PopularPage`；
/// `no_more` 决定是否还有下一页。
struct PopularPayload: Decodable, Sendable {
    let list: [PopularVideoPayload]
    let noMore: Bool

    private enum CodingKeys: String, CodingKey {
        case list
        case noMore = "no_more"
    }
}

/// 热门列表的一项，映射为 `PopularVideo`；BVID 不以 `BV` 开头、标题为空或时长、
/// 发布时间为负时整页失败。
struct PopularVideoPayload: Decodable, Sendable {
    let bvid: String
    let title: String
    let pic: String
    let owner: OwnerPayload
    let stat: StatisticsPayload
    let duration: Int
    let pubdate: Int64

    func model() throws -> PopularVideo {
        guard bvid.hasPrefix("BV"), !title.isEmpty, duration >= 0, pubdate >= 0 else {
            throw BiliAPIError.decodingFailed
        }
        return PopularVideo(
            bvid: bvid,
            title: RemoteHTMLText.plainText(title),
            coverURL: WebImageURL.parse(pic),
            owner: owner.model(),
            statistics: stat.model(),
            durationSeconds: duration,
            publishedAt: Date(timeIntervalSince1970: TimeInterval(pubdate))
        )
    }
}

/// 相关推荐（`/x/web-interface/archive/related`，`data` 直接是数组）的一项，由
/// `BiliAPIClient.relatedVideos` 映射为 `RelatedVideo`。
///
/// 任一项缺字段、BVID 不是 12 位 `BV…`、UP 主昵称为空或计数为负时整个列表失败。
struct RelatedVideoPayload: Decodable, Sendable {
    let bvid: String?
    let title: String?
    let pic: String?
    let owner: RelatedVideoOwnerPayload?
    let stat: RelatedVideoStatisticsPayload?
    let duration: Int?

    func model() throws -> RelatedVideo {
        guard let bvid,
            let title,
            let owner,
            let stat,
            bvid.hasPrefix("BV"),
            bvid.count == 12,
            !title.isEmpty,
            !owner.name.isEmpty,
            stat.view >= 0,
            stat.danmaku >= 0,
            duration.map({ $0 >= 0 }) ?? true
        else {
            throw BiliAPIError.decodingFailed
        }
        return RelatedVideo(
            bvid: bvid,
            title: RemoteHTMLText.plainText(title),
            coverURL: pic.flatMap(WebImageURL.parse),
            ownerName: owner.name,
            viewCount: stat.view,
            danmakuCount: stat.danmaku,
            durationSeconds: duration
        )
    }
}

/// 相关推荐里的 UP 主，只取昵称。
struct RelatedVideoOwnerPayload: Decodable, Sendable {
    let name: String
}

/// 相关推荐里的播放数与弹幕数。
struct RelatedVideoStatisticsPayload: Decodable, Sendable {
    let view: Int64
    let danmaku: Int64
}

/// 热门、推荐与视频详情共用的 UP 主：MID、昵称与头像，映射为 `VideoOwner`；头像地址经
/// `WebImageURL` 规范，不合规时视为没有头像。
struct OwnerPayload: Decodable, Sendable {
    let mid: Int64
    let name: String
    let face: String?

    func model() -> VideoOwner {
        VideoOwner(
            id: mid,
            name: name,
            avatarURL: face.flatMap(WebImageURL.parse)
        )
    }
}

/// UP 主名片（`/x/web-interface/card`）的 `data`，由 `BiliAPIClient.uploaderProfile` 映射为
/// `UploaderProfile`。
///
/// 粉丝数（`follower`）与投稿数（`archive_count`）在 `data` 这一层；它们只是展示，缺失、为负或形状不对时按缺省，
/// 不拖累签名。登录时同一响应还带 `following`，这里刻意不取：名片按 UP 主沿用、不随账户重读，关注状态来自播放页的互动
/// 读取。
struct UploaderCardDataPayload: Decodable, Sendable {
    let card: UploaderCardPayload
    let follower: Int64?
    let archiveCount: Int64?

    private enum CodingKeys: String, CodingKey {
        case card
        case follower
        case archiveCount = "archive_count"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        card = try container.decode(UploaderCardPayload.self, forKey: .card)
        follower = container.decodeLossyIfPresent(Int64.self, forKey: .follower)
            .flatMap { $0 >= 0 ? $0 : nil }
        archiveCount = container.decodeLossyIfPresent(Int64.self, forKey: .archiveCount)
            .flatMap { $0 >= 0 ? $0 : nil }
    }

    func model() -> UploaderProfile {
        card.model(followerCount: follower, videoCount: archiveCount)
    }
}

/// 名片的 `card`：MID、昵称、头像、签名与大会员状态。
///
/// `mid` 可能是数字或数字字符串；调用方要求它与请求的 MID 相等，否则按解码失败处理。
struct UploaderCardPayload: Decodable, Sendable {
    let mid: Int64
    let name: String?
    let face: String?
    let sign: String
    let vip: MemberVIPPayload?

    private enum CodingKeys: String, CodingKey {
        case mid
        case name
        case face
        case sign
        case vip
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let numericMID = Int64(try container.decodeIntegerText(forKey: .mid)) else {
            throw DecodingError.dataCorruptedError(
                forKey: .mid,
                in: container,
                debugDescription: "Uploader MID is not an integer"
            )
        }
        mid = numericMID
        // 名字与头像只在只凭 MID 打开的空间里补齐头部，字段异常时按缺省处理，不拖累签名。
        name = try? container.decodeIfPresent(String.self, forKey: .name)
        face = try? container.decodeIfPresent(String.self, forKey: .face)
        sign = try container.decode(String.self, forKey: .sign)
        // 大会员只决定名字颜色，字段异常时按非大会员处理，不拖累签名。
        vip = try? container.decodeIfPresent(MemberVIPPayload.self, forKey: .vip)
    }

    func model(followerCount: Int64?, videoCount: Int64?) -> UploaderProfile {
        UploaderProfile(
            name: name,
            avatarURL: face.flatMap(WebImageURL.parse),
            signature: sign,
            isVIP: vip?.isActive == true,
            followerCount: followerCount,
            videoCount: videoCount
        )
    }
}

/// 热门、推荐与视频详情共用的播放、弹幕与点赞数，映射为 `VideoStatistics`。
///
/// 投币与收藏数只有视频详情用，缺失或形状不对时为 nil，不影响列表与详情的解码。
struct StatisticsPayload: Decodable, Sendable {
    let view: Int64
    let danmaku: Int64
    let like: Int64
    let coin: LossyDecodable<Int64>?
    let favorite: LossyDecodable<Int64>?

    func model() -> VideoStatistics {
        VideoStatistics(viewCount: view, danmakuCount: danmaku, likeCount: like)
    }
}

/// 视频详情（`/x/web-interface/wbi/view`）的 `data`，由 `BiliAPIClient.videoDetail` 映射为
/// `VideoDetail`。
///
/// `aid` 非正、BVID 不以 `BV` 开头、标题为空、时长或发布时间为负、分 P 无效或
/// cid／序号重复时整体失败；调用方另要求返回的 BVID 与请求一致。
struct VideoDetailPayload: Decodable, Sendable {
    let aid: Int64?
    let bvid: String
    let title: String
    let desc: String
    /// 分段简介；缺失、为 null 或形状不对时为 nil，简介退回 `desc`。
    let descV2: LossyDecodable<[LossyDecodable<VideoDescriptionSegmentPayload>]>?
    let pic: String
    let owner: OwnerPayload
    let stat: StatisticsPayload
    let duration: Int
    let pubdate: Int64
    let dimension: DimensionPayload?
    let pages: [PagePayload]?
    let ugcSeason: UGCSeasonPayload?
    let isUPowerExclusive: Bool?
    let isUPowerPreviewAvailable: Bool?
    let isUPowerPlayable: Bool?
    /// 1 自制、2 转载、3 未填写；缺失或形状不对时按自制处理。
    let copyright: LossyDecodable<Int>?

    private enum CodingKeys: String, CodingKey {
        case aid, bvid, title, desc, pic, owner, stat, duration, pubdate, dimension, pages,
            copyright
        case descV2 = "desc_v2"
        case ugcSeason = "ugc_season"
        case isUPowerExclusive = "is_upower_exclusive"
        case isUPowerPreviewAvailable = "is_upower_preview"
        case isUPowerPlayable = "is_upower_play"
    }

    func model() throws -> VideoDetail {
        guard aid.map({ $0 > 0 }) ?? true,
            bvid.hasPrefix("BV"),
            !title.isEmpty,
            duration >= 0,
            pubdate >= 0
        else {
            throw BiliAPIError.decodingFailed
        }
        let resolvedPages = try validatedPageModels(pages ?? [])
        let summary = VideoDescriptionAssembly.summary(
            desc: desc,
            segments: descV2?.value?.map(\.value)
        )
        return VideoDetail(
            bvid: bvid,
            title: title,
            summary: summary.text,
            summaryLinks: summary.links,
            coverURL: WebImageURL.parse(pic),
            owner: owner.model(),
            statistics: stat.model(),
            durationSeconds: duration,
            publishedAt: Date(timeIntervalSince1970: TimeInterval(pubdate)),
            dimension: dimension?.model(),
            aid: aid,
            pages: resolvedPages,
            collection: ugcSeason?.model(),
            access: VideoAccess(
                isUPowerExclusive: isUPowerExclusive,
                isUPowerPreviewAvailable: isUPowerPreviewAvailable,
                isUPowerPlayable: isUPowerPlayable
            ),
            engagementSummary: VideoEngagementSummary(
                coinCount: stat.coin?.value.map { max(0, $0) },
                favoriteCount: stat.favorite?.value.map { max(0, $0) },
                isReposted: copyright?.value == Self.repostedCopyright
            )
        )
    }

    /// `copyright` 的转载取值。
    private static let repostedCopyright = 2
}

/// 分 P：cid、序号、标题、时长与画面尺寸，映射为 `VideoPage`。
struct PagePayload: Decodable, Sendable {
    let cid: Int64
    let page: Int
    let part: String
    let duration: Int
    let dimension: DimensionPayload?

    func model() throws -> VideoPage {
        // 较早的单 P 视频分 P 标题常为空字符串，不算数据错误；显示时省略。
        guard cid > 0, page > 0, duration >= 0 else {
            throw BiliAPIError.decodingFailed
        }
        return VideoPage(
            cid: cid,
            index: page,
            title: part,
            durationSeconds: duration,
            dimension: dimension?.model()
        )
    }
}

/// 视频所属合集（`ugc_season`），映射为 `VideoCollection`。
///
/// 各字段单独容错解码；合集 ID 或标题无效时没有合集。小节与条目的身份字段互相冲突时不丢弃，
/// 而是标为身份不一致（`isIdentityConsistent` 为 false）供界面说明不可用；同一 ID
/// 重复出现时用出现序号区分。
struct UGCSeasonPayload: Decodable, Sendable {
    let id: Int64?
    let title: String?
    let epCount: Int?
    let sections: [UGCSeasonSectionPayload]?

    private enum CodingKeys: String, CodingKey {
        case id, title, sections
        case epCount = "ep_count"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try? container.decodeIfPresent(Int64.self, forKey: .id)
        title = try? container.decodeIfPresent(String.self, forKey: .title)
        epCount = try? container.decodeIfPresent(Int.self, forKey: .epCount)
        sections = try? container.decodeIfPresent([UGCSeasonSectionPayload].self, forKey: .sections)
    }

    func model() -> VideoCollection? {
        guard let id,
            id > 0,
            let title,
            !title.isEmpty,
            epCount.map({ $0 >= 0 }) ?? true
        else {
            return nil
        }
        let resolvedSections = sections ?? []
        let sectionIDCounts = Dictionary(grouping: resolvedSections, by: \.resolvedID)
            .mapValues(\.count)
        return VideoCollection(
            id: id,
            title: title,
            reportedEpisodeCount: epCount,
            sections: resolvedSections.enumerated().map { ordinal, section in
                section.model(
                    seasonID: id,
                    ordinal: ordinal,
                    needsOccurrenceIdentity: sectionIDCounts[section.resolvedID, default: 0] > 1
                )
            }
        )
    }
}

/// 合集的一个小节；`id` 与 `section_id` 是同一身份的两种写法，两者不一致、身份不为正或 `season_id`
/// 与所属合集不符时标为身份不一致。
struct UGCSeasonSectionPayload: Decodable, Sendable {
    let id: Int64?
    let sectionIDAlias: Int64?
    let seasonID: Int64?
    let title: String?
    let episodes: [UGCSeasonEpisodePayload]?

    private enum CodingKeys: String, CodingKey {
        case id, title, episodes
        case sectionIDAlias = "section_id"
        case seasonID = "season_id"
    }

    var resolvedID: Int64? { id ?? sectionIDAlias }

    init(from decoder: any Decoder) throws {
        guard let container = try? decoder.container(keyedBy: CodingKeys.self) else {
            id = nil
            seasonID = nil
            sectionIDAlias = nil
            title = nil
            episodes = nil
            return
        }
        id = try? container.decodeIfPresent(Int64.self, forKey: .id)
        seasonID = try? container.decodeIfPresent(Int64.self, forKey: .seasonID)
        sectionIDAlias = try? container.decodeIfPresent(Int64.self, forKey: .sectionIDAlias)
        title = try? container.decodeIfPresent(String.self, forKey: .title)
        episodes = try? container.decodeIfPresent([UGCSeasonEpisodePayload].self, forKey: .episodes)
    }

    func model(
        seasonID expectedSeasonID: Int64,
        ordinal: Int,
        needsOccurrenceIdentity: Bool
    ) -> VideoCollectionSection {
        let sectionIDFieldsAreConsistent =
            id == nil || sectionIDAlias == nil || id == sectionIDAlias
        let resolvedID = resolvedID ?? 0
        let identityIsConsistent =
            resolvedID > 0
            && sectionIDFieldsAreConsistent
            && (seasonID.map { $0 == expectedSeasonID } ?? true)
        let resolvedEpisodes = episodes ?? []
        let episodeIDCounts = Dictionary(
            grouping: resolvedEpisodes.compactMap(\.id),
            by: { $0 }
        ).mapValues(\.count)
        return VideoCollectionSection(
            id: VideoCollectionSectionIdentity(
                seasonID: expectedSeasonID,
                sectionID: resolvedID,
                occurrenceOrdinal: needsOccurrenceIdentity ? ordinal : nil
            ),
            ordinal: ordinal,
            title: title ?? "",
            episodes: resolvedEpisodes.enumerated().map { episodeOrdinal, episode in
                episode.model(
                    seasonID: expectedSeasonID,
                    sectionID: resolvedID,
                    sectionOccurrenceOrdinal: needsOccurrenceIdentity ? ordinal : nil,
                    ordinal: episodeOrdinal,
                    parentIdentityIsConsistent: identityIsConsistent,
                    needsOccurrenceIdentity: episode.id == nil
                        || episodeIDCounts[episode.id ?? 0, default: 0] > 1
                )
            },
            isIdentityConsistent: identityIsConsistent
        )
    }
}

/// 合集小节里的一集；顶层字段与 `arc`、`page`、`pages` 里重复的身份字段互相核对，
/// 冲突时不采用冲突值并标为身份不一致。
struct UGCSeasonEpisodePayload: Decodable, Sendable {
    let id: Int64?
    let seasonID: Int64?
    let sectionID: Int64?
    let aid: Int64?
    let bvid: String?
    let cid: Int64?
    let title: String?
    let arc: UGCSeasonEpisodeArcPayload?
    let page: PagePayload?
    let pages: [PagePayload]?

    private enum CodingKeys: String, CodingKey {
        case id, aid, bvid, cid, title, arc, page, pages
        case seasonID = "season_id"
        case sectionID = "section_id"
    }

    init(from decoder: any Decoder) throws {
        guard let container = try? decoder.container(keyedBy: CodingKeys.self) else {
            id = nil
            seasonID = nil
            sectionID = nil
            aid = nil
            bvid = nil
            cid = nil
            title = nil
            arc = nil
            page = nil
            pages = nil
            return
        }
        id = try? container.decodeIfPresent(Int64.self, forKey: .id)
        seasonID = try? container.decodeIfPresent(Int64.self, forKey: .seasonID)
        sectionID = try? container.decodeIfPresent(Int64.self, forKey: .sectionID)
        aid = try? container.decodeIfPresent(Int64.self, forKey: .aid)
        bvid = try? container.decodeIfPresent(String.self, forKey: .bvid)
        cid = try? container.decodeIfPresent(Int64.self, forKey: .cid)
        title = try? container.decodeIfPresent(String.self, forKey: .title)
        arc = try? container.decodeIfPresent(UGCSeasonEpisodeArcPayload.self, forKey: .arc)
        page = try? container.decodeIfPresent(PagePayload.self, forKey: .page)
        pages = try? container.decodeIfPresent([PagePayload].self, forKey: .pages)
    }

    func model(
        seasonID expectedSeasonID: Int64,
        sectionID expectedSectionID: Int64,
        sectionOccurrenceOrdinal: Int?,
        ordinal: Int,
        parentIdentityIsConsistent: Bool,
        needsOccurrenceIdentity: Bool
    ) -> VideoCollectionEpisode {
        let aidIsConsistent = aid == nil || arc?.aid == nil || aid == arc?.aid
        let bvidIsConsistent = bvid == nil || arc?.bvid == nil || bvid == arc?.bvid
        let resolvedAID = aidIsConsistent ? (aid ?? arc?.aid) : nil
        let resolvedBVID = bvidIsConsistent ? (bvid ?? arc?.bvid) : nil
        let resolvedTitle = title ?? arc?.title ?? ""
        let resolvedPage = page.flatMap { try? $0.model() }
        let knownPages = pages.flatMap { try? validatedPageModels($0) }
        let pageDataIsValid = page == nil || resolvedPage != nil
        let pagesDataIsValid = pages == nil || knownPages != nil
        let candidateCID = cid ?? resolvedPage?.cid ?? knownPages?.first?.cid
        let cidIsConsistent =
            (cid == nil || resolvedPage?.cid == nil || cid == resolvedPage?.cid)
            && (knownPages.map { pages in
                guard let candidateCID else { return true }
                return pages.contains(where: { $0.cid == candidateCID })
            } ?? true)
        let identityIsConsistent =
            parentIdentityIsConsistent
            && (id.map { $0 > 0 } ?? true)
            && (seasonID.map { $0 == expectedSeasonID } ?? true)
            && (sectionID.map { $0 == expectedSectionID } ?? true)
            && aidIsConsistent
            && bvidIsConsistent
            && (resolvedAID.map { $0 > 0 } ?? true)
            && (resolvedBVID.map { $0.hasPrefix("BV") && $0.count == 12 } ?? true)
            && !resolvedTitle.isEmpty
            && (cid.map { $0 > 0 } ?? true)
            && pageDataIsValid
            && pagesDataIsValid
            && cidIsConsistent
            && (arc?.duration.map { $0 >= 0 } ?? true)
        return VideoCollectionEpisode(
            id: VideoCollectionEpisodeIdentity(
                seasonID: expectedSeasonID,
                sectionID: expectedSectionID,
                sectionOccurrenceOrdinal: sectionOccurrenceOrdinal,
                episodeID: id,
                occurrenceOrdinal: needsOccurrenceIdentity ? ordinal : nil
            ),
            ordinal: ordinal,
            aid: resolvedAID,
            bvid: resolvedBVID,
            title: resolvedTitle,
            coverURL: arc?.pic.flatMap(WebImageURL.parse),
            durationSeconds: arc?.duration,
            defaultCID: cidIsConsistent ? candidateCID : nil,
            knownPages: knownPages,
            isIdentityConsistent: identityIsConsistent
        )
    }
}

/// 合集条目的 `arc`：稿件 aid、BVID、标题、封面与时长，用于补齐或核对顶层字段。
struct UGCSeasonEpisodeArcPayload: Decodable, Sendable {
    let aid: Int64?
    let bvid: String?
    let title: String?
    let pic: String?
    let duration: Int?
}

/// 映射分 P 列表：任一分 P 无效或 cid、序号重复时失败，结果按序号排序。
func validatedPageModels(_ payloads: [PagePayload]) throws -> [VideoPage] {
    let pages = try payloads.map { try $0.model() }
    guard Set(pages.map(\.cid)).count == pages.count,
        Set(pages.map(\.index)).count == pages.count
    else {
        throw BiliAPIError.decodingFailed
    }
    return pages.sorted(by: { $0.index < $1.index })
}

/// 画面宽高与旋转标记，映射为 `VideoDimension`。
struct DimensionPayload: Decodable, Sendable {
    let width: Int
    let height: Int
    let rotate: Int

    func model() -> VideoDimension {
        VideoDimension(width: width, height: height, rotation: rotate)
    }
}
