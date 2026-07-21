import BiliApplication
import BiliModels

public struct BiliGuestRepository: GuestContentRepository {
    private let service: any BiliAPIService

    public init(service: any BiliAPIService) {
        self.service = service
    }

    public func popular(page: Int, pageSize: Int) async throws -> PopularPage {
        try await mapError {
            try await service.popular(page: page, pageSize: pageSize)
        }
    }

    public func searchVideos(keyword: String, page: Int) async throws -> SearchPage {
        try await mapError {
            try await service.searchVideos(keyword: keyword, page: page)
        }
    }

    public func videoDetail(for bvid: String) async throws -> VideoDetail {
        try await mapError {
            try await service.videoDetail(for: bvid)
        }
    }

    public func pages(for bvid: String) async throws -> [VideoPage] {
        try await mapError {
            try await service.pages(for: bvid)
        }
    }

    public func playback(
        for bvid: String,
        cid: Int64,
        quality: Int
    ) async throws -> VideoPlayback {
        try await mapError {
            try await service.playback(for: bvid, cid: cid, quality: quality)
        }
    }

    private func mapError<Value: Sendable>(
        _ operation: @Sendable () async throws -> Value
    ) async throws -> Value {
        do {
            return try await operation()
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as BiliAPIError {
            throw error.applicationError
        } catch let error as GuestApplicationError {
            throw error
        } catch {
            throw GuestApplicationError.unavailable
        }
    }
}

private extension BiliAPIError {
    var applicationError: GuestApplicationError {
        switch self {
        case .invalidRequest:
            .invalidRequest
        case .transportFailure:
            .transportFailure
        case .httpStatus(403), .nonJSONResponse,
             .apiRejected(code: -403, _), .apiRejected(code: -412, _):
            .requestRestricted
        case let .apiRejected(code, _):
            .serviceRejected(code: code)
        case .noAVCVideo, .noAACAudio:
            .unsupportedMedia
        case .responseTooLarge, .decodingFailed, .missingData,
             .invalidWBIKey, .signingFailed, .invalidMediaData:
            .invalidResponse
        case .httpStatus:
            .unavailable
        }
    }
}
