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
public final class SubtitleViewModel {
    public private(set) var state: SubtitleViewState = .idle
    public private(set) var tracks: [SubtitleTrack] = []
    public private(set) var selectedTrackID: String?
    public private(set) var currentCueText: String?

    @ObservationIgnored private let useCase: SubtitleUseCase
    @ObservationIgnored private let timeline: any PlaybackTimelineProviding
    @ObservationIgnored private var contentTask: Task<Void, Never>?
    @ObservationIgnored private var timelineTask: Task<Void, Never>?
    @ObservationIgnored private var contentGeneration = 0
    @ObservationIgnored private var identity: PlaybackItemIdentity?
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
    }

    public func selectVideo(_ identity: PlaybackItemIdentity) {
        guard self.identity != identity else { return }
        let previousIdentity = self.identity
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

        if let previousIdentity {
            Task { [useCase] in
                await useCase.reset(for: previousIdentity)
            }
        }
        startTimeline(for: identity)
        contentTask = Task { [weak self] in
            await self?.loadCatalog(
                for: identity,
                generation: generation
            )
        }
    }

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
        guard let identity else { return }
        self.identity = nil
        selectVideo(identity)
    }

    public func reset() {
        let previousIdentity = identity
        contentGeneration += 1
        contentTask?.cancel()
        contentTask = nil
        timelineTask?.cancel()
        timelineTask = nil
        identity = nil
        tracks = []
        selectedTrackID = nil
        cues = []
        currentCueText = nil
        latestPositionSeconds = 0
        state = .idle

        if let previousIdentity {
            Task { [useCase] in
                await useCase.reset(for: previousIdentity)
            }
        }
    }

    public func waitForCurrentTask() async {
        await contentTask?.value
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
            guard let firstTrack = tracks.first else {
                state = .unavailable(identity)
                contentTask = nil
                return
            }
            selectedTrackID = firstTrack.id
            state = .loadingTrack(identity)
            await loadTrack(
                firstTrack.id,
                identity: identity,
                generation: generation
            )
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
