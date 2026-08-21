import BiliApplication
import BiliBrowseFeature
import BiliModels
import Foundation

@MainActor
final class SystemNowPlayingDefaultRateObservation {
    private var cancellation: (() -> Void)?

    init(cancellation: @escaping () -> Void) {
        self.cancellation = cancellation
    }

    isolated deinit {
        cancellation?()
    }

    func cancel() {
        cancellation?()
        cancellation = nil
    }
}

@MainActor
struct SystemNowPlayingPlaybackConnection {
    let currentSnapshot: () -> PlaybackTimelineSnapshot
    let timelineUpdates: () -> AsyncStream<PlaybackTimelineSnapshot>
    let currentItemIdentifier: () -> ObjectIdentifier?
    let currentDefaultPlaybackRate: () -> Double
    let observeDefaultPlaybackRate:
        (@escaping @MainActor @Sendable (Double) -> Void) ->
            SystemNowPlayingDefaultRateObservation
    let perform:
        (
            SystemNowPlayingCommand,
            PlaybackItemIdentity,
            ObjectIdentifier
        ) -> Bool
}

@MainActor
final class SystemNowPlayingWindowCoordinator {
    private let controller: SystemNowPlayingController
    private let connection: SystemNowPlayingPlaybackConnection
    private let videoModel: GuestVideoViewModel
    private let windowID: UUID
    private var observationTask: Task<Void, Never>?
    private var defaultRateObservation: SystemNowPlayingDefaultRateObservation?
    private var generation: UInt64 = 0
    private var sourceIdentity: SystemNowPlayingSourceIdentity?
    private var isClosed = false

    init(
        controller: SystemNowPlayingController,
        connection: SystemNowPlayingPlaybackConnection,
        videoModel: GuestVideoViewModel
    ) {
        self.controller = controller
        self.connection = connection
        self.videoModel = videoModel
        windowID = controller.registerWindow()
    }

    isolated deinit {
        observationTask?.cancel()
        defaultRateObservation?.cancel()
        controller.removeWindow(windowID)
    }

    func start() {
        guard observationTask == nil, !isClosed else { return }
        synchronize(with: connection.currentSnapshot())
        observationTask = Task { [weak self, connection] in
            for await snapshot in connection.timelineUpdates() {
                guard !Task.isCancelled else { return }
                self?.synchronize(with: snapshot)
            }
        }
        defaultRateObservation = connection.observeDefaultPlaybackRate {
            [weak self] _ in
            guard let self, !self.isClosed else { return }
            self.synchronize(with: self.connection.currentSnapshot())
        }
        observePresentation()
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        observationTask?.cancel()
        observationTask = nil
        defaultRateObservation?.cancel()
        defaultRateObservation = nil
        controller.removeWindow(windowID)
    }

    func markWindowActive() {
        controller.markWindowActive(windowID)
    }

    private func observePresentation() {
        guard !isClosed else { return }
        withObservationTracking {
            _ = videoModel.presentedContext
            _ = videoModel.presentedPlaybackIdentity
            _ = videoModel.state
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, !self.isClosed else { return }
                self.synchronize(with: self.connection.currentSnapshot())
                self.observePresentation()
            }
        }
    }

    private func synchronize(with timeline: PlaybackTimelineSnapshot) {
        guard let context = videoModel.presentedContext,
            let identity = videoModel.presentedPlaybackIdentity,
            timeline.identity == identity,
            context.detail.bvid == identity.bvid,
            context.selectedPage.cid == identity.cid,
            let itemIdentifier = connection.currentItemIdentifier()
        else {
            controller.removeWindow(windowID)
            sourceIdentity = nil
            return
        }
        let nextSourceIdentity = SystemNowPlayingSourceIdentity(
            playbackIdentity: identity,
            playerItemIdentifier: itemIdentifier
        )
        if nextSourceIdentity != sourceIdentity {
            generation &+= 1
            sourceIdentity = nextSourceIdentity
        }
        controller.update(
            windowID: windowID,
            generation: generation,
            playbackIdentity: identity,
            playerItemIdentifier: itemIdentifier,
            presentation: SystemNowPlayingPresentation(
                totalTitle: context.detail.title,
                artist: context.detail.owner.name,
                partTitle: context.selectedPage.title,
                partCount: context.pages.count,
                coverURL: context.detail.coverURL
            ),
            timeline: timeline,
            defaultPlaybackRate: connection.currentDefaultPlaybackRate(),
            perform: connection.perform
        )
    }
}

private struct SystemNowPlayingSourceIdentity: Equatable {
    let playbackIdentity: PlaybackItemIdentity
    let playerItemIdentifier: ObjectIdentifier
}
