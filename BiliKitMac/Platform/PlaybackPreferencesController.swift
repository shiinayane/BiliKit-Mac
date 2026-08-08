@preconcurrency import AVFoundation
import CoreFoundation
import Foundation

struct PlaybackPreferences: Equatable, Sendable {
    static let defaults = PlaybackPreferences(
        volume: 1,
        isMuted: false,
        preferredRate: 1
    )

    let volume: Float
    let isMuted: Bool
    let preferredRate: Float
}

protocol PlaybackPreferencesStoring: AnyObject, Sendable {
    func load() -> PlaybackPreferences
    func saveVolume(_ volume: Float)
    func saveMuted(_ isMuted: Bool)
    func savePreferredRate(_ rate: Float)
}

/// `UserDefaults` 官方保证线程安全，但当前 SDK 尚未声明其为 `Sendable`。
final class UserDefaultsPlaybackPreferencesStore:
    PlaybackPreferencesStoring, @unchecked Sendable
{
    private enum Key {
        static let volume = "player.volume"
        static let isMuted = "player.isMuted"
        static let preferredRate = "player.preferredRate"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> PlaybackPreferences {
        PlaybackPreferences(
            volume: validNumber(forKey: Key.volume, in: 0...1)
                ?? PlaybackPreferences.defaults.volume,
            isMuted: validBool(forKey: Key.isMuted)
                ?? PlaybackPreferences.defaults.isMuted,
            preferredRate: validNumber(forKey: Key.preferredRate, in: 0.25...4)
                ?? PlaybackPreferences.defaults.preferredRate
        )
    }

    func saveVolume(_ volume: Float) {
        guard volume.isFinite, (0...1).contains(volume) else { return }
        defaults.set(volume, forKey: Key.volume)
    }

    func saveMuted(_ isMuted: Bool) {
        defaults.set(isMuted, forKey: Key.isMuted)
    }

    func savePreferredRate(_ rate: Float) {
        guard rate.isFinite, (0.25...4).contains(rate) else { return }
        defaults.set(rate, forKey: Key.preferredRate)
    }

    private func validNumber(
        forKey key: String,
        in range: ClosedRange<Float>
    ) -> Float? {
        guard let number = defaults.object(forKey: key) as? NSNumber else {
            return nil
        }
        guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let value = number.floatValue
        guard value.isFinite, range.contains(value) else { return nil }
        return value
    }

    private func validBool(forKey key: String) -> Bool? {
        guard let number = defaults.object(forKey: key) as? NSNumber,
            CFGetTypeID(number) == CFBooleanGetTypeID()
        else { return nil }
        return number.boolValue
    }
}

@MainActor
/// 恢复并观察 AVPlayerView 原生控件的非内容偏好；不接触播放 identity、进度或字幕选择。
final class PlaybackPreferencesController {
    private let player: AVPlayer
    private let store: any PlaybackPreferencesStoring
    private var volumeObservation: NSKeyValueObservation?
    private var mutedObservation: NSKeyValueObservation?
    private var defaultRateObservation: NSKeyValueObservation?

    init(
        player: AVPlayer,
        store: any PlaybackPreferencesStoring = UserDefaultsPlaybackPreferencesStore()
    ) {
        self.player = player
        self.store = store

        let preferences = store.load()
        player.volume = preferences.volume
        player.isMuted = preferences.isMuted
        player.defaultRate = preferences.preferredRate

        volumeObservation = player.observe(\.volume, options: [.new]) {
            [store] _, change in
            guard let volume = change.newValue else { return }
            store.saveVolume(volume)
        }
        mutedObservation = player.observe(\.isMuted, options: [.new]) {
            [store] _, change in
            guard let isMuted = change.newValue else { return }
            store.saveMuted(isMuted)
        }
        defaultRateObservation = player.observe(\.defaultRate, options: [.new]) {
            [store] _, change in
            guard let preferredRate = change.newValue else { return }
            store.savePreferredRate(preferredRate)
        }
    }
}
