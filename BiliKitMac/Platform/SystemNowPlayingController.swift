@preconcurrency import AppKit
import BiliApplication
import Foundation
@preconcurrency import MediaPlayer

struct SystemNowPlayingPresentation: Equatable, Sendable {
    let title: String
    let artist: String?
    let albumTitle: String?
    let coverURL: URL?

    init(
        totalTitle: String,
        artist: String,
        partTitle: String?,
        partCount: Int,
        coverURL: URL?
    ) {
        let normalizedTotal = totalTitle.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let normalizedPart = partTitle?.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        if let normalizedPart,
            partCount > 1,
            !normalizedPart.isEmpty,
            normalizedPart != normalizedTotal
        {
            title = normalizedPart
            albumTitle = normalizedTotal
        } else {
            title = normalizedTotal
            albumTitle = nil
        }
        let normalizedArtist = artist.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        self.artist = normalizedArtist.isEmpty ? nil : normalizedArtist
        self.coverURL = coverURL
    }
}

enum SystemNowPlayingCommand: Equatable, Sendable {
    case play
    case pause
    case togglePlayPause
    case seek(positionSeconds: Double)
    case skip(offsetSeconds: Double)

    static func skip(
        interval: Double,
        direction: SystemNowPlayingSkipDirection
    ) -> SystemNowPlayingCommand? {
        guard interval.isFinite, interval > 0 else { return nil }
        return .skip(
            offsetSeconds: direction == .forward ? interval : -interval
        )
    }
}

enum SystemNowPlayingSkipDirection: Sendable {
    case forward
    case backward
}

enum SystemNowPlayingCommandResult: Equatable, Sendable {
    case success
    case noSuchContent
    case commandFailed
}

@MainActor
private struct SystemNowPlayingSession {
    let windowID: UUID
    let generation: UInt64
    let playbackIdentity: PlaybackItemIdentity
    let playerItemIdentifier: ObjectIdentifier
    let presentation: SystemNowPlayingPresentation
    let timeline: PlaybackTimelineSnapshot
    let defaultPlaybackRate: Double
    let perform:
        (
            SystemNowPlayingCommand,
            PlaybackItemIdentity,
            ObjectIdentifier
        ) -> Bool
    var selectionOrder: UInt64

    var isPlaying: Bool {
        timeline.state == .playing || timeline.state == .buffering
    }

    var isValid: Bool {
        timeline.identity == playbackIdentity
            && timeline.durationSeconds.map { $0 > 0 } == true
            && timeline.state != .idle
            && timeline.state != .loading
            && timeline.state != .failed
    }
}

private struct SystemNowPlayingPublicationIdentity: Equatable {
    let windowID: UUID
    let generation: UInt64
    let playbackIdentity: PlaybackItemIdentity
    let playerItemIdentifier: ObjectIdentifier
}

private struct SystemNowPlayingTimelineFingerprint: Equatable {
    let identity: PlaybackItemIdentity?
    let durationSeconds: Double?
    let rate: Double
    let defaultPlaybackRate: Double
    let state: PlaybackTimelineState
    let discontinuityGeneration: UInt64
}

@MainActor
protocol SystemNowPlayingCenterWriting: AnyObject {
    func publish(info: [String: Any], state: MPNowPlayingPlaybackState)
    func clear()
}

@MainActor
private final class DefaultSystemNowPlayingCenter: SystemNowPlayingCenterWriting {
    private let center: MPNowPlayingInfoCenter

    init(center: MPNowPlayingInfoCenter = .default()) {
        self.center = center
    }

    func publish(info: [String: Any], state: MPNowPlayingPlaybackState) {
        center.nowPlayingInfo = info
        center.playbackState = state
    }

    func clear() {
        center.nowPlayingInfo = nil
        center.playbackState = .stopped
    }
}

@MainActor
protocol SystemRemoteCommandManaging: AnyObject {
    var installationCount: Int { get }
    var removalCount: Int { get }
    func install(
        handler:
            @escaping @Sendable (SystemNowPlayingCommand) ->
            SystemNowPlayingCommandResult
    )
    func removeHandlers()
}

@MainActor
private final class DefaultSystemRemoteCommandManager:
    SystemRemoteCommandManaging
{
    private let center: MPRemoteCommandCenter
    private var registrations: [(command: MPRemoteCommand, token: Any)] = []
    private(set) var installationCount = 0
    private(set) var removalCount = 0

    init(center: MPRemoteCommandCenter = .shared()) {
        self.center = center
    }

    func install(
        handler:
            @escaping @Sendable (SystemNowPlayingCommand) ->
            SystemNowPlayingCommandResult
    ) {
        guard registrations.isEmpty else { return }
        installationCount += 1

        register(center.playCommand) { _ in handler(.play) }
        register(center.pauseCommand) { _ in handler(.pause) }
        register(center.togglePlayPauseCommand) { _ in
            handler(.togglePlayPause)
        }
        register(center.changePlaybackPositionCommand) { event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent,
                event.positionTime.isFinite,
                event.positionTime >= 0
            else { return .commandFailed }
            return handler(.seek(positionSeconds: event.positionTime))
        }
        center.skipForwardCommand.preferredIntervals = [15]
        register(center.skipForwardCommand) { event in
            guard let event = event as? MPSkipIntervalCommandEvent,
                let command = SystemNowPlayingCommand.skip(
                    interval: event.interval,
                    direction: .forward
                )
            else { return .commandFailed }
            return handler(command)
        }
        center.skipBackwardCommand.preferredIntervals = [15]
        register(center.skipBackwardCommand) { event in
            guard let event = event as? MPSkipIntervalCommandEvent,
                let command = SystemNowPlayingCommand.skip(
                    interval: event.interval,
                    direction: .backward
                )
            else { return .commandFailed }
            return handler(command)
        }

        center.nextTrackCommand.isEnabled = false
        center.previousTrackCommand.isEnabled = false
    }

    func removeHandlers() {
        guard !registrations.isEmpty else { return }
        removalCount += 1
        for registration in registrations {
            registration.command.removeTarget(registration.token)
        }
        registrations.removeAll()
    }

    private func register(
        _ command: MPRemoteCommand,
        handler:
            @escaping (MPRemoteCommandEvent) ->
            SystemNowPlayingCommandResult
    ) {
        command.isEnabled = true
        let token = command.addTarget { event in
            switch handler(event) {
            case .success:
                return .success
            case .noSuchContent:
                return .noSuchContent
            case .commandFailed:
                return .commandFailed
            }
        }
        registrations.append((command, token))
    }
}

private final class SystemNowPlayingArtworkImageBox: @unchecked Sendable {
    let image: CGImage

    init(_ image: CGImage) {
        self.image = image
    }
}

@MainActor
final class SystemNowPlayingController {
    private let center: any SystemNowPlayingCenterWriting
    private let remoteCommands: any SystemRemoteCommandManaging
    private let artworkLoader: (@Sendable (URL) async -> CGImage?)?
    private var sessions: [UUID: SystemNowPlayingSession] = [:]
    private var selectionClock: UInt64 = 0
    private var publishedIdentity: SystemNowPlayingPublicationIdentity?
    private var publishedFingerprint: SystemNowPlayingTimelineFingerprint?
    private var publishedArtwork: MPMediaItemArtwork?
    private var artworkTask: Task<Void, Never>?
    private var artworkPipelineOwner: NativeVideoImagePipelineOwner?
    private var isClosed = false

    init(
        center: (any SystemNowPlayingCenterWriting)? = nil,
        remoteCommands: (any SystemRemoteCommandManaging)? = nil,
        artworkLoader: (@Sendable (URL) async -> CGImage?)? = nil
    ) {
        self.center = center ?? DefaultSystemNowPlayingCenter()
        self.remoteCommands =
            remoteCommands ?? DefaultSystemRemoteCommandManager()
        self.artworkLoader = artworkLoader
        self.remoteCommands.install { [weak self] command in
            guard let self else { return .noSuchContent }
            return self.handleFromAnyThread(command)
        }
    }

    isolated deinit {
        artworkTask?.cancel()
        artworkPipelineOwner?.shutdown()
        remoteCommands.removeHandlers()
        if publishedIdentity != nil {
            center.clear()
        }
    }

    func registerWindow() -> UUID {
        UUID()
    }

    func update(
        windowID: UUID,
        generation: UInt64,
        playbackIdentity: PlaybackItemIdentity,
        playerItemIdentifier: ObjectIdentifier,
        presentation: SystemNowPlayingPresentation,
        timeline: PlaybackTimelineSnapshot,
        defaultPlaybackRate: Double,
        perform:
            @escaping (
                SystemNowPlayingCommand,
                PlaybackItemIdentity,
                ObjectIdentifier
            ) -> Bool
    ) {
        guard !isClosed else { return }
        let previous = sessions[windowID]
        var selectionOrder = previous?.selectionOrder ?? 0
        let beganPlaying =
            (timeline.state == .playing || timeline.state == .buffering)
            && previous?.isPlaying != true
        if beganPlaying {
            selectionClock &+= 1
            selectionOrder = selectionClock
        }
        let session = SystemNowPlayingSession(
            windowID: windowID,
            generation: generation,
            playbackIdentity: playbackIdentity,
            playerItemIdentifier: playerItemIdentifier,
            presentation: presentation,
            timeline: timeline,
            defaultPlaybackRate: Self.normalizedDefaultPlaybackRate(
                defaultPlaybackRate
            ),
            perform: perform,
            selectionOrder: selectionOrder
        )
        if session.isValid {
            sessions[windowID] = session
        } else {
            sessions[windowID] = nil
        }
        reconcile()
    }

    func markWindowActive(_ windowID: UUID) {
        guard var session = sessions[windowID], session.isValid else { return }
        selectionClock &+= 1
        session.selectionOrder = selectionClock
        sessions[windowID] = session
        reconcile()
    }

    func removeWindow(_ windowID: UUID) {
        sessions[windowID] = nil
        reconcile()
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        sessions.removeAll()
        clearPublishedSession()
        remoteCommands.removeHandlers()
    }

    nonisolated private func handleFromAnyThread(
        _ command: SystemNowPlayingCommand
    ) -> SystemNowPlayingCommandResult {
        if Thread.isMainThread {
            return MainActor.assumeIsolated { handle(command) }
        }
        return DispatchQueue.main.sync { handle(command) }
    }

    func handle(
        _ command: SystemNowPlayingCommand
    ) -> SystemNowPlayingCommandResult {
        guard !isClosed, var winner = winningSession() else {
            return .noSuchContent
        }
        guard commandIsValid(command, for: winner.timeline) else {
            return .noSuchContent
        }
        guard
            winner.perform(
                command,
                winner.playbackIdentity,
                winner.playerItemIdentifier
            )
        else {
            return .commandFailed
        }
        selectionClock &+= 1
        winner.selectionOrder = selectionClock
        sessions[winner.windowID] = winner
        return .success
    }

    private func commandIsValid(
        _ command: SystemNowPlayingCommand,
        for timeline: PlaybackTimelineSnapshot
    ) -> Bool {
        guard timeline.identity != nil, timeline.state != .ended else {
            return false
        }
        switch command {
        case .play, .pause, .togglePlayPause:
            return true
        case .seek(let positionSeconds):
            guard let duration = timeline.durationSeconds else { return false }
            return positionSeconds.isFinite
                && positionSeconds >= 0
                && positionSeconds <= duration
        case .skip(let offsetSeconds):
            return offsetSeconds.isFinite
                && offsetSeconds != 0
                && timeline.durationSeconds.map { $0 > 0 } == true
        }
    }

    private func winningSession() -> SystemNowPlayingSession? {
        let valid = sessions.values.filter(\.isValid)
        let playing = valid.filter(\.isPlaying)
        let candidates = playing.isEmpty ? valid : playing
        return candidates.max { lhs, rhs in
            let lhsRank = (lhs.selectionOrder, lhs.generation)
            let rhsRank = (rhs.selectionOrder, rhs.generation)
            return lhsRank < rhsRank
        }
    }

    private func reconcile() {
        guard let winner = winningSession() else {
            clearPublishedSession()
            return
        }
        let identity = SystemNowPlayingPublicationIdentity(
            windowID: winner.windowID,
            generation: winner.generation,
            playbackIdentity: winner.playbackIdentity,
            playerItemIdentifier: winner.playerItemIdentifier
        )
        let fingerprint = SystemNowPlayingTimelineFingerprint(
            identity: winner.timeline.identity,
            durationSeconds: winner.timeline.durationSeconds,
            rate: Self.effectiveRate(for: winner.timeline),
            defaultPlaybackRate: winner.defaultPlaybackRate,
            state: winner.timeline.state,
            discontinuityGeneration:
                winner.timeline.discontinuityGeneration
        )
        let identityChanged = identity != publishedIdentity
        guard identityChanged || fingerprint != publishedFingerprint else {
            return
        }
        if identityChanged {
            cancelArtworkLoad()
            publishedArtwork = nil
            publishedIdentity = identity
        }
        publishedFingerprint = fingerprint
        publish(winner)
        if identityChanged, let coverURL = winner.presentation.coverURL {
            loadArtwork(from: coverURL, for: identity)
        }
    }

    private func publish(_ session: SystemNowPlayingSession) {
        var info = Self.info(
            presentation: session.presentation,
            timeline: session.timeline,
            defaultPlaybackRate: session.defaultPlaybackRate
        )
        if let publishedArtwork {
            info[MPMediaItemPropertyArtwork] = publishedArtwork
        }
        center.publish(info: info, state: playbackState(for: session.timeline))
    }

    static func info(
        presentation: SystemNowPlayingPresentation,
        timeline: PlaybackTimelineSnapshot,
        defaultPlaybackRate: Double
    ) -> [String: Any] {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: presentation.title,
            MPNowPlayingInfoPropertyElapsedPlaybackTime:
                timeline.positionSeconds,
            MPNowPlayingInfoPropertyPlaybackRate: effectiveRate(for: timeline),
            MPNowPlayingInfoPropertyDefaultPlaybackRate:
                normalizedDefaultPlaybackRate(defaultPlaybackRate),
            MPNowPlayingInfoPropertyMediaType:
                MPNowPlayingInfoMediaType.video.rawValue,
            MPNowPlayingInfoPropertyIsLiveStream: false,
            MPNowPlayingInfoPropertyExcludeFromSuggestions: true,
        ]
        if let artist = presentation.artist {
            info[MPMediaItemPropertyArtist] = artist
        }
        if let albumTitle = presentation.albumTitle {
            info[MPMediaItemPropertyAlbumTitle] = albumTitle
        }
        if let duration = timeline.durationSeconds, duration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = duration
        }
        return info
    }

    nonisolated private static func effectiveRate(
        for timeline: PlaybackTimelineSnapshot
    ) -> Double {
        switch timeline.state {
        case .playing:
            return timeline.rate
        case .idle, .loading, .ready, .paused, .buffering, .ended, .failed:
            return 0
        }
    }

    nonisolated private static func normalizedDefaultPlaybackRate(
        _ rate: Double
    ) -> Double {
        rate.isFinite && rate > 0 ? rate : 1
    }

    private func playbackState(
        for timeline: PlaybackTimelineSnapshot
    ) -> MPNowPlayingPlaybackState {
        switch timeline.state {
        case .playing, .buffering:
            return .playing
        case .ready, .paused, .ended:
            return .paused
        case .idle, .loading, .failed:
            return .stopped
        }
    }

    private func loadArtwork(
        from url: URL,
        for identity: SystemNowPlayingPublicationIdentity
    ) {
        if let artworkLoader {
            artworkTask = Task { [weak self] in
                guard let image = await artworkLoader(url),
                    !Task.isCancelled
                else { return }
                self?.acceptArtwork(image, for: identity)
            }
            return
        }
        let owner = NativeVideoImagePipelineOwner()
        artworkPipelineOwner = owner
        artworkTask = Task { [weak self, pipeline = owner.pipeline] in
            guard let result = await pipeline.image(for: url, variant: .cover),
                !Task.isCancelled
            else { return }
            self?.acceptArtwork(result.image, for: identity)
        }
    }

    private func acceptArtwork(
        _ image: CGImage,
        for identity: SystemNowPlayingPublicationIdentity
    ) {
        guard publishedIdentity == identity else { return }
        publishedArtwork = Self.makeArtwork(from: image)
        guard let winner = winningSession(),
            publishedIdentity
                == SystemNowPlayingPublicationIdentity(
                    windowID: winner.windowID,
                    generation: winner.generation,
                    playbackIdentity: winner.playbackIdentity,
                    playerItemIdentifier: winner.playerItemIdentifier
                )
        else { return }
        publish(winner)
    }

    nonisolated private static func makeArtwork(
        from image: CGImage
    ) -> MPMediaItemArtwork {
        let box = SystemNowPlayingArtworkImageBox(image)
        let size = NSSize(width: image.width, height: image.height)
        return MPMediaItemArtwork(boundsSize: size) { _ in
            NSImage(cgImage: box.image, size: size)
        }
    }

    private func cancelArtworkLoad() {
        artworkTask?.cancel()
        artworkTask = nil
        artworkPipelineOwner?.shutdown()
        artworkPipelineOwner = nil
    }

    private func clearPublishedSession() {
        guard publishedIdentity != nil else { return }
        cancelArtworkLoad()
        publishedArtwork = nil
        publishedIdentity = nil
        publishedFingerprint = nil
        center.clear()
    }
}
