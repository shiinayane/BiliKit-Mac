import BiliApplication
import BiliModels

public struct BiliDanmakuRepository: DanmakuSegmentRepository, Sendable {
    private let client: BiliAPIClient

    public init(client: BiliAPIClient) {
        self.client = client
    }

    public func segment(
        index: Int,
        for identity: PlaybackItemIdentity
    ) async throws -> DanmakuSegment {
        do {
            let data = try await client.danmakuSegmentData(
                index: index,
                for: identity
            )
            let events = try DanmakuPayloadDecoder.events(from: data)
            return DanmakuSegment(index: index, events: events)
        } catch {
            throw BiliAPIError.domainError(
                for: error,
                fallback: DanmakuApplicationError.unavailable,
                Self.map
            )
        }
    }

    /// 弹幕没有独立的“认证不可用”状态：本地授权不可用归入 `unavailable`，会话对它与服务端
    /// 不可用一样只让该分段失败关闭；只有 `authenticationInvalid` 会触发账户复核。
    private static func map(
        _ failure: BiliAPIError.Failure
    ) -> DanmakuApplicationError {
        switch failure {
        case .invalidRequest:
            .invalidRequest
        case .authenticationInvalid:
            .authenticationInvalid
        case .restricted:
            .requestRestricted
        case .transport:
            .transportFailure
        case .authorizationRequired, .authorizationUnavailable,
            .unexpectedHTTPStatus, .rejected:
            .unavailable
        case .unsupportedMedia, .noPlayableMedia, .invalidResponse:
            .invalidResponse
        }
    }
}
