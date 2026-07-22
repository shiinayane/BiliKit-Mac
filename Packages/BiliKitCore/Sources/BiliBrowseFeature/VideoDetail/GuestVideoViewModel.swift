import BiliApplication
import Observation

public enum GuestFlowFailure: Sendable, Equatable {
    case content(GuestApplicationError)
    case playback
}

public enum GuestSelectionState: Sendable, Equatable {
    case idle
    case loading(bvid: String)
    case preparingPlayback(GuestVideoContext)
    case ready(GuestVideoContext)
    case failed(bvid: String, failure: GuestFlowFailure)
}

@MainActor
@Observable
public final class GuestVideoViewModel {
    public private(set) var state: GuestSelectionState = .idle

    @ObservationIgnored private let useCase: GuestVideoUseCase
    @ObservationIgnored private let playback: any PlaybackControlling
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = 0

    public init(
        useCase: GuestVideoUseCase,
        playback: any PlaybackControlling
    ) {
        self.useCase = useCase
        self.playback = playback
    }

    public func selectVideo(_ bvid: String, quality: Int = 32) {
        generation += 1
        let currentGeneration = generation
        task?.cancel()
        if state != .idle {
            playback.stop()
        }
        state = .loading(bvid: bvid)
        task = Task { [weak self] in
            await self?.performSelection(
                bvid: bvid,
                quality: quality,
                generation: currentGeneration
            )
        }
    }

    public func reset() {
        generation += 1
        task?.cancel()
        task = nil
        state = .idle
        playback.stop()
    }

    public func waitForCurrentTask() async {
        await task?.value
    }

    private func performSelection(
        bvid: String,
        quality: Int,
        generation currentGeneration: Int
    ) async {
        do {
            let context = try await useCase.prepareVideo(
                bvid: bvid,
                quality: quality
            )
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
            task = nil
        }
    }
}
