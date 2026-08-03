import BiliModels

public enum SubtitleApplicationError: Error, Sendable, Equatable {
    case invalidRequest
    case authenticationRequired
    case requestRestricted
    case transportFailure
    case invalidResponse
    case unavailable
}

/// 字幕目录与正文的 identity-scoped port。
///
/// `reset` 是 adapter 清除当前身份 URL 映射的生命周期操作，不是一般缓存清理。
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

/// 在 adapter 前验证字幕 identity/track 输入，同时保持取消原样传播。
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
