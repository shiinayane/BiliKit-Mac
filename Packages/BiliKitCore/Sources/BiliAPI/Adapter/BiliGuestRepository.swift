import BiliApplication
import BiliModels

public struct BiliGuestRepository: GuestFeedRepository, GuestVideoRepository,
    RelatedVideoRepository, UploaderSignatureRepository
{
    private let client: BiliAPIClient

    public init(client: BiliAPIClient) {
        self.client = client
    }

    public func recommendations(
        after continuation: RecommendationContinuation?
    ) async throws -> RecommendationPage {
        try await mapError {
            try await client.recommendations(after: continuation)
        }
    }

    public func popular(page: Int, pageSize: Int) async throws -> PopularPage {
        try await mapError {
            try await client.popular(page: page, pageSize: pageSize)
        }
    }

    public func searchVideos(request: VideoSearchRequest) async throws -> SearchPage {
        try await mapError {
            try await client.searchVideos(request: request)
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

    public func signature(for ownerID: Int64) async throws -> String? {
        try await mapError {
            try await client.uploaderSignature(for: ownerID)
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
        } catch {
            throw BiliAPIError.domainError(
                for: error,
                fallback: GuestApplicationError.unavailable,
                Self.applicationError
            )
        }
    }

    private static func applicationError(
        _ failure: BiliAPIError.Failure
    ) -> GuestApplicationError {
        switch failure {
        case .invalidRequest:
            .invalidRequest
        case .authorizationRequired, .authenticationInvalid:
            .authenticationInvalid
        case .authorizationUnavailable:
            .authenticationUnavailable
        case .transport:
            .transportFailure
        case .unexpectedHTTPStatus:
            .unavailable
        case .restricted:
            .requestRestricted
        case .rejected(let code):
            .serviceRejected(code: code)
        case .unsupportedMedia:
            .unsupportedMedia
        case .noPlayableMedia:
            .playbackUnavailable
        case .invalidResponse:
            .invalidResponse
        }
    }
}
