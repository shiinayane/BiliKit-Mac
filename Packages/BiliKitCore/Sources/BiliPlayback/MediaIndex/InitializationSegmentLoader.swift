import BiliModels
import BiliNetworking
import Foundation

/// init 区间超过 `InitializationSegmentLoader.maximumByteCount`，没有发请求。
enum InitializationSegmentLoaderError: Error, Sendable, Equatable {
    case initializationTooLarge
}

/// 有界读取一条 representation 的 fMP4 initialization，并用调用方给的解析器解出结果。
///
/// 只向 SIDX 成功的那个来源读取，不跨来源拼字节；区间超过上限时不发请求（见 SECURITY-MODEL §4）。
/// 正文先通过 `parse` 才被 Range client 接受，解析失败与读取失败一样抛错。不缓存结果，也不决定失败
/// 是否影响播放，由调用方决定。
struct InitializationSegmentLoader: Sendable {
    /// init 区间上限，超出时不发请求。
    ///
    /// 正常的 init 只有 `ftyp` 与 `moov`，远小于这个值；上限只用来挡住把媒体正文声明成 init 的
    /// 区间。调大只会放宽这道检查，调小可能拒掉 sample description 较大的合法 init。
    static let maximumByteCount = 2 * 1_024 * 1_024

    private let rangeClient: HTTPRangeClient

    init(rangeClient: HTTPRangeClient) {
        self.rangeClient = rangeClient
    }

    func load<Value>(
        for representation: MediaRepresentation,
        sourceURL: URL,
        headers: [String: String],
        parse: @escaping @Sendable (Data) throws -> Value
    ) async throws -> Value {
        let initialization = representation.segmentBase.initialization
        let range = try HTTPByteRange(
            start: initialization.start,
            endInclusive: initialization.endInclusive
        )
        guard range.length <= UInt64(Self.maximumByteCount) else {
            throw InitializationSegmentLoaderError.initializationTooLarge
        }
        let response = try await rangeClient.fetch(
            from: [sourceURL],
            range: range,
            headers: headers,
            validateBody: { data in
                (try? parse(data)) != nil
            }
        )
        return try parse(response.body)
    }
}
