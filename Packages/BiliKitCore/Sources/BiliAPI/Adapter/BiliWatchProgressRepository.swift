import BiliApplication

public struct BiliWatchProgressRepository: WatchProgressRepository {
    private let client: BiliAPIClient

    public init(client: BiliAPIClient) {
        self.client = client
    }

    public func report(_ progress: WatchProgressReport) async throws {
        do {
            try await client.reportWatchProgress(progress)
        } catch {
            throw BiliAPIError.domainError(
                for: error,
                fallback: WatchProgressError.unavailable,
                Self.map
            )
        }
    }

    private static func map(_ failure: BiliAPIError.Failure) -> WatchProgressError {
        switch failure {
        case .authorizationRequired:
            .authenticationRequired
        case .authenticationInvalid:
            .authenticationInvalid
        case .restricted:
            .requestRestricted
        case .authorizationUnavailable, .transport, .unexpectedHTTPStatus:
            .unavailable
        case .rejected(let code):
            .serviceRejected(code: code)
        case .invalidRequest, .unsupportedMedia, .noPlayableMedia,
            .invalidResponse:
            .invalidResponse
        }
    }
}
