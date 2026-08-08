import BiliApplication
import BiliModels
import Foundation

struct PopularPayload: Decodable, Sendable {
    let list: [PopularVideoPayload]
}

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
            title: title,
            coverURL: WebImageURL.parse(pic),
            owner: owner.model(),
            statistics: stat.model(),
            durationSeconds: duration,
            publishedAt: Date(timeIntervalSince1970: TimeInterval(pubdate))
        )
    }
}

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
            title: title,
            coverURL: pic.flatMap(WebImageURL.parse),
            ownerName: owner.name,
            viewCount: stat.view,
            danmakuCount: stat.danmaku,
            durationSeconds: duration
        )
    }
}

struct RelatedVideoOwnerPayload: Decodable, Sendable {
    let name: String
}

struct RelatedVideoStatisticsPayload: Decodable, Sendable {
    let view: Int64
    let danmaku: Int64
}

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

struct UploaderCardDataPayload: Decodable, Sendable {
    let card: UploaderCardPayload
}

struct UploaderCardPayload: Decodable, Sendable {
    let mid: Int64
    let sign: String

    private enum CodingKeys: String, CodingKey {
        case mid
        case sign
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let numericMID = try? container.decode(Int64.self, forKey: .mid) {
            mid = numericMID
        } else {
            let stringMID = try container.decode(String.self, forKey: .mid)
            guard let numericMID = Int64(stringMID) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .mid,
                    in: container,
                    debugDescription: "Uploader MID is not an integer"
                )
            }
            mid = numericMID
        }
        sign = try container.decode(String.self, forKey: .sign)
    }
}

struct StatisticsPayload: Decodable, Sendable {
    let view: Int64
    let danmaku: Int64
    let like: Int64

    func model() -> VideoStatistics {
        VideoStatistics(viewCount: view, danmakuCount: danmaku, likeCount: like)
    }
}

struct VideoDetailPayload: Decodable, Sendable {
    let bvid: String
    let title: String
    let desc: String
    let pic: String
    let owner: OwnerPayload
    let stat: StatisticsPayload
    let duration: Int
    let pubdate: Int64
    let dimension: DimensionPayload?

    func model() throws -> VideoDetail {
        guard bvid.hasPrefix("BV"), !title.isEmpty, duration >= 0, pubdate >= 0 else {
            throw BiliAPIError.decodingFailed
        }
        return VideoDetail(
            bvid: bvid,
            title: title,
            summary: desc,
            coverURL: WebImageURL.parse(pic),
            owner: owner.model(),
            statistics: stat.model(),
            durationSeconds: duration,
            publishedAt: Date(timeIntervalSince1970: TimeInterval(pubdate)),
            dimension: dimension?.model()
        )
    }
}

struct PagePayload: Decodable, Sendable {
    let cid: Int64
    let page: Int
    let part: String
    let duration: Int
    let dimension: DimensionPayload?

    func model() throws -> VideoPage {
        guard cid > 0, page > 0, !part.isEmpty, duration >= 0 else {
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

struct DimensionPayload: Decodable, Sendable {
    let width: Int
    let height: Int
    let rotate: Int

    func model() -> VideoDimension {
        VideoDimension(width: width, height: height, rotation: rotate)
    }
}
