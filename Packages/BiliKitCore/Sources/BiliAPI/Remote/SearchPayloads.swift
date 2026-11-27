import BiliModels
import BiliNetworking
import Foundation

/// 视频搜索（`/x/web-interface/wbi/search/type`）的 `data`，由 `BiliAPIClient.searchVideos` 映射为
/// `SearchPage`。
///
/// 页码信息不合规时整页失败；BVID 形状不合规的结果先滤掉，其余结果映射失败时整页失败。
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

/// 搜索结果的一项，映射为 `SearchVideo`；标题带高亮标签，经
/// `RemoteHTMLText.searchResult` 去标签并解码实体。
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
    /// 弹幕数：现网 `danmaku` 与旧字段 `video_review` 都有（2026-11 实测），文档只记旧字段；先取前者，两者都缺时
    /// 才按 0，不因为一条结果缺字段让整页失败。
    let danmaku: Int64?
    let videoReview: Int64?
    let like: Int64?

    private enum CodingKeys: String, CodingKey {
        case bvid, title, pic, author, mid, upic, duration, pubdate, play, danmaku, like
        case videoReview = "video_review"
    }

    /// `BV` 开头、总长 ≤ 24 的 ASCII 字母数字；不合规的结果在映射前丢弃，不算整页错误。
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
            title: RemoteHTMLText.searchResult(title),
            coverURL: WebImageURL.parse(pic),
            owner: VideoOwner(
                id: mid,
                name: author,
                avatarURL: upic.flatMap(WebImageURL.parse)
            ),
            statistics: VideoStatistics(
                viewCount: play,
                danmakuCount: danmaku ?? videoReview ?? 0,
                likeCount: like ?? 0
            ),
            durationSeconds: RemoteClockDuration.seconds(duration),
            publishedAt: Date(timeIntervalSince1970: TimeInterval(pubdate))
        )
    }
}
