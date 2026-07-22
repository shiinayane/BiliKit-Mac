import BiliApplication
import BiliModels

public struct BiliWatchHistoryRepository: WatchHistoryRepository {
    private let service: any BiliWatchHistoryService

    public init(service: any BiliWatchHistoryService) {
        self.service = service
    }

    public func watchHistory(
        after continuation: WatchHistoryContinuation?,
        pageSize: Int
    ) async throws -> WatchHistoryPage {
        do {
            return try await service.watchHistory(
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
        case let .apiRejected(code, _):
            .serviceRejected(code: code)
        case .transportFailure, .httpStatus:
            .transportFailure
        case .invalidRequest, .responseTooLarge, .decodingFailed,
             .missingData, .invalidWBIKey, .signingFailed,
             .invalidMediaData, .invalidSubtitleData,
             .untrustedSubtitleOrigin, .noAVCVideo, .noAACAudio:
            .invalidResponse
        }
    }
}
