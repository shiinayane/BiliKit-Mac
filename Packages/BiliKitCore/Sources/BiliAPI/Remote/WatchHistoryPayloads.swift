import BiliApplication
import BiliModels
import BiliNetworking
import Foundation

/// 观看历史（`/x/web-interface/history/cursor`）的 `data`，由 `BiliAPIClient.watchHistory` 映射为
/// `WatchHistoryPage`。
///
/// 只按账户读取（见 SECURITY-MODEL §3）；非稿件条目跳过，按 BVID 去重交给分页列表 `PagedVideoList`；
/// 本页条数少于每页条数或没有游标时没有下一页。
struct WatchHistoryPayload: Decodable, Sendable {
    let cursor: WatchHistoryCursorPayload?
    let list: [WatchHistoryItemPayload]

    func model(pageSize: Int) throws -> WatchHistoryPage {
        let items = try list.compactMap { try $0.model() }
        let continuation: WatchHistoryContinuation?
        if list.count >= pageSize, let cursor {
            continuation = try cursor.continuation()
        } else {
            continuation = nil
        }
        return WatchHistoryPage(items: items, continuation: continuation)
    }
}

/// 历史游标（`max`、`view_at`、`business`），与不透明的 `WatchHistoryContinuation` 互转。
///
/// continuation 是游标按键排序编码的 JSON 再 base64；解析与生成时都校验非负与 `business` ≤ 64
/// 字符：调用方传回的 continuation 不合规按无效请求失败，接口给的游标不合规按解码失败。
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

/// 历史的一条，映射为 `WatchHistoryItem`；非稿件（`business` 不是 `archive`）返回 nil。
///
/// BVID 形状、标题、作者、观看时间或时长不合规时整页失败；进度为负（接口用 -1 表示已看完）
/// 按看完处理，并截到时长以内。
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
            title: RemoteHTMLText.plainText(title),
            coverURL: WebImageURL.parse(cover),
            owner: VideoOwner(
                id: authorID,
                name: authorName,
                avatarURL: authorFace.flatMap(WebImageURL.parse)
            ),
            progressSeconds: normalizedProgress,
            durationSeconds: duration,
            viewedAt: Date(timeIntervalSince1970: TimeInterval(viewedAt)),
            device: history.device,
            firstPageCID: history.firstPageCID
        )
    }
}

/// 历史条目的 `history`：BVID、业务类型与观看设备。
struct WatchHistoryIdentityPayload: Decodable, Sendable {
    let bvid: String?
    let business: String
    /// 观看设备 `dt`；缺失或形状不对时为 nil，不影响整条历史。
    let deviceType: LossyDecodable<FlexibleInt64>?
    /// 上次看到的那一 P 的 CID 与序号（从 1 开始）。
    let cid: LossyDecodable<FlexibleInt64>?
    let page: LossyDecodable<FlexibleInt64>?

    private enum CodingKeys: String, CodingKey {
        case bvid, business, cid, page
        case deviceType = "dt"
    }

    /// 上次看到的正是第一个分 P 时，它的 CID 就是第一个分 P 的 CID；否则不作提示。
    var firstPageCID: Int64? {
        guard page?.value?.value == 1 else { return nil }
        return firstPageCIDHint(cid?.value?.value)
    }

    /// `dt`：1/3/5/7 手机端，2 网页端，4/6 平板端，33 电视端；其他取值不显示设备。
    var device: WatchHistoryDevice? {
        switch deviceType?.value?.value {
        case 1, 3, 5, 7: .phone
        case 2: .web
        case 4, 6: .pad
        case 33: .tv
        default: nil
        }
    }
}
