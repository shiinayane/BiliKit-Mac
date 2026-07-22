import BiliModels

public enum SubtitleApplicationError: Error, Sendable, Equatable {
    case invalidRequest
    case authenticationRequired
    case requestRestricted
    case transportFailure
    case invalidResponse
    case unavailable
}

public protocol SubtitleRepository: Sendable {
    func tracks(
        for identity: PlaybackItemIdentity
    ) async throws -> [SubtitleTrack]

    func cues(
        for trackID: String,
        identity: PlaybackItemIdentity
    ) async throws -> [SubtitleCue]

    func reset(for identity: PlaybackItemIdentity) async
}

public struct SubtitleUseCase: Sendable {
    private let repository: any SubtitleRepository

    public init(repository: any SubtitleRepository) {
        self.repository = repository
    }

    public func tracks(
        for identity: PlaybackItemIdentity
    ) async throws -> [SubtitleTrack] {
        guard !identity.bvid.isEmpty, identity.cid > 0 else {
            throw SubtitleApplicationError.invalidRequest
        }
        return try await repository.tracks(for: identity)
    }

    public func cues(
        for trackID: String,
        identity: PlaybackItemIdentity
    ) async throws -> [SubtitleCue] {
        guard !trackID.isEmpty, !identity.bvid.isEmpty, identity.cid > 0 else {
            throw SubtitleApplicationError.invalidRequest
        }
        return try await repository.cues(
            for: trackID,
            identity: identity
        )
    }

    public func reset(for identity: PlaybackItemIdentity) async {
        await repository.reset(for: identity)
    }
}
