import BiliApplication
import BiliModels
import Foundation

private enum WebImageURL {
    static func parse(_ value: String) -> URL? {
        let normalized: String
        if value.hasPrefix("//") {
            normalized = "https:\(value)"
        } else if value.lowercased().hasPrefix("http://") {
            normalized = "https://" + value.dropFirst("http://".count)
        } else {
            normalized = value
        }
        guard let url = URL(string: normalized),
              url.scheme?.lowercased() == "https",
              url.host != nil
        else {
            return nil
        }
        return url
    }
}

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

struct PlayURLPayload: Decodable, Sendable {
    let dash: DASHPayload
}

struct DASHPayload: Decodable, Sendable {
    let video: [DASHRepresentationPayload]
    let audio: [DASHRepresentationPayload]
}

struct DASHRepresentationPayload: Decodable, Sendable {
    let id: Int
    let codecid: Int?
    let codecs: String
    let mimeType: String
    let bandwidth: Int?
    let baseURL: String
    let backupURLs: [String]
    let segmentBase: DASHSegmentBasePayload

    var isAVCVideo: Bool {
        mimeType == "video/mp4"
            && (codecid == 7 || codecs.lowercased().hasPrefix("avc1"))
    }

    var isAACAudio: Bool {
        mimeType == "audio/mp4" && codecs.lowercased().hasPrefix("mp4a")
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case codecid
        case codecs
        case mimeType = "mime_type"
        case mimeTypeCamel = "mimeType"
        case bandwidth
        case baseURL = "base_url"
        case baseURLCamel = "baseUrl"
        case backupURLs = "backup_url"
        case backupURLsCamel = "backupUrl"
        case segmentBase = "segment_base"
        case segmentBaseCamel = "SegmentBase"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        codecid = try container.decodeIfPresent(Int.self, forKey: .codecid)
        codecs = try container.decode(String.self, forKey: .codecs)
        mimeType = try container.decodeIfPresent(String.self, forKey: .mimeType)
            ?? container.decode(String.self, forKey: .mimeTypeCamel)
        bandwidth = try container.decodeIfPresent(Int.self, forKey: .bandwidth)
        baseURL = try container.decodeIfPresent(String.self, forKey: .baseURL)
            ?? container.decode(String.self, forKey: .baseURLCamel)
        backupURLs = try container.decodeIfPresent(
            [String].self,
            forKey: .backupURLs
        ) ?? container.decodeIfPresent(
            [String].self,
            forKey: .backupURLsCamel
        ) ?? []
        segmentBase = try container.decodeIfPresent(
            DASHSegmentBasePayload.self,
            forKey: .segmentBase
        ) ?? container.decode(DASHSegmentBasePayload.self, forKey: .segmentBaseCamel)
    }

    func model(kind: MediaKind) throws -> MediaRepresentation {
        var seen = Set<URL>()
        let urls = ([baseURL] + backupURLs)
            .compactMap(Self.validMediaURL)
            .filter { seen.insert($0).inserted }
        guard let primaryURL = urls.first else {
            throw BiliAPIError.invalidMediaData
        }
        return MediaRepresentation(
            id: id,
            kind: kind,
            codecs: codecs,
            mimeType: mimeType,
            bandwidth: bandwidth,
            primaryURL: primaryURL,
            backupURLs: Array(urls.dropFirst()),
            segmentBase: try segmentBase.model()
        )
    }

    private static func validMediaURL(_ value: String) -> URL? {
        guard let url = URL(string: value),
              BiliMediaURLPolicy().allows(url)
        else {
            return nil
        }
        return url
    }
}

struct DASHSegmentBasePayload: Decodable, Sendable {
    let initialization: String
    let indexRange: String

    private enum CodingKeys: String, CodingKey {
        case initialization
        case indexRange = "index_range"
        case indexRangeCamel = "indexRange"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        initialization = try container.decode(String.self, forKey: .initialization)
        indexRange = try container.decodeIfPresent(String.self, forKey: .indexRange)
            ?? container.decode(String.self, forKey: .indexRangeCamel)
    }

    func model() throws -> SegmentBase {
        do {
            return SegmentBase(
                initialization: try byteRange(initialization),
                index: try byteRange(indexRange)
            )
        } catch {
            throw BiliAPIError.invalidMediaData
        }
    }

    private func byteRange(_ value: String) throws -> MediaByteRange {
        let bounds = value.split(
            separator: "-",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        guard bounds.count == 2,
              let start = Int64(bounds[0]),
              let end = Int64(bounds[1])
        else {
            throw BiliAPIError.invalidMediaData
        }
        return try MediaByteRange(start: start, endInclusive: end)
    }
}

struct WBIImagePayload: Decodable, Sendable {
    let imageURL: String
    let subURL: String

    private enum CodingKeys: String, CodingKey {
        case imageURL = "img_url"
        case subURL = "sub_url"
    }
}

struct NavigationPayload: Decodable, Sendable {
    let wbiImage: WBIImagePayload

    private enum CodingKeys: String, CodingKey {
        case wbiImage = "wbi_img"
    }
}

struct WatchHistoryPayload: Decodable, Sendable {
    let cursor: WatchHistoryCursorPayload?
    let list: [WatchHistoryItemPayload]

    func model(pageSize: Int) throws -> WatchHistoryPage {
        var seen = Set<String>()
        let items: [WatchHistoryItem] = try list.compactMap { payload in
            guard let item = try payload.model() else { return nil }
            return seen.insert(item.bvid).inserted ? item : nil
        }
        let continuation: WatchHistoryContinuation?
        if list.count >= pageSize, let cursor {
            continuation = try cursor.continuation()
        } else {
            continuation = nil
        }
        return WatchHistoryPage(items: items, continuation: continuation)
    }
}

struct WatchHistoryCursorPayload: Codable, Sendable {
    let maximum: Int64
    let viewedAt: Int64
    let business: String

    static let initial = WatchHistoryCursorPayload(
        maximum: 0,
        viewedAt: 0,
        business: ""
    )

    private enum CodingKeys: String, CodingKey {
        case maximum = "max"
        case viewedAt = "view_at"
        case business
    }

    init(maximum: Int64, viewedAt: Int64, business: String) {
        self.maximum = maximum
        self.viewedAt = viewedAt
        self.business = business
    }

    init(_ continuation: WatchHistoryContinuation) throws {
        guard let data = Data(base64Encoded: continuation.rawValue),
              let cursor = try? JSONDecoder().decode(Self.self, from: data)
        else {
            throw BiliAPIError.invalidRequest
        }
        self = cursor
        try validate(as: .invalidRequest)
    }

    func continuation() throws -> WatchHistoryContinuation {
        try validate(as: .decodingFailed)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(self) else {
            throw BiliAPIError.decodingFailed
        }
        return WatchHistoryContinuation(rawValue: data.base64EncodedString())
    }

    private func validate(as error: BiliAPIError) throws {
        guard maximum >= 0, viewedAt >= 0, business.count <= 64 else {
            throw error
        }
    }
}

struct WatchHistoryItemPayload: Decodable, Sendable {
    let title: String
    let cover: String
    let authorName: String
    let authorFace: String?
    let authorID: Int64
    let viewedAt: Int64
    let progress: Int
    let duration: Int
    let history: WatchHistoryIdentityPayload

    private enum CodingKeys: String, CodingKey {
        case title
        case cover
        case authorName = "author_name"
        case authorFace = "author_face"
        case authorID = "author_mid"
        case viewedAt = "view_at"
        case progress
        case duration
        case history
    }

    func model() throws -> WatchHistoryItem? {
        guard history.business == "archive" else { return nil }
        guard let bvid = history.bvid,
              bvid.hasPrefix("BV"),
              bvid.count <= 24,
              bvid.dropFirst(2).allSatisfy({
                  $0.isASCII && ($0.isLetter || $0.isNumber)
              }),
              !title.isEmpty,
              !authorName.isEmpty,
              authorID >= 0,
              viewedAt > 0,
              duration >= 0
        else {
            throw BiliAPIError.decodingFailed
        }
        let normalizedProgress = progress < 0
            ? duration
            : min(progress, duration)
        return WatchHistoryItem(
            bvid: bvid,
            title: title,
            coverURL: WebImageURL.parse(cover),
            owner: VideoOwner(
                id: authorID,
                name: authorName,
                avatarURL: authorFace.flatMap(WebImageURL.parse)
            ),
            progressSeconds: normalizedProgress,
            durationSeconds: duration,
            viewedAt: Date(timeIntervalSince1970: TimeInterval(viewedAt))
        )
    }
}

struct WatchHistoryIdentityPayload: Decodable, Sendable {
    let bvid: String?
    let business: String
}

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
            videos: try result
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
        guard components.count == value.split(separator: ":").count else {
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
