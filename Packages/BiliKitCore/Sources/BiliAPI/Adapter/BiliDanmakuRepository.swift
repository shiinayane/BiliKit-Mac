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
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as BiliAPIError {
            throw Self.map(error)
        } catch {
            throw DanmakuApplicationError.unavailable
        }
    }

    private static func map(
        _ error: BiliAPIError
    ) -> DanmakuApplicationError {
        switch error {
        case .invalidRequest:
            .invalidRequest
        case .transportFailure:
            .transportFailure
        case .httpStatus(403), .nonProtobufResponse,
             .apiRejected(code: -403, _), .apiRejected(code: -412, _):
            .requestRestricted
        case .responseTooLarge, .decodingFailed, .missingData,
             .invalidDanmakuData:
            .invalidResponse
        case .httpStatus, .apiRejected:
            .unavailable
        case .authorizationRequired, .nonJSONResponse, .invalidWBIKey,
             .signingFailed, .invalidMediaData, .invalidSubtitleData,
             .untrustedSubtitleOrigin, .noAVCVideo, .noAACAudio:
            .invalidResponse
        }
    }
}
