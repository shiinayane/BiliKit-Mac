import BiliModels
import Foundation

struct SearchPayload: Decodable, Sendable {
    let page: Int
    let pageSize: Int
    let totalResults: Int
    let totalPages: Int
    let result: [SearchVideoPayload]

    private enum CodingKeys: String, CodingKey {
        case page
        case pageSize = "pagesize"
        case totalResults = "numResults"
        case totalPages = "numPages"
        case result
    }

    func model() throws -> SearchPage {
        guard page > 0, pageSize > 0, totalResults >= 0, totalPages >= 0 else {
            throw BiliAPIError.decodingFailed
        }
        return SearchPage(
            videos:
                try result
                .filter(\.hasUsableBVID)
                .map { try $0.model() },
            pageNumber: page,
            pageSize: pageSize,
            totalResults: totalResults,
            totalPages: totalPages
        )
    }
}

struct SearchVideoPayload: Decodable, Sendable {
    let bvid: String
    let title: String
    let pic: String
    let author: String
    let mid: Int64
    let upic: String?
    let duration: String
    let pubdate: Int64
    let play: Int64
    let danmaku: Int64
    let like: Int64?

    var hasUsableBVID: Bool {
        bvid.hasPrefix("BV")
            && bvid.count <= 24
            && bvid.dropFirst(2).allSatisfy {
                $0.isASCII && ($0.isLetter || $0.isNumber)
            }
    }

    func model() throws -> SearchVideo {
        guard bvid.hasPrefix("BV"), !title.isEmpty, !author.isEmpty, pubdate >= 0 else {
            throw BiliAPIError.decodingFailed
        }
        return SearchVideo(
            bvid: bvid,
            title: Self.strippingTags(title),
            coverURL: WebImageURL.parse(pic),
            owner: VideoOwner(
                id: mid,
                name: author,
                avatarURL: upic.flatMap(WebImageURL.parse)
            ),
            statistics: VideoStatistics(
                viewCount: play,
                danmakuCount: danmaku,
                likeCount: like ?? 0
            ),
            durationSeconds: Self.durationSeconds(duration),
            publishedAt: Date(timeIntervalSince1970: TimeInterval(pubdate))
        )
    }

    private static func strippingTags(_ value: String) -> String {
        var result = ""
        var isInsideTag = false
        for character in value {
            switch character {
            case "<":
                isInsideTag = true
            case ">":
                isInsideTag = false
            default:
                if !isInsideTag {
                    result.append(character)
                }
            }
        }
        return result
    }

    private static func durationSeconds(_ value: String) -> Int? {
        let components = value.split(separator: ":").compactMap { Int($0) }
        guard components.count == value.split(separator: ":").count,
            components.allSatisfy({ $0 >= 0 })
        else {
            return nil
        }
        switch components.count {
        case 2:
            return components[0] * 60 + components[1]
        case 3:
            return components[0] * 3_600 + components[1] * 60 + components[2]
        default:
            return nil
        }
    }
}
