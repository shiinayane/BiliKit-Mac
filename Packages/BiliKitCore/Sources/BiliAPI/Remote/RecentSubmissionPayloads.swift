import Foundation

struct RecentRankPayload: Decodable, Sendable {
    let result: [RecentRankSubmissionPayload]?
}

struct RecentRankSubmissionPayload: Decodable, Sendable {
    let bvid: String
    let duration: Int
    let senddate: Int64
    let mid: Int64
    let play: FlexibleInt64
}

struct RecentSubmissionDetailPayload: Decodable, Sendable {
    let bvid: String
    let cid: Int64
    let duration: Int
    let pubdate: Int64
    let tid: Int
    let owner: RecentOwnerPayload
}

struct RecentOwnerPayload: Decodable, Sendable {
    let mid: Int64
}

struct FlexibleInt64: Decodable, Sendable {
    let value: Int64

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Int64.self) {
            self.value = value
            return
        }
        let rawValue = try container.decode(String.self)
        value = Int64(rawValue) ?? -1
    }
}
