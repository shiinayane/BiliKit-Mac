import BiliModels

public enum DanmakuApplicationError: Error, Sendable, Equatable {
    case invalidRequest
    case requestRestricted
    case transportFailure
    case invalidResponse
    case unavailable
}

public protocol DanmakuSegmentRepository: Sendable {
    func segment(
        index: Int,
        for identity: PlaybackItemIdentity
    ) async throws -> DanmakuSegment
}

public struct DanmakuSegmentUseCase: Sendable {
    public static let maximumSegmentIndex = 10_000

    private let repository: any DanmakuSegmentRepository

    public init(repository: any DanmakuSegmentRepository) {
        self.repository = repository
    }

    public func segment(
        index: Int,
        for identity: PlaybackItemIdentity
    ) async throws -> DanmakuSegment {
        guard (1...Self.maximumSegmentIndex).contains(index),
              !identity.bvid.isEmpty,
              identity.cid > 0
        else {
            throw DanmakuApplicationError.invalidRequest
        }
        let segment = try await repository.segment(index: index, for: identity)
        guard segment.index == index else {
            throw DanmakuApplicationError.invalidResponse
        }
        return segment
    }
}
