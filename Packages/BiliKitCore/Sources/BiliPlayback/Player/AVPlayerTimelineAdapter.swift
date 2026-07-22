@preconcurrency import AVFoundation
import BiliApplication
import Foundation
import os

@MainActor
final class AVPlayerTimelineAdapter {
    var onEnded: (@MainActor () -> Void)?

    var currentSnapshot: PlaybackTimelineSnapshot {
        store.currentSnapshot
    }

    private let player: AVPlayer
    private let store = PlaybackTimelineStore()
    private let observers = PlayerTimelineObserverBag()
    private var token: PlaybackTimelineItemToken?
    private var preferredPlaybackRate: Float = 1
    private var pendingExplicitSeekPosition: Double?

    init(player: AVPlayer) {
        self.player = player
    }

    func updates() -> AsyncStream<PlaybackTimelineSnapshot> {
        store.updates()
    }

    func begin(identity: PlaybackItemIdentity) {
        observers.reset()
        pendingExplicitSeekPosition = nil
        token = store.beginItem(identity: identity)
    }

    func installObservers(for item: AVPlayerItem) {
        observers.reset()
        guard let token else { return }

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
                if player.rate > 0 {
                    self.preferredPlaybackRate = player.rate
                }
                self.store.update(token: token, rate: Double(player.rate))
            }
        }

        let timeControlObservation = player.observe(
            \.timeControlStatus,
            options: [.initial, .new]
        ) { [weak self, weak item] player, _ in
            Task { @MainActor in
                guard let self, let item, self.player.currentItem === item else {
                    return
                }
                let currentState = self.store.currentSnapshot.state
                switch player.timeControlStatus {
                case .paused:
                    guard currentState != .loading, currentState != .ended else {
                        return
                    }
                    self.store.update(token: token, rate: 0, state: .paused)
                case .waitingToPlayAtSpecifiedRate:
                    guard currentState != .loading else { return }
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
                self.onEnded?()
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
                   abs(explicit - position) <= 0.25 {
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
            endNotificationObserver: endNotificationObserver,
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
        observers.reset()
        guard let token else { return }
        store.markFailed(token: token)
    }

    func play() {
        guard let token else { return }
        player.playImmediately(atRate: preferredPlaybackRate)
        store.update(
            token: token,
            rate: Double(preferredPlaybackRate),
            state: .playing
        )
    }

    func pause() {
        guard let token else { return }
        player.pause()
        store.update(token: token, rate: 0, state: .paused)
    }

    func setRate(_ rate: Double) throws {
        guard rate.isFinite, (0.25...4).contains(rate) else {
            throw AVPlayerEngineError.invalidPlaybackRate
        }
        preferredPlaybackRate = Float(rate)
        guard player.rate > 0, let token else { return }
        player.rate = preferredPlaybackRate
        store.update(token: token, rate: rate, state: .playing)
    }

    func prepareExplicitSeek(to positionSeconds: Double) {
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
        observers.reset()
        pendingExplicitSeekPosition = nil
        store.clear(token: token)
        token = nil
    }

    private static func seconds(from time: CMTime) -> Double? {
        let seconds = CMTimeGetSeconds(time)
        guard seconds.isFinite, seconds >= 0 else { return nil }
        return seconds
    }
}

private final class PlayerTimelineObserverBag: Sendable {
    private struct Storage {
        var player: AVPlayer? = nil
        var periodicTimeObserver: Any? = nil
        var rateObservation: NSKeyValueObservation? = nil
        var timeControlObservation: NSKeyValueObservation? = nil
        var endNotificationObserver: NSObjectProtocol? = nil
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
        endNotificationObserver: NSObjectProtocol,
        timeJumpNotificationObserver: NSObjectProtocol
    ) {
        let previous = storage.withLockUnchecked { storage -> Storage in
            let previous = storage
            storage = Storage(
                player: player,
                periodicTimeObserver: periodicTimeObserver,
                rateObservation: rateObservation,
                timeControlObservation: timeControlObservation,
                endNotificationObserver: endNotificationObserver,
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
           let periodicTimeObserver = storage.periodicTimeObserver {
            player.removeTimeObserver(periodicTimeObserver)
        }
        storage.rateObservation?.invalidate()
        storage.timeControlObservation?.invalidate()
        if let endNotificationObserver = storage.endNotificationObserver {
            NotificationCenter.default.removeObserver(endNotificationObserver)
        }
        if let timeJumpNotificationObserver = storage.timeJumpNotificationObserver {
            NotificationCenter.default.removeObserver(timeJumpNotificationObserver)
        }
    }
}
