import BiliApplication
import BiliModels

public struct BiliGuestRepository: GuestContentRepository, RelatedVideoRepository {
    private let client: BiliAPIClient

    public init(client: BiliAPIClient) {
        self.client = client
    }

    public func popular(page: Int, pageSize: Int) async throws -> PopularPage {
        try await mapError {
            try await client.popular(page: page, pageSize: pageSize)
        }
    }

    public func searchVideos(keyword: String, page: Int) async throws -> SearchPage {
        try await mapError {
            try await client.searchVideos(keyword: keyword, page: page)
        }
    }

    public func videoDetail(for bvid: String) async throws -> VideoDetail {
        try await mapError {
            try await client.videoDetail(for: bvid)
        }
    }

    public func pages(for bvid: String) async throws -> [VideoPage] {
        try await mapError {
            try await client.pages(for: bvid)
        }
    }

    public func relatedVideos(to bvid: String) async throws -> [RelatedVideo] {
        try await mapError {
            try await client.relatedVideos(to: bvid)
        }
    }

    public func playback(
        for bvid: String,
        cid: Int64
    ) async throws -> VideoPlayback {
        try await mapError {
            try await client.playback(for: bvid, cid: cid)
        }
    }

    public func playback(
        for bvid: String,
        cid: Int64,
        quality: Int
    ) async throws -> VideoPlayback {
        try await mapError {
            try await client.playback(
                for: bvid,
                cid: cid,
                quality: quality
            )
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

extension BiliAPIError {
    fileprivate var applicationError: GuestApplicationError {
        switch self {
        case .invalidRequest:
            .invalidRequest
        case .authorizationRequired, .authenticationInvalid:
            .authenticationInvalid
        case .authorizationUnavailable:
            .authenticationUnavailable
        case .transportFailure:
            .transportFailure
        case .httpStatus(403), .httpStatus(412), .nonJSONResponse,
            .apiRejected(code: -403, _), .apiRejected(code: -412, _):
            .requestRestricted
        case .apiRejected(let code, _):
            .serviceRejected(code: code)
        case .noAVCVideo, .noAACAudio:
            .unsupportedMedia
        case .responseTooLarge, .decodingFailed, .missingData,
            .invalidWBIKey, .signingFailed, .invalidMediaData,
            .invalidSubtitleData, .untrustedSubtitleOrigin,
            .nonProtobufResponse, .invalidDanmakuData:
            .invalidResponse
        case .httpStatus:
            .unavailable
        }
    }
}
