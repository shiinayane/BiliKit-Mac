import BiliApplication
import BiliModels

public struct BiliWatchHistoryRepository: WatchHistoryRepository {
    private let client: BiliAPIClient

    public init(client: BiliAPIClient) {
        self.client = client
    }

    public func watchHistory(
        after continuation: WatchHistoryContinuation?,
        pageSize: Int
    ) async throws -> WatchHistoryPage {
        do {
            return try await client.watchHistory(
                after: continuation,
                pageSize: pageSize
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as BiliAPIError {
            throw Self.map(error)
        } catch {
            throw WatchHistoryError.transportFailure
        }
    }

    private static func map(_ error: BiliAPIError) -> WatchHistoryError {
        switch error {
        case .authorizationRequired,
            .apiRejected(code: -101, message: _):
            .authenticationRequired
        case .apiRejected(code: -412, message: _),
            .apiRejected(code: -403, message: _),
            .nonJSONResponse:
            .requestRestricted
        case .apiRejected(let code, _):
            .serviceRejected(code: code)
        case .transportFailure, .httpStatus:
            .transportFailure
        case .invalidRequest, .responseTooLarge, .decodingFailed,
            .missingData, .invalidWBIKey, .signingFailed,
            .invalidMediaData, .invalidSubtitleData,
            .untrustedSubtitleOrigin, .nonProtobufResponse,
            .invalidDanmakuData, .noAVCVideo, .noAACAudio:
            .invalidResponse
        }
    }
}
