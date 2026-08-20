import BiliModels
import Foundation

struct RecommendationPayload: Decodable, Sendable {
    let item: [RecommendationItemPayload]
}

struct RecommendationItemPayload: Decodable, Sendable {
    let goto: String?
    let bvid: String?
    let title: String?
    let pic: String?
    let owner: OwnerPayload?
    let stat: StatisticsPayload?
    let duration: Int?
    let pubdate: Int64?
    let recommendationReason: RecommendationReasonPayload?
    let hasBusinessInfo: Bool

    private enum CodingKeys: String, CodingKey {
        case goto
        case bvid
        case title
        case pic
        case owner
        case stat
        case duration
        case pubdate
        case recommendationReason = "rcmd_reason"
        case businessInfo = "business_info"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        goto = try container.decodeIfPresent(String.self, forKey: .goto)
        bvid = try container.decodeIfPresent(String.self, forKey: .bvid)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        pic = try container.decodeIfPresent(String.self, forKey: .pic)
        owner = try container.decodeIfPresent(OwnerPayload.self, forKey: .owner)
        stat = try container.decodeIfPresent(StatisticsPayload.self, forKey: .stat)
        duration = try container.decodeIfPresent(Int.self, forKey: .duration)
        pubdate = try container.decodeIfPresent(Int64.self, forKey: .pubdate)
        recommendationReason = try container.decodeIfPresent(
            RecommendationReasonPayload.self,
            forKey: .recommendationReason
        )
        if container.contains(.businessInfo) {
            hasBusinessInfo = try !container.decodeNil(forKey: .businessInfo)
        } else {
            hasBusinessInfo = false
        }
    }

    func model() -> RecommendedVideo? {
        guard goto == "av",
            !hasBusinessInfo,
            let bvid,
            bvid.hasPrefix("BV"),
            bvid.count == 12,
            let title,
            !title.isEmpty,
            let owner,
            let stat,
            let duration,
            duration >= 0,
            let pubdate,
            pubdate >= 0
        else {
            return nil
        }
        let normalizedReason = recommendationReason?.content.map {
            RemoteVideoTitleNormalizer.plainText($0)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return RecommendedVideo(
            bvid: bvid,
            title: RemoteVideoTitleNormalizer.plainText(title),
            coverURL: pic.flatMap(WebImageURL.parse),
            owner: owner.model(),
            statistics: stat.model(),
            durationSeconds: duration,
            publishedAt: Date(timeIntervalSince1970: TimeInterval(pubdate)),
            recommendationReason: normalizedReason.flatMap { $0.isEmpty ? nil : $0 }
        )
    }
}

struct RecommendationReasonPayload: Decodable, Sendable {
    let content: String?
}
