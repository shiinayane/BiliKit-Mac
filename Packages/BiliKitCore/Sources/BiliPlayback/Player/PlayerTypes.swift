@preconcurrency import AVFoundation
import BiliApplication
import BiliModels
import Foundation

public struct PlaybackRequest: Sendable, Equatable {
    public let media: PlaybackMedia
    public let mediaHeaders: [String: String]

    public init(
        media: PlaybackMedia,
        mediaHeaders: [String: String] = [:]
    ) {
        self.media = media
        self.mediaHeaders = mediaHeaders
    }
}

/// 一条语义音轨及其在本次加载中选定的媒体 representation。
///
/// `track` 保留用户可选择的语义 identity；`representation` 只能是该轨内部的一个码率候选。
public struct SelectedPlaybackAudioTrack: Sendable, Equatable {
    public let track: PlaybackAudioTrack
    public let representation: MediaRepresentation

    public init(
        track: PlaybackAudioTrack,
        representation: MediaRepresentation
    ) {
        self.track = track
        self.representation = representation
    }
}

extension PlaybackManifest {
    /// 本次加载交给 ABR 的全部视频 representation。
    func selectedVideos() throws -> [MediaRepresentation] {
        guard !videoRepresentations.isEmpty else {
            throw AVPlayerEngineError.missingVideoRepresentation
        }
        return videoRepresentations
    }

    /// 每条语义音轨取其首个 representation，并在释放旧播放项之前验证音轨契约。
    func selectedAudioTracks() throws -> [SelectedPlaybackAudioTrack] {
        guard !audioTracks.isEmpty else {
            throw AVPlayerEngineError.missingAudioRepresentation
        }
        var trackIDs = Set<String>()
        for track in audioTracks {
            guard trackIDs.insert(track.id).inserted else {
                throw AVPlayerEngineError.duplicateAudioTrackID(track.id)
            }
        }
        let defaultTracks = audioTracks.filter(\.isDefault)
        guard defaultTracks.count == 1 else {
            throw AVPlayerEngineError.invalidDefaultAudioTrackCount(
                defaultTracks.count
            )
        }

        return try audioTracks.map { track in
            for representation in track.representations
            where representation.kind != .audio {
                throw AVPlayerEngineError.invalidAudioTrackRepresentation(
                    trackID: track.id,
                    representationID: representation.id
                )
            }
            guard let representation = track.representations.first else {
                throw AVPlayerEngineError.missingAudioTrackRepresentation(
                    track.id
                )
            }
            return SelectedPlaybackAudioTrack(
                track: track,
                representation: representation
            )
        }
    }
}

enum PlaybackToggleAction: Equatable, Sendable {
    case play
    case pause

    init?(
        timeControlStatus: AVPlayer.TimeControlStatus,
        timelineState: PlaybackTimelineState
    ) {
        guard timelineState != .ended else { return nil }
        self = timeControlStatus == .paused ? .play : .pause
    }
}

struct TransportSeekOperationState: Sendable {
    struct Operation: Equatable, Sendable {
        let id: UUID
        let generation: UUID
        let itemIdentity: ObjectIdentifier
        let targetSeconds: Double
    }

    enum Completion: Equatable, Sendable {
        case ignored
        case failed
        case completed(positionSeconds: Double)
    }

    private(set) var current: Operation?

    mutating func prepare(
        offsetSeconds: Double,
        currentSeconds: Double,
        durationSeconds: Double,
        generation: UUID,
        itemIdentity: ObjectIdentifier,
        makeOperationID: () -> UUID = UUID.init
    ) -> Operation? {
        guard offsetSeconds.isFinite,
            currentSeconds.isFinite,
            currentSeconds >= 0,
            durationSeconds.isFinite,
            durationSeconds > 0
        else { return nil }
        let base =
            if let current,
                current.generation == generation,
                current.itemIdentity == itemIdentity
            {
                current.targetSeconds
            } else {
                currentSeconds
            }
        let operation = Operation(
            id: makeOperationID(),
            generation: generation,
            itemIdentity: itemIdentity,
            targetSeconds: min(max(base + offsetSeconds, 0), durationSeconds)
        )
        current = operation
        return operation
    }

    func matches(_ operation: Operation) -> Bool {
        current == operation
    }

    mutating func complete(
        _ operation: Operation,
        finished: Bool,
        resolvedPositionSeconds: Double?
    ) -> Completion {
        guard matches(operation) else { return .ignored }
        current = nil
        guard finished,
            let resolvedPositionSeconds,
            resolvedPositionSeconds.isFinite,
            resolvedPositionSeconds >= 0
        else { return .failed }
        return .completed(positionSeconds: resolvedPositionSeconds)
    }

    @discardableResult
    mutating func invalidate() -> Operation? {
        let operation = current
        current = nil
        return operation
    }
}
