import BiliApplication
import Observation

public enum GuestVideoFailure: Sendable, Equatable {
    case content(GuestApplicationError)
    case playback
}

public enum GuestVideoState: Sendable, Equatable {
    case idle
    case loading(bvid: String)
    case preparingPlayback(GuestVideoContext)
    case ready(GuestVideoContext)
    case failed(bvid: String, failure: GuestVideoFailure)
}

@MainActor
@Observable
public final class GuestVideoViewModel {
    public private(set) var state: GuestVideoState = .idle

    @ObservationIgnored private let useCase: GuestVideoUseCase
    @ObservationIgnored private let playback: any PlaybackControlling
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0

    public init(
        useCase: GuestVideoUseCase,
        playback: any PlaybackControlling
    ) {
        self.useCase = useCase
        self.playback = playback
    }

    public func loadVideo(_ bvid: String) {
        generation += 1
        let currentGeneration = generation
        loadTask?.cancel()
        if state != .idle {
            playback.stop()
        }
        state = .loading(bvid: bvid)
        loadTask = Task { [weak self] in
            await self?.performLoad(
                bvid: bvid,
                generation: currentGeneration
            )
        }
    }

    public func reset() {
        generation += 1
        loadTask?.cancel()
        loadTask = nil
        state = .idle
        playback.stop()
    }

    public func waitForCurrentTask() async {
        await loadTask?.value
    }

    func taskSnapshotForTesting() -> Task<Void, Never>? {
        loadTask
    }

    private func performLoad(
        bvid: String,
        generation currentGeneration: Int
    ) async {
        do {
            let context = try await useCase.prepareVideo(bvid: bvid)
            try Task.checkCancellation()
            guard generation == currentGeneration else { return }

            state = .preparingPlayback(context)
            try await playback.load(
                context.playback,
                identity: PlaybackItemIdentity(
                    bvid: context.detail.bvid,
                    cid: context.selectedPage.cid
                )
            )
            try Task.checkCancellation()
            guard generation == currentGeneration else { return }
            state = .ready(context)
        } catch is CancellationError {
            guard generation == currentGeneration else { return }
            state = .idle
        } catch let error as GuestApplicationError {
            guard generation == currentGeneration else { return }
            state = .failed(bvid: bvid, failure: .content(error))
        } catch {
            guard generation == currentGeneration else { return }
            state = .failed(bvid: bvid, failure: .playback)
        }

        if generation == currentGeneration {
            loadTask = nil
        }
    }
}
