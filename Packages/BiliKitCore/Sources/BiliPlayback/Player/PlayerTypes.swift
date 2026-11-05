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
/// `track` 保留用户可选择的语义 identity；`representation` 是该轨码率最高的 AAC 候选，也是这条音轨在
/// 默认音频组里的版本。`additionalRepresentations` 只有原声非空：其余 AAC 档（码率从高到低）、杜比音频、
/// 允许时的无损版本，按这个顺序各成一个音频组；每组的成员与默认组相同，只把原声换成这个版本（见
/// ARCHITECTURE 的音频组一节）。
public struct SelectedPlaybackAudioTrack: Sendable, Equatable {
    public let track: PlaybackAudioTrack
    public let representation: MediaRepresentation
    public let additionalRepresentations: [MediaRepresentation]

    public init(
        track: PlaybackAudioTrack,
        representation: MediaRepresentation,
        additionalRepresentations: [MediaRepresentation] = []
    ) {
        self.track = track
        self.representation = representation
        self.additionalRepresentations = additionalRepresentations
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

    /// 每条语义音轨取其码率最高的 representation，原声再带上附加音频组的版本，并在释放旧播放项之前验证
    /// 音轨契约。
    ///
    /// 没有音轨（稿件没有声音）时返回空，交给 bridge 生成只有视频的 master。`allowsLosslessAudio` 为 false
    /// 时不带无损版本，bridge 也就不会读它的 SIDX。
    ///
    /// playurl 的 `dash.audio` 不按码率排序（首条常是 30232 而非更高的 30280），所以不能取首个。
    /// 有 `bandwidth` 的候选优先于缺失的；码率相同或都缺失时保留输入中靠前的一条，结果只由输入决定。
    func selectedAudioTracks(allowsLosslessAudio: Bool) throws -> [SelectedPlaybackAudioTrack] {
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
            let versions =
                track.representations
                + [track.dolbyRepresentation, track.losslessRepresentation].compactMap { $0 }
            for representation in versions where representation.kind != .audio {
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
                representation: representation,
                additionalRepresentations: track.role == .original
                    ? Self.additionalRepresentations(
                        of: track,
                        excluding: representation,
                        allowsLosslessAudio: allowsLosslessAudio
                    ) : []
            )
        }
    }

    /// 原声附加音频组的版本：其余 AAC 档按码率从高到低，再接杜比、允许时的无损。
    ///
    /// 缺码率的 AAC 档排最后，同码率保持输入顺序。附加版本只是更多选择，与已选版本 ID 重复的直接略过（它们的 loopback route 以 ID 命名）。
    private static func additionalRepresentations(
        of track: PlaybackAudioTrack,
        excluding selected: MediaRepresentation,
        allowsLosslessAudio: Bool
    ) -> [MediaRepresentation] {
        let otherAAC = track.representations.enumerated()
            .filter { $0.element != selected }
            .sorted { lhs, rhs in
                switch (lhs.element.bandwidth, rhs.element.bandwidth) {
                case (let left?, let right?) where left != right: left > right
                case (_?, nil): true
                case (nil, _?): false
                default: lhs.offset < rhs.offset
                }
            }
            .map(\.element)
        let candidates =
            otherAAC
            + [
                track.dolbyRepresentation,
                allowsLosslessAudio ? track.losslessRepresentation : nil
            ].compactMap { $0 }
        var usedIDs: Set<Int> = [selected.id]
        return candidates.filter { usedIDs.insert($0.id).inserted }
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
