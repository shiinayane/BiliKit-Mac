@preconcurrency import AVFoundation
import BiliApplication
import BiliModels
import Foundation

/// 一次 load 的输入：媒体（DASH 或 progressive）、媒体请求 header 与起播位置。
public struct PlaybackRequest: Sendable, Equatable {
    public let media: PlaybackMedia
    public let mediaHeaders: [String: String]
    /// DASH 起播位置，item 就绪时即位于该处。
    ///
    /// 写入 master playlist 的 `EXT-X-START`；progressive 单文件没有 playlist，忽略此值、从头播放。
    public let startPositionSeconds: Double?

    public init(
        media: PlaybackMedia,
        mediaHeaders: [String: String] = [:],
        startPositionSeconds: Double? = nil
    ) {
        self.media = media
        self.mediaHeaders = mediaHeaders
        self.startPositionSeconds = startPositionSeconds
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

    /// 每条语义音轨取其码率最高的 representation，并在释放旧播放项之前验证音轨契约。
    ///
    /// 没有音轨（稿件没有声音）时返回空，交给 bridge 生成只有视频的 master。
    ///
    /// playurl 的 `dash.audio` 不按码率排序（首条常是 30232 而非更高的 30280），所以不能取首个。
    /// 有 `bandwidth` 的候选优先于缺失的；码率相同或都缺失时保留输入中靠前的一条，结果只由输入决定。
    func selectedAudioTracks() throws -> [SelectedPlaybackAudioTrack] {
        guard !audioTracks.isEmpty else { return [] }
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
            guard
                let representation = track.representations.reduce(
                    nil,
                    Self.preferredAudioRepresentation
                )
            else {
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

    /// 两条候选中保留码率更高者；只有严格更高才替换，相同码率或都缺失时保留先出现的 `current`。
    private static func preferredAudioRepresentation(
        _ current: MediaRepresentation?,
        _ candidate: MediaRepresentation
    ) -> MediaRepresentation? {
        guard let current else { return candidate }
        switch (current.bandwidth, candidate.bandwidth) {
        case (let currentBandwidth?, let candidateBandwidth?):
            return candidateBandwidth > currentBandwidth ? candidate : current
        case (nil, _?):
            return candidate
        case (_, nil):
            return current
        }
    }
}

/// `togglePlayback` 的动作：已结束时不切换；`paused` 时播放，播放中或等待播放时暂停。
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

/// transport 相对跳转的累加状态，由 `AVPlayerEngine` 持有。
///
/// 连续跳转在上一次尚未落地的目标上累加，而不是在还没更新的当前位置上；只有同一 load generation、
/// 同一 item 时才累加，否则从当前位置算起。完成回调经 `matches` 比对，已被新跳转取代或
/// `invalidate` 的操作得到 `.ignored`。
struct TransportSeekOperationState: Sendable {
    /// 一次跳转：操作 ID、发起时的 load generation 与 item identity，以及截在 0 到时长之间的目标。
    struct Operation: Equatable, Sendable {
        let id: UUID
        let generation: UUID
        let itemIdentity: ObjectIdentifier
        let targetSeconds: Double
    }

    /// 收尾结论：已被取代（`ignored`）、未完成或落点无效（`failed`），或落在某处（`completed`）。
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
        itemIdentity: ObjectIdentifier
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
            id: UUID(),
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
