@preconcurrency import AVFoundation
import BiliApplication
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

struct DanmakuPreferences: Equatable, Sendable {
    static let defaults = DanmakuPreferences(
        speedLevel: .three,
        opacity: .fullyOpaque,
        displayArea: .full,
        density: .normal
    )

    let speedLevel: DanmakuSpeedLevel
    let opacity: DanmakuOpacity
    let displayArea: DanmakuDisplayArea
    let density: DanmakuDensity
}

protocol DanmakuPreferencesStoring: AnyObject, Sendable {
    func load() -> DanmakuPreferences
    func saveSpeedLevel(_ speedLevel: DanmakuSpeedLevel)
    func saveOpacity(_ opacity: DanmakuOpacity)
    func saveDisplayArea(_ displayArea: DanmakuDisplayArea)
    func saveDensity(_ density: DanmakuDensity)
}

/// 只保存设备级弹幕显示意图，不保存视频 identity、正文或播放位置。
final class UserDefaultsDanmakuPreferencesStore:
    DanmakuPreferencesStoring, @unchecked Sendable
{
    private enum Key {
        static let speedLevel = "danmaku.speedLevel"
        static let opacity = "danmaku.opacity"
        static let displayArea = "danmaku.displayArea"
        static let density = "danmaku.density"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> DanmakuPreferences {
        DanmakuPreferences(
            speedLevel: loadSpeedLevel(),
            opacity: loadOpacity(),
            displayArea: loadDisplayArea(),
            density: loadDensity()
        )
    }

    func saveSpeedLevel(_ speedLevel: DanmakuSpeedLevel) {
        defaults.set(speedLevel.rawValue, forKey: Key.speedLevel)
    }

    func saveOpacity(_ opacity: DanmakuOpacity) {
        defaults.set(opacity.value, forKey: Key.opacity)
    }

    func saveDisplayArea(_ displayArea: DanmakuDisplayArea) {
        defaults.set(displayArea.rawValue, forKey: Key.displayArea)
    }

    func saveDensity(_ density: DanmakuDensity) {
        defaults.set(density.rawValue, forKey: Key.density)
    }

    private func loadSpeedLevel() -> DanmakuSpeedLevel {
        guard let number = defaults.object(forKey: Key.speedLevel) as? NSNumber,
            CFGetTypeID(number) != CFBooleanGetTypeID()
        else {
            return DanmakuPreferences.defaults.speedLevel
        }
        let rawValue = number.intValue
        guard number.doubleValue == Double(rawValue),
            let speedLevel = DanmakuSpeedLevel(rawValue: rawValue)
        else {
            return DanmakuPreferences.defaults.speedLevel
        }
        return speedLevel
    }

    private func loadOpacity() -> DanmakuOpacity {
        guard let number = defaults.object(forKey: Key.opacity) as? NSNumber,
            CFGetTypeID(number) != CFBooleanGetTypeID(),
            let opacity = DanmakuOpacity(number.doubleValue)
        else {
            return DanmakuPreferences.defaults.opacity
        }
        return opacity
    }

    private func loadDisplayArea() -> DanmakuDisplayArea {
        guard let rawValue = integer(forKey: Key.displayArea),
            let displayArea = DanmakuDisplayArea(rawValue: rawValue)
        else {
            return DanmakuPreferences.defaults.displayArea
        }
        return displayArea
    }

    private func loadDensity() -> DanmakuDensity {
        guard let rawValue = integer(forKey: Key.density),
            let density = DanmakuDensity(rawValue: rawValue)
        else {
            return DanmakuPreferences.defaults.density
        }
        return density
    }

    private func integer(forKey key: String) -> Int? {
        guard let number = defaults.object(forKey: key) as? NSNumber,
            CFGetTypeID(number) != CFBooleanGetTypeID()
        else {
            return nil
        }
        let value = number.intValue
        return number.doubleValue == Double(value) ? value : nil
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

    @discardableResult
    func adjustVolume(by offset: Float) -> Float {
        guard offset.isFinite else { return player.volume }
        player.isMuted = false
        player.volume = min(max(player.volume + offset, 0), 1)
        return player.volume
    }
}
