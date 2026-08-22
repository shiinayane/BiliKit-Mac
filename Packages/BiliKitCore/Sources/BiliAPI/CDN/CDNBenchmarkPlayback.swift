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

struct CDNBenchmarkDASHPayload: Decodable, Sendable {
    let video: [DASHRepresentationPayload]
}
