import BiliModels
import BiliNetworking
import Foundation

/// UP 主空间投稿（App 端 `/x/v2/space/archive/cursor`）的 `data`，由 `BiliAPIClient` 的空间扩展映射为
/// `UploaderVideoBatch`。
///
/// 下一批游标取本批最后一条的 `param`，只在 `has_next` 为真时给出；总数取 `count`。条目逐条宽松解码，形状不对或不是普通
/// 稿件（`goto` 不是 av）的条目只丢弃那一条，但它的 `param` 仍可作为游标，游标不会因此落在更早的条目上。
struct UploaderVideoArchivePayload: Decodable, Sendable {
    let count: Int
    let hasNext: Bool
    let items: [UploaderVideoArchiveItemPayload]

    private enum CodingKeys: String, CodingKey {
        case count
        case hasNext = "has_next"
        case item
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        count = container.decodeLossyIfPresent(Int.self, forKey: .count) ?? 0
        hasNext = container.decodeLossyBool(forKey: .hasNext) ?? false
        // 到底时 `item` 可能缺失或为 null：按空批处理，不让整批失败。
        items =
            (try? container.decodeLossyElements(UploaderVideoArchiveItemPayload.self, forKey: .item))
            ?? []
    }

    func model() -> UploaderVideoBatch {
        let nextCursor =
            hasNext
            ? items.last.map(\.param).flatMap { param in
                UploaderVideoCursorPayload.isValid(param) ? UploaderVideoCursor(value: param) : nil
            }
            : nil
        return UploaderVideoBatch(
            videos: items.compactMap { $0.model() },
            nextCursor: nextCursor,
            totalCount: count
        )
    }
}

/// 投稿游标的形状校验：游标原样拼回 query，只接受十进制数字（实测是 aid 或排序位置），防止异常正文改写请求。
enum UploaderVideoCursorPayload {
    /// 远超 aid 的位数，只用来拒绝异常值。
    private static let maximumLength = 20

    static func isValid(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= maximumLength
            && value.utf8.allSatisfy { (0x30...0x39).contains($0) }
    }
}

/// 投稿列表的一项：只解码映射需要的字段；`param` 必需（翻页游标），其余字段缺失时由 `model()` 决定是否丢弃。
struct UploaderVideoArchiveItemPayload: Decodable, Sendable {
    let param: String
    let goto: String?
    let bvid: String?
    let title: String?
    let cover: String?
    /// 时长是秒数（App 端空间搜索给的才是 `"MM:SS"` 字符串）。
    let duration: Int?
    let play: Int64?
    let danmaku: Int64?
    let ctime: Int64?
    let isCooperation: Bool

    private enum CodingKeys: String, CodingKey {
        case param, goto, bvid, title, cover, duration, play, danmaku, ctime
        case isCooperation = "is_cooperation"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        param = try container.decode(String.self, forKey: .param)
        goto = container.decodeLossyIfPresent(String.self, forKey: .goto)
        bvid = container.decodeLossyIfPresent(String.self, forKey: .bvid)
        title = container.decodeLossyIfPresent(String.self, forKey: .title)
        cover = container.decodeLossyIfPresent(String.self, forKey: .cover)
        duration = container.decodeLossyIfPresent(Int.self, forKey: .duration)
        play = container.decodeLossyIfPresent(FlexibleInt64.self, forKey: .play)?.value
        danmaku = container.decodeLossyIfPresent(FlexibleInt64.self, forKey: .danmaku)?.value
        ctime = container.decodeLossyIfPresent(Int64.self, forKey: .ctime)
        isCooperation = container.decodeLossyBool(forKey: .isCooperation) ?? false
    }

    /// 只收普通稿件（`goto` 为 av）且 BVID、标题与发布时间齐全的条目，其余为 nil。
    func model() -> UploaderVideo? {
        guard goto == "av", let bvid, BVID.isValid(bvid), let title, let ctime else { return nil }
        return UploaderVideo(
            bvid: bvid,
            title: RemoteHTMLText.plainText(title),
            coverURL: cover.flatMap(WebImageURL.parse),
            durationSeconds: duration.flatMap { $0 > 0 ? $0 : nil },
            viewCount: play,
            danmakuCount: danmaku,
            publishedAt: Date(timeIntervalSince1970: TimeInterval(ctime)),
            isCollaboration: isCooperation
        )
    }
}

/// UP 主空间内搜索（App 端 `/x/v2/space/search`）的 `data`，由 `BiliAPIClient` 的空间扩展映射为 `UploaderVideoBatch`。
///
/// 按页码翻页：本页有条目且前面各页加本页仍不足 `total` 时，下一批游标是下一页的页码。条目没有 BVID，`param` 是 av 号，
/// 在本地换算；只收普通稿件（`goto` 为 av）且标题与发布时间齐全的条目，逐条宽松解码。
struct UploaderVideoSearchPayload: Decodable, Sendable {
    let total: Int
    let items: [UploaderVideoSearchItemPayload]
    /// 本页原始条目数（含被丢弃的），用于判断是否还有下一页。
    let rawItemCount: Int

    private enum CodingKeys: String, CodingKey {
        case total
        case item
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        total = container.decodeLossyIfPresent(Int.self, forKey: .total) ?? 0
        // 没有结果时 `item` 缺失：按空页处理。
        let lossy =
            (try? container.decode(
                [LossyDecodable<UploaderVideoSearchItemPayload>].self,
                forKey: .item
            ))
            ?? []
        rawItemCount = lossy.count
        items = lossy.compactMap(\.value)
    }

    func model(page: Int, pageSize: Int) -> UploaderVideoBatch {
        let hasNext =
            rawItemCount > 0 && page < BiliAPIClient.uploaderVideoSearchMaximumPage
            && page * pageSize < total
        return UploaderVideoBatch(
            videos: items.compactMap { $0.model() },
            nextCursor: hasNext ? UploaderVideoCursor(value: String(page + 1)) : nil,
            totalCount: total
        )
    }
}

/// 空间内搜索结果的一项；`duration` 是 `"MM:SS"` 或 `"H:MM:SS"` 字符串（与投稿列表的秒数不同）。
struct UploaderVideoSearchItemPayload: Decodable, Sendable {
    let param: String
    let goto: String?
    let title: String?
    let cover: String?
    let duration: String?
    let play: Int64?
    let danmaku: Int64?
    let ptime: Int64?

    private enum CodingKeys: String, CodingKey {
        case param, goto, title, cover, duration, play, danmaku, ptime
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        param = try container.decode(String.self, forKey: .param)
        goto = container.decodeLossyIfPresent(String.self, forKey: .goto)
        title = container.decodeLossyIfPresent(String.self, forKey: .title)
        cover = container.decodeLossyIfPresent(String.self, forKey: .cover)
        duration = container.decodeLossyIfPresent(String.self, forKey: .duration)
        play = container.decodeLossyIfPresent(FlexibleInt64.self, forKey: .play)?.value
        danmaku = container.decodeLossyIfPresent(FlexibleInt64.self, forKey: .danmaku)?.value
        ptime = container.decodeLossyIfPresent(Int64.self, forKey: .ptime)
    }

    func model() -> UploaderVideo? {
        guard goto == "av", let aid = Int64(param), let bvid = BiliVideoAID.bvid(fromAID: aid),
            let title, let ptime
        else { return nil }
        return UploaderVideo(
            bvid: bvid,
            title: RemoteHTMLText.plainText(title),
            coverURL: cover.flatMap(WebImageURL.parse),
            durationSeconds: duration.flatMap(RemoteClockDuration.seconds),
            viewCount: play,
            danmakuCount: danmaku,
            publishedAt: Date(timeIntervalSince1970: TimeInterval(ptime)),
            // 搜索结果不标联合投稿。
            isCollaboration: false
        )
    }
}
