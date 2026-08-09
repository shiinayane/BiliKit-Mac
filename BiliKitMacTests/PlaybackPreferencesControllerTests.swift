@preconcurrency import AVFoundation
import BiliApplication
import Foundation
import Testing

@testable import BiliKit

struct PlaybackPreferencesControllerTests {
    @Test
    @MainActor
    func nativePlayerPreferencesPersistSynchronouslyAndRestore() {
        withIsolatedDefaults { defaults in
            let firstPlayer = AVPlayer()
            var firstController: PlaybackPreferencesController? =
                PlaybackPreferencesController(
                    player: firstPlayer,
                    store: UserDefaultsPlaybackPreferencesStore(defaults: defaults)
                )

            firstPlayer.volume = 0.35
            firstPlayer.isMuted = true
            firstPlayer.defaultRate = 1.5
            firstController = nil

            #expect(firstController == nil)
            let stored = UserDefaultsPlaybackPreferencesStore(defaults: defaults)
                .load()
            #expect(abs(stored.volume - 0.35) < 0.001)
            #expect(stored.isMuted)
            #expect(abs(stored.preferredRate - 1.5) < 0.001)

            let restoredPlayer = AVPlayer()
            let restoredController = PlaybackPreferencesController(
                player: restoredPlayer,
                store: UserDefaultsPlaybackPreferencesStore(defaults: defaults)
            )

            #expect(abs(restoredPlayer.volume - 0.35) < 0.001)
            #expect(restoredPlayer.isMuted)
            #expect(abs(restoredPlayer.defaultRate - 1.5) < 0.001)
            withExtendedLifetime(restoredController) {}
        }
    }

    @Test
    @MainActor
    func invalidValuesAndTypesFallBackToSafeDefaults() {
        withIsolatedDefaults { defaults in
            defaults.set(2, forKey: "player.volume")
            defaults.set(-1, forKey: "player.preferredRate")
            #expect(load(from: defaults) == .defaults)

            defaults.set(true, forKey: "player.volume")
            defaults.set(1, forKey: "player.isMuted")
            defaults.set("fast", forKey: "player.preferredRate")
            #expect(load(from: defaults) == .defaults)

            defaults.set(Double.nan, forKey: "player.volume")
            defaults.set(Double.infinity, forKey: "player.preferredRate")
            #expect(load(from: defaults) == .defaults)
        }
    }

    @Test
    @MainActor
    func danmakuSpeedLevelPersistsAndInvalidValuesFallBackToLevelThree() {
        withIsolatedDefaults { defaults in
            let store = UserDefaultsDanmakuSpeedPreferencesStore(
                defaults: defaults
            )
            #expect(store.loadSpeedLevel() == .three)

            store.saveSpeedLevel(.five)
            #expect(store.loadSpeedLevel() == .five)

            defaults.set(2.5, forKey: "danmaku.speedLevel")
            #expect(store.loadSpeedLevel() == .three)
            defaults.set(true, forKey: "danmaku.speedLevel")
            #expect(store.loadSpeedLevel() == .three)
            defaults.set(6, forKey: "danmaku.speedLevel")
            #expect(store.loadSpeedLevel() == .three)
        }
    }

    @MainActor
    private func withIsolatedDefaults(
        _ body: (UserDefaults) -> Void
    ) {
        let suiteName = "PlaybackPreferencesControllerTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            Issue.record("无法创建隔离的 UserDefaults suite")
            return
        }
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        body(defaults)
    }

    private func load(from defaults: UserDefaults) -> PlaybackPreferences {
        UserDefaultsPlaybackPreferencesStore(defaults: defaults).load()
    }
}
