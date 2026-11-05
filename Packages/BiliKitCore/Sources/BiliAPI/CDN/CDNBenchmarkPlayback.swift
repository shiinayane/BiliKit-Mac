import BiliModels
import Foundation

/// 已认证测速发现所需的最小 playurl 投影；不包含音频、断点或账户字段。
struct CDNBenchmarkPlayback: Sendable, Equatable {
    let videoRepresentations: [MediaRepresentation]
    let mediaHeaders: [String: String]
}

/// playurl 的测速专用解码边界；未声明的音频、语言与断点字段不会被读取。
struct CDNBenchmarkPlayURLPayload: Decodable, Sendable {
    let dash: CDNBenchmarkDASHPayload
}

/// 测速只读的 `dash.video` 列表；音频等字段不声明、不解码。
///
/// 与播放一样逐条宽松解码，形状不认识的档位只丢这一条。
struct CDNBenchmarkDASHPayload: Decodable, Sendable {
    let video: [DASHRepresentationPayload]

    private enum CodingKeys: String, CodingKey {
        case video
    }

    init(from decoder: any Decoder) throws {
        video = try decoder.container(keyedBy: CodingKeys.self).decodeLossyElements(
            DASHRepresentationPayload.self,
            forKey: .video
        )
    }
}
