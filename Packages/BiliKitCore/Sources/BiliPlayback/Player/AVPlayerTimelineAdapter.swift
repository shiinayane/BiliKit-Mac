@preconcurrency import AVFoundation
import BiliApplication
import Foundation
import Synchronization
import os

enum MomentaryRateRestorationAction: Equatable {
    case none
    case setCurrentRate
    case resumeAtDefaultRate
}

enum MomentaryRateRestorationPolicy {
    static func action(
        timeControlStatus: AVPlayer.TimeControlStatus,
        currentRate: Float,
        momentaryRate: Float
    ) -> MomentaryRateRestorationAction {
        let stillUsesMomentaryRate =
            abs(currentRate - momentaryRate) < 0.01
        switch timeControlStatus {
        case .paused:
            return .none
        case .playing:
            return stillUsesMomentaryRate ? .setCurrentRate : .none
        case .waitingToPlayAtSpecifiedRate:
            return currentRate == 0 || stillUsesMomentaryRate
                ? .resumeAtDefaultRate : .none
        @unknown default:
            return .none
        }
    }
}

private final class PlaybackInteractionTracker: Sendable {
    private let wasObserved = Mutex(false)

    var hasObservedInteraction: Bool {
        wasObserved.withLock { $0 }
    }

    func markObserved() {
        wasObserved.withLock { $0 = true }
    }
}

@MainActor
/// 把 AVPlayer/KVO/notification 事件投影为平台无关、identity-safe 的播放时间线。
///
/// 所有 callback 都同时核对当前 `AVPlayerItem` 与 item token；observer bag 在替换、失败和
/// clear 时统一释放，避免旧 item 继续推进字幕或弹幕。
final class AVPlayerTimelineAdapter {
    private struct MomentaryRateSession {
        let id: UUID
        let item: AVPlayerItem
        let rate: Float
    }

    var onEnded: (@MainActor () -> Void)?
    var onFailed: (@MainActor () -> Void)?

    var currentSnapshot: PlaybackTimelineSnapshot {
        store.currentSnapshot
    }

    var hasObservedPlaybackInteraction: Bool {
        interactionTracker.hasObservedInteraction
    }

    private let player: AVPlayer
    private let store = PlaybackTimelineStore()
    private let observers = PlayerTimelineObserverBag()
    private var token: PlaybackTimelineItemToken?
    private var failedToken: PlaybackTimelineItemToken?
    private var momentaryRateSession: MomentaryRateSession?
    private var pendingExplicitSeekPosition: Double?
    private var interactionTracker = PlaybackInteractionTracker()

    init(player: AVPlayer) {
        self.player = player
        let initialRate = Self.validatedPlaybackRate(player.defaultRate) ?? 1
        player.defaultRate = initialRate
    }

    func updates() -> AsyncStream<PlaybackTimelineSnapshot> {
        store.updates()
    }

    func begin(identity: PlaybackItemIdentity) {
        momentaryRateSession = nil
        observers.reset()
        pendingExplicitSeekPosition = nil
        interactionTracker = PlaybackInteractionTracker()
        token = store.beginItem(identity: identity)
        failedToken = nil
    }

    /// 为当前 item 安装位置、速率、状态、结束、失败与时间跳变观察，并替换旧观察集合。
    func installObservers(for item: AVPlayerItem) {
        observers.reset()
        guard let token else { return }
        let interactionTracker = interactionTracker

        let periodicTimeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 30),
            queue: .main
        ) { [weak self, weak item] time in
            Task { @MainActor in
                guard let self, let item, self.player.currentItem === item,
                    let seconds = Self.seconds(from: time)
                else { return }
                self.store.update(
                    token: token,
                    positionSeconds: seconds,
                    rate: Double(self.player.rate)
                )
            }
        }

        let rateObservation = player.observe(\.rate, options: [.initial, .new]) {
            [weak self, weak item] player, _ in
            Task { @MainActor in
                guard let self, let item, self.player.currentItem === item else {
                    return
                }
                self.store.update(token: token, rate: Double(player.rate))
            }
        }

        let timeControlObservation = player.observe(
            \.timeControlStatus,
            options: [.new]
        ) { [weak self, weak item] player, change in
            let observedStatus = change.newValue ?? player.timeControlStatus
            if observedStatus != .paused {
                interactionTracker.markObserved()
            }
            Task { @MainActor in
                guard let self, let item, self.player.currentItem === item else {
                    return
                }
                let currentState = self.store.currentSnapshot.state
                guard currentState != .failed else { return }
                switch observedStatus {
                case .paused:
                    guard currentState != .ended,
                        currentState != .loading
                            || interactionTracker.hasObservedInteraction
                    else {
                        return
                    }
                    self.store.update(token: token, rate: 0, state: .paused)
                case .waitingToPlayAtSpecifiedRate:
                    self.store.update(
                        token: token,
                        rate: Double(player.rate),
                        state: .buffering
                    )
                case .playing:
                    self.store.update(
                        token: token,
                        rate: Double(player.rate),
                        state: .playing
                    )
                @unknown default:
                    return
                }
            }
        }

        let endNotificationObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: item,
            queue: .main
        ) { [weak self, weak item] _ in
            Task { @MainActor in
                guard let self, let item, self.player.currentItem === item else {
                    return
                }
                self.store.update(
                    token: token,
                    positionSeconds: Self.seconds(from: item.currentTime()),
                    rate: 0,
                    state: .ended
                )
                self.momentaryRateSession = nil
                self.onEnded?()
            }
        }

        let statusObservation = item.observe(
            \.status,
            options: [.new]
        ) { [weak self, weak item] observedItem, _ in
            Task { @MainActor in
                guard observedItem.status == .failed,
                    let self,
                    let item
                else { return }
                self.fail(item: item, token: token)
            }
        }

        let failureNotificationObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.failedToPlayToEndTimeNotification,
            object: item,
            queue: .main
        ) { [weak self, weak item] _ in
            Task { @MainActor in
                guard let self, let item else { return }
                self.fail(item: item, token: token)
            }
        }

        let timeJumpNotificationObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.timeJumpedNotification,
            object: item,
            queue: .main
        ) { [weak self, weak item] _ in
            Task { @MainActor in
                guard let self, let item, self.player.currentItem === item,
                    self.store.currentSnapshot.state != .loading,
                    let position = Self.seconds(from: item.currentTime())
                else { return }

                if let explicit = self.pendingExplicitSeekPosition,
                    abs(explicit - position) <= 0.25
                {
                    self.pendingExplicitSeekPosition = nil
                    return
                }
                self.pendingExplicitSeekPosition = nil
                self.store.markDiscontinuity(
                    token: token,
                    positionSeconds: position
                )
            }
        }

        observers.replace(
            player: player,
            periodicTimeObserver: periodicTimeObserver,
            rateObservation: rateObservation,
            timeControlObservation: timeControlObservation,
            statusObservation: statusObservation,
            endNotificationObserver: endNotificationObserver,
            failureNotificationObserver: failureNotificationObserver,
            timeJumpNotificationObserver: timeJumpNotificationObserver
        )
    }

    func markReady(duration: CMTime) {
        guard let token else { return }
        store.markReady(
            token: token,
            durationSeconds: Self.seconds(from: duration)
        )
    }

    func markFailed() {
        momentaryRateSession = nil
        observers.reset()
        guard let token else { return }
        failedToken = token
        store.markFailed(token: token)
    }

    func play() {
        guard let token else { return }
        let preferredRate = Self.validatedPlaybackRate(player.defaultRate) ?? 1
        player.defaultRate = preferredRate
        player.playImmediately(atRate: preferredRate)
        store.update(
            token: token,
            rate: Double(preferredRate),
            state: .playing
        )
    }

    func pause() {
        guard let token else { return }
        interactionTracker.markObserved()
        momentaryRateSession = nil
        player.pause()
        store.update(token: token, rate: 0, state: .paused)
    }

    func setRate(_ rate: Double) throws {
        guard rate.isFinite, (0.25...4).contains(rate) else {
            throw AVPlayerEngineError.invalidPlaybackRate
        }
        momentaryRateSession = nil
        player.defaultRate = Float(rate)
        guard player.rate > 0, let token else { return }
        player.rate = Float(rate)
        store.update(token: token, rate: rate, state: .playing)
    }

    func beginMomentaryRate(_ rate: Double) throws -> UUID? {
        guard rate.isFinite, (0.25...4).contains(rate) else {
            throw AVPlayerEngineError.invalidPlaybackRate
        }
        guard let token,
            let item = player.currentItem,
            player.rate > 0
        else {
            return nil
        }

        let session = MomentaryRateSession(
            id: UUID(),
            item: item,
            rate: Float(rate)
        )
        momentaryRateSession = session
        player.rate = session.rate
        store.update(token: token, rate: rate, state: .playing)
        return session.id
    }

    func endMomentaryRate(sessionID: UUID) {
        guard let session = momentaryRateSession,
            session.id == sessionID
        else {
            return
        }
        momentaryRateSession = nil

        guard player.currentItem === session.item, let token
        else {
            return
        }
        let restorationAction = MomentaryRateRestorationPolicy.action(
            timeControlStatus: player.timeControlStatus,
            currentRate: player.rate,
            momentaryRate: session.rate
        )
        switch restorationAction {
        case .none:
            return
        case .setCurrentRate:
            player.rate = player.defaultRate
        case .resumeAtDefaultRate:
            player.play()
        }
        let restoredState: PlaybackTimelineState =
            player.timeControlStatus == .playing ? .playing : .buffering
        store.update(
            token: token,
            rate: Double(player.defaultRate),
            state: restoredState
        )
    }

    func prepareExplicitSeek(to positionSeconds: Double) {
        interactionTracker.markObserved()
        pendingExplicitSeekPosition = positionSeconds
    }

    func explicitSeekFailed() {
        pendingExplicitSeekPosition = nil
    }

    func explicitSeekCompleted(at positionSeconds: Double) {
        guard let token else { return }
        store.markDiscontinuity(
            token: token,
            positionSeconds: positionSeconds
        )
    }

    func clear() {
        momentaryRateSession = nil
        observers.reset()
        pendingExplicitSeekPosition = nil
        store.clear(token: token)
        token = nil
        failedToken = nil
    }

    private func fail(
        item: AVPlayerItem,
        token: PlaybackTimelineItemToken
    ) {
        guard player.currentItem === item,
            self.token == token,
            failedToken != token,
            store.currentSnapshot.state != .loading
        else { return }

        failedToken = token
        momentaryRateSession = nil
        observers.reset()
        store.markFailed(token: token)
        onFailed?()
    }

    private static func seconds(from time: CMTime) -> Double? {
        let seconds = CMTimeGetSeconds(time)
        guard seconds.isFinite, seconds >= 0 else { return nil }
        return seconds
    }

    private static func validatedPlaybackRate(_ rate: Float) -> Float? {
        guard rate.isFinite, (0.25...4).contains(rate) else { return nil }
        return rate
    }
}

private final class PlayerTimelineObserverBag: Sendable {
    private struct Storage {
        var player: AVPlayer? = nil
        var periodicTimeObserver: Any? = nil
        var rateObservation: NSKeyValueObservation? = nil
        var timeControlObservation: NSKeyValueObservation? = nil
        var statusObservation: NSKeyValueObservation? = nil
        var endNotificationObserver: NSObjectProtocol? = nil
        var failureNotificationObserver: NSObjectProtocol? = nil
        var timeJumpNotificationObserver: NSObjectProtocol? = nil
    }

    private let storage = OSAllocatedUnfairLock(uncheckedState: Storage())

    deinit {
        reset()
    }

    func replace(
        player: AVPlayer,
        periodicTimeObserver: Any,
        rateObservation: NSKeyValueObservation,
        timeControlObservation: NSKeyValueObservation,
        statusObservation: NSKeyValueObservation,
        endNotificationObserver: NSObjectProtocol,
        failureNotificationObserver: NSObjectProtocol,
        timeJumpNotificationObserver: NSObjectProtocol
    ) {
        let previous = storage.withLockUnchecked { storage -> Storage in
            let previous = storage
            storage = Storage(
                player: player,
                periodicTimeObserver: periodicTimeObserver,
                rateObservation: rateObservation,
                timeControlObservation: timeControlObservation,
                statusObservation: statusObservation,
                endNotificationObserver: endNotificationObserver,
                failureNotificationObserver: failureNotificationObserver,
                timeJumpNotificationObserver: timeJumpNotificationObserver
            )
            return previous
        }
        Self.remove(previous)
    }

    func reset() {
        let previous = storage.withLockUnchecked { storage -> Storage in
            let previous = storage
            storage = Storage()
            return previous
        }
        Self.remove(previous)
    }

    private static func remove(_ storage: Storage) {
        if let player = storage.player,
            let periodicTimeObserver = storage.periodicTimeObserver
        {
            player.removeTimeObserver(periodicTimeObserver)
        }
        storage.rateObservation?.invalidate()
        storage.timeControlObservation?.invalidate()
        storage.statusObservation?.invalidate()
        if let endNotificationObserver = storage.endNotificationObserver {
            NotificationCenter.default.removeObserver(endNotificationObserver)
        }
        if let failureNotificationObserver = storage.failureNotificationObserver {
            NotificationCenter.default.removeObserver(failureNotificationObserver)
        }
        if let timeJumpNotificationObserver = storage.timeJumpNotificationObserver {
            NotificationCenter.default.removeObserver(timeJumpNotificationObserver)
        }
    }
}
