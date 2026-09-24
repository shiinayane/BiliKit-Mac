@preconcurrency import AVFoundation
import BiliApplication
import BiliModels
import Foundation

public struct PlaybackRequest: Sendable, Equatable {
    public let media: PlaybackMedia
    public let preferredVideoRepresentationID: Int?
    public let preferredAudioRepresentationIDs: [String: Int]
    public let mediaHeaders: [String: String]

    public var dashManifest: PlaybackManifest? {
        guard case .dash(let manifest) = media else { return nil }
        return manifest
    }

    public init(
        media: PlaybackMedia,
        preferredVideoRepresentationID: Int? = nil,
        preferredAudioRepresentationIDs: [String: Int] = [:],
        mediaHeaders: [String: String] = [:]
    ) {
        self.media = media
        self.preferredVideoRepresentationID = preferredVideoRepresentationID
        self.preferredAudioRepresentationIDs = preferredAudioRepresentationIDs
        self.mediaHeaders = mediaHeaders
    }

    public init(
        manifest: PlaybackManifest,
        preferredVideoRepresentationID: Int? = nil,
        preferredAudioRepresentationIDs: [String: Int] = [:],
        mediaHeaders: [String: String] = [:]
    ) {
        self.init(
            media: .dash(manifest),
            preferredVideoRepresentationID: preferredVideoRepresentationID,
            preferredAudioRepresentationIDs: preferredAudioRepresentationIDs,
            mediaHeaders: mediaHeaders
        )
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

extension PlaybackRequest {
    /// 按请求偏好选出本次加载的视频 representation；没有偏好时交给 ABR 使用全部。
    func selectedVideos(in manifest: PlaybackManifest) throws -> [MediaRepresentation] {
        if let preferredID = preferredVideoRepresentationID {
            guard
                let representation = manifest.videoRepresentations.first(
                    where: { $0.id == preferredID }
                )
            else {
                throw AVPlayerEngineError.preferredVideoRepresentationNotFound(
                    preferredID
                )
            }
            return [representation]
        }
        guard !manifest.videoRepresentations.isEmpty else {
            throw AVPlayerEngineError.missingVideoRepresentation
        }
        return manifest.videoRepresentations
    }

    /// 为每条语义音轨选出一个 representation，并在释放旧播放项之前验证音轨契约。
    func selectedAudioTracks(in manifest: PlaybackManifest) throws -> [SelectedPlaybackAudioTrack] {
        guard !manifest.audioTracks.isEmpty else {
            throw AVPlayerEngineError.missingAudioRepresentation
        }
        var trackIDs = Set<String>()
        for track in manifest.audioTracks {
            guard trackIDs.insert(track.id).inserted else {
                throw AVPlayerEngineError.duplicateAudioTrackID(track.id)
            }
        }
        for trackID in preferredAudioRepresentationIDs.keys
        where !trackIDs.contains(trackID) {
            throw AVPlayerEngineError.preferredAudioTrackNotFound(trackID)
        }
        let defaultTracks = manifest.audioTracks.filter(\.isDefault)
        guard defaultTracks.count == 1 else {
            throw AVPlayerEngineError.invalidDefaultAudioTrackCount(
                defaultTracks.count
            )
        }

        return try manifest.audioTracks.map { track in
            for representation in track.representations
            where representation.kind != .audio {
                throw AVPlayerEngineError.invalidAudioTrackRepresentation(
                    trackID: track.id,
                    representationID: representation.id
                )
            }
            let representation: MediaRepresentation
            if let preferredID =
                preferredAudioRepresentationIDs[track.id]
            {
                guard
                    let preferred = track.representations.first(
                        where: { $0.id == preferredID }
                    )
                else {
                    throw
                        AVPlayerEngineError
                        .preferredAudioRepresentationNotFound(
                            trackID: track.id,
                            representationID: preferredID
                        )
                }
                representation = preferred
            } else {
                guard let first = track.representations.first else {
                    throw AVPlayerEngineError.missingAudioTrackRepresentation(
                        track.id
                    )
                }
                representation = first
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
