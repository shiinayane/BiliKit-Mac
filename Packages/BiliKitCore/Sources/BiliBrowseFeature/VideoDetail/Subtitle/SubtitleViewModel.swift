import BiliApplication
import BiliModels
import Observation

public enum SubtitleFailure: Sendable, Equatable {
    case authenticationRequired
    case requestRestricted
    case invalidResponse
    case unavailable
}

public enum SubtitleViewState: Sendable, Equatable {
    case idle
    case loadingCatalog(PlaybackItemIdentity)
    case loadingTrack(PlaybackItemIdentity)
    case ready(PlaybackItemIdentity)
    case unavailable(PlaybackItemIdentity)
    case failed(PlaybackItemIdentity, SubtitleFailure)
}

@MainActor
@Observable
/// 拥有当前视频的字幕目录、正文、时间线订阅与跨 identity reset 顺序。
///
/// 切换视频时先让串行 reset worker 清理上一 identity，再加载下一目录；这避免 A→B→A
/// 中迟到的旧 A reset 清掉新 A。内容 generation 另行隔离切轨与网络迟到结果。
public final class SubtitleViewModel {
    private struct LoadIntent {
        let identity: PlaybackItemIdentity
        let generation: Int
    }

    public private(set) var state: SubtitleViewState = .idle
    public private(set) var tracks: [SubtitleTrack] = []
    public private(set) var selectedTrackID: String?
    public private(set) var currentCueText: String?

    @ObservationIgnored private let useCase: SubtitleUseCase
    @ObservationIgnored private let timeline: any PlaybackTimelineProviding
    @ObservationIgnored private var contentTask: Task<Void, Never>?
    @ObservationIgnored private var timelineTask: Task<Void, Never>?
    @ObservationIgnored private var resetTask: Task<Void, Never>?
    @ObservationIgnored private var pendingResetIdentity: PlaybackItemIdentity?
    @ObservationIgnored private var pendingLoadIntent: LoadIntent?
    @ObservationIgnored private var contentGeneration = 0
    @ObservationIgnored private var identity: PlaybackItemIdentity?
    @ObservationIgnored private var suspendedIdentity: PlaybackItemIdentity?
    @ObservationIgnored private var cues: [SubtitleCue] = []
    @ObservationIgnored private var latestPositionSeconds = 0.0

    public init(
        useCase: SubtitleUseCase,
        timeline: any PlaybackTimelineProviding
    ) {
        self.useCase = useCase
        self.timeline = timeline
    }

    deinit {
        contentTask?.cancel()
        timelineTask?.cancel()
        resetTask?.cancel()
    }

    /// 选择新的播放身份；目录可以预载，但默认不选择轨道，也不会请求正文。
    public func selectVideo(_ identity: PlaybackItemIdentity) {
        guard self.identity != identity else { return }
        let previousIdentity = self.identity
        suspendedIdentity = nil
        contentGeneration += 1
        let generation = contentGeneration
        contentTask?.cancel()
        timelineTask?.cancel()
        self.identity = identity
        tracks = []
        selectedTrackID = nil
        cues = []
        currentCueText = nil
        latestPositionSeconds = 0
        state = .loadingCatalog(identity)

        enqueueReset(for: previousIdentity)
        startTimeline(for: identity)
        pendingLoadIntent = LoadIntent(
            identity: identity,
            generation: generation
        )
        startPendingLoadIfReady()
    }

    /// 切换正文请求；传入 `nil` 明确关闭字幕并清空已加载 cue。
    public func selectTrack(_ trackID: String?) {
        guard let identity else { return }
        if let trackID, !tracks.contains(where: { $0.id == trackID }) {
            return
        }
        contentGeneration += 1
        let generation = contentGeneration
        contentTask?.cancel()
        contentTask = nil
        selectedTrackID = trackID
        cues = []
        currentCueText = nil

        guard let trackID else {
            state = .ready(identity)
            return
        }
        state = .loadingTrack(identity)
        contentTask = Task { [weak self] in
            await self?.loadTrack(
                trackID,
                identity: identity,
                generation: generation
            )
        }
    }

    public func retry() {
        guard let identity = identity ?? suspendedIdentity else { return }
        if self.identity == identity,
            case .failed(let failedIdentity, _) = state,
            failedIdentity == identity,
            let selectedTrackID
        {
            selectTrack(selectedTrackID)
            return
        }
        suspendedIdentity = nil
        self.identity = nil
        selectVideo(identity)
    }

    public func reset() {
        reset(preservingIdentityForRetry: false)
    }

    /// 登出时清除已授权取得的数据，但保留 identity 供重新认证后显式 retry。
    public func suspendForAuthentication() {
        reset(preservingIdentityForRetry: true)
    }

    public func waitForCurrentTask() async {
        await resetTask?.value
        await contentTask?.value
    }

    private func reset(
        preservingIdentityForRetry: Bool
    ) {
        let previousIdentity = identity
        if preservingIdentityForRetry {
            suspendedIdentity = previousIdentity ?? suspendedIdentity
        } else {
            suspendedIdentity = nil
        }
        contentGeneration += 1
        contentTask?.cancel()
        contentTask = nil
        pendingLoadIntent = nil
        timelineTask?.cancel()
        timelineTask = nil
        identity = nil
        tracks = []
        selectedTrackID = nil
        cues = []
        currentCueText = nil
        latestPositionSeconds = 0
        state = .idle

        enqueueReset(for: previousIdentity)
    }

    private func loadCatalog(
        for identity: PlaybackItemIdentity,
        generation: Int
    ) async {
        do {
            let tracks = try await useCase.tracks(for: identity)
            try Task.checkCancellation()
            guard self.identity == identity,
                contentGeneration == generation
            else { return }
            self.tracks = tracks
            guard !tracks.isEmpty else {
                state = .unavailable(identity)
                contentTask = nil
                return
            }
            state = .ready(identity)
            contentTask = nil
        } catch is CancellationError {
            return
        } catch let error as SubtitleApplicationError {
            fail(error, identity: identity, generation: generation)
        } catch {
            fail(.unavailable, identity: identity, generation: generation)
        }
    }

    private func loadTrack(
        _ trackID: String,
        identity: PlaybackItemIdentity,
        generation: Int
    ) async {
        do {
            let cues = try await useCase.cues(
                for: trackID,
                identity: identity
            )
            try Task.checkCancellation()
            guard self.identity == identity,
                selectedTrackID == trackID,
                contentGeneration == generation
            else { return }
            self.cues = cues
            updateCurrentCue(positionSeconds: latestPositionSeconds)
            state = .ready(identity)
            contentTask = nil
        } catch is CancellationError {
            return
        } catch let error as SubtitleApplicationError {
            fail(error, identity: identity, generation: generation)
        } catch {
            fail(.unavailable, identity: identity, generation: generation)
        }
    }

    private func startTimeline(for identity: PlaybackItemIdentity) {
        let updates = timeline.timelineUpdates()
        timelineTask = Task { [weak self] in
            for await snapshot in updates {
                guard !Task.isCancelled else { return }
                guard let self, self.identity == identity else { return }
                guard snapshot.identity == identity else {
                    self.currentCueText = nil
                    continue
                }
                self.latestPositionSeconds = snapshot.positionSeconds
                self.updateCurrentCue(
                    positionSeconds: snapshot.positionSeconds
                )
            }
        }
    }

    /// 合并待清理 identity，并用单一 worker 保证 reset 与下一次目录加载不会交错。
    private func enqueueReset(for identity: PlaybackItemIdentity?) {
        if let identity, pendingResetIdentity == nil {
            pendingResetIdentity = identity
        }
        guard resetTask == nil, pendingResetIdentity != nil else {
            return
        }
        let task = Task { [weak self, useCase] in
            while !Task.isCancelled {
                guard let identity = self?.takePendingReset() else {
                    self?.finishResetWorker()
                    return
                }
                await useCase.reset(for: identity)
            }
            self?.finishResetWorker()
        }
        resetTask = task
    }

    private func takePendingReset() -> PlaybackItemIdentity? {
        guard let identity = pendingResetIdentity else { return nil }
        pendingResetIdentity = nil
        return identity
    }

    private func finishResetWorker() {
        resetTask = nil
        startPendingLoadIfReady()
    }

    private func startPendingLoadIfReady() {
        guard resetTask == nil, let intent = pendingLoadIntent else {
            return
        }
        pendingLoadIntent = nil
        contentTask?.cancel()
        contentTask = Task { [weak self] in
            await self?.loadCatalog(
                for: intent.identity,
                generation: intent.generation
            )
        }
    }

    private func updateCurrentCue(positionSeconds: Double) {
        guard selectedTrackID != nil, !cues.isEmpty else {
            currentCueText = nil
            return
        }

        var lowerBound = 0
        var upperBound = cues.count
        while lowerBound < upperBound {
            let middle = lowerBound + (upperBound - lowerBound) / 2
            if cues[middle].startSeconds <= positionSeconds {
                lowerBound = middle + 1
            } else {
                upperBound = middle
            }
        }

        var index = lowerBound - 1
        while index >= 0 {
            let cue = cues[index]
            if cue.contains(positionSeconds: positionSeconds) {
                currentCueText = cue.text
                return
            }
            if cue.endSeconds <= positionSeconds {
                break
            }
            index -= 1
        }
        currentCueText = nil
    }

    private func fail(
        _ error: SubtitleApplicationError,
        identity: PlaybackItemIdentity,
        generation: Int
    ) {
        guard self.identity == identity,
            contentGeneration == generation
        else { return }
        cues = []
        currentCueText = nil
        state = .failed(identity, Self.failure(error))
        contentTask = nil
    }

    private static func failure(
        _ error: SubtitleApplicationError
    ) -> SubtitleFailure {
        switch error {
        case .authenticationRequired:
            .authenticationRequired
        case .requestRestricted:
            .requestRestricted
        case .invalidResponse:
            .invalidResponse
        case .invalidRequest, .transportFailure, .unavailable:
            .unavailable
        }
    }
}
