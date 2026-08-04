import BiliApplication
import BiliModels
import Foundation

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
        let normalizedProgress =
            progress < 0
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
