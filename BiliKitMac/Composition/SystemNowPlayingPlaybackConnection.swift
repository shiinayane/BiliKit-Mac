import AVFoundation
import BiliApplication
import BiliPlayback
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

extension SystemNowPlayingPlaybackConnection {
    /// 把系统媒体命令与 `defaultRate` KVO 接到窗口唯一的 `AVPlayerEngine`。
    ///
    /// 每个命令都先复核播放 identity 与 `AVPlayerItem`，旧窗口或旧条目的命令不会作用到新播放。
    static func live(engine: AVPlayerEngine) -> SystemNowPlayingPlaybackConnection {
        SystemNowPlayingPlaybackConnection(
            currentSnapshot: {
                engine.currentTimelineSnapshot
            },
            timelineUpdates: {
                engine.timelineUpdates()
            },
            currentItemIdentifier: {
                engine.player.currentItem.map(ObjectIdentifier.init)
            },
            currentDefaultPlaybackRate: {
                Double(engine.player.defaultRate)
            },
            observeDefaultPlaybackRate: { notify in
                let observation = engine.player.observe(
                    \.defaultRate,
                    options: [.new]
                ) { player, change in
                    let rate = Double(change.newValue ?? player.defaultRate)
                    Task { @MainActor in notify(rate) }
                }
                return SystemNowPlayingDefaultRateObservation {
                    observation.invalidate()
                }
            },
            perform: { command, identity, itemIdentifier in
                guard engine.currentTimelineSnapshot.identity == identity,
                    let item = engine.player.currentItem,
                    ObjectIdentifier(item) == itemIdentifier
                else { return false }
                switch command {
                case .play:
                    engine.play()
                    return true
                case .pause:
                    engine.pause()
                    return true
                case .togglePlayPause:
                    if engine.currentTimelineSnapshot.state == .playing
                        || engine.currentTimelineSnapshot.state == .buffering
                    {
                        engine.pause()
                    } else {
                        engine.play()
                    }
                    return true
                case .seek(let positionSeconds):
                    return requestSystemSeek(
                        positionSeconds,
                        engine: engine,
                        identity: identity,
                        itemIdentifier: itemIdentifier
                    )
                case .skip(let offsetSeconds):
                    let snapshot = engine.currentTimelineSnapshot
                    guard let duration = snapshot.durationSeconds,
                        let target = SystemNowPlayingSeekTarget.relative(
                            positionSeconds: snapshot.positionSeconds,
                            durationSeconds: duration,
                            offsetSeconds: offsetSeconds
                        )
                    else {
                        return false
                    }
                    return requestSystemSeek(
                        target,
                        engine: engine,
                        identity: identity,
                        itemIdentifier: itemIdentifier
                    )
                }
            }
        )
    }

    private static func requestSystemSeek(
        _ positionSeconds: Double,
        engine: AVPlayerEngine,
        identity: PlaybackItemIdentity,
        itemIdentifier: ObjectIdentifier
    ) -> Bool {
        guard positionSeconds.isFinite, positionSeconds >= 0,
            let duration = engine.currentTimelineSnapshot.durationSeconds,
            positionSeconds <= duration
        else { return false }
        guard engine.currentTimelineSnapshot.identity == identity,
            let item = engine.player.currentItem,
            ObjectIdentifier(item) == itemIdentifier
        else { return false }
        return engine.requestSeek(to: .seconds(positionSeconds))
    }
}

enum SystemNowPlayingSeekTarget {
    static func relative(
        positionSeconds: Double,
        durationSeconds: Double,
        offsetSeconds: Double
    ) -> Double? {
        guard positionSeconds.isFinite,
            durationSeconds.isFinite,
            durationSeconds > 0,
            offsetSeconds.isFinite,
            offsetSeconds != 0
        else { return nil }
        return min(max(positionSeconds + offsetSeconds, 0), durationSeconds)
    }
}
