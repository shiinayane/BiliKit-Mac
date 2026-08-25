import BiliApplication

public struct BiliWatchProgressRepository: WatchProgressRepository {
    private let client: BiliAPIClient

    public init(client: BiliAPIClient) {
        self.client = client
    }

    public func report(_ progress: WatchProgressReport) async throws {
        do {
            try await client.reportWatchProgress(progress)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as BiliAPIError {
            throw Self.map(error)
        } catch {
            throw WatchProgressError.unavailable
        }
    }

    private static func map(_ error: BiliAPIError) -> WatchProgressError {
        switch error {
        case .authorizationRequired:
            .authenticationRequired
        case .authenticationInvalid:
            .authenticationInvalid
        case .httpStatus(403), .httpStatus(412),
            .apiRejected(code: -403, message: _),
            .apiRejected(code: -412, message: _), .nonJSONResponse:
            .requestRestricted
        case .authorizationUnavailable, .transportFailure, .httpStatus:
            .unavailable
        case .apiRejected(let code, _):
            .serviceRejected(code: code)
        case .invalidRequest, .responseTooLarge, .decodingFailed,
            .missingData, .invalidWBIKey, .signingFailed,
            .invalidMediaData, .invalidSubtitleData,
            .untrustedSubtitleOrigin, .nonProtobufResponse,
            .invalidDanmakuData, .noAVCVideo, .noAACAudio,
            .unsupportedProgressiveMedia, .noPlayableMedia:
            .invalidResponse
        }
    }
}
