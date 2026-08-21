@preconcurrency import AVFoundation
import BiliApplication
import Foundation
import Testing

@testable import BiliKit

struct PlaybackPreferencesControllerTests {
    @Test
    @MainActor
    func relativeVolumeClampsUnmutesAndUsesTheObservedPlayer() {
        let player = AVPlayer()
        player.volume = 0.98
        player.isMuted = true
        let controller = PlaybackPreferencesController(
            player: player,
            store: InMemoryPlaybackPreferencesStore()
        )

        #expect(controller.adjustVolume(by: 0.05) == 1)
        #expect(player.volume == 1)
        #expect(!player.isMuted)
        #expect(controller.adjustVolume(by: -2) == 0)
        #expect(player.volume == 0)
    }

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
    func danmakuDisplayPreferencesPersistAndInvalidValuesFallBack() throws {
        try withIsolatedDefaults { defaults in
            let store = UserDefaultsDanmakuPreferencesStore(
                defaults: defaults
            )
            #expect(store.load() == .defaults)

            store.saveSpeedLevel(.five)
            let opacity = try #require(DanmakuOpacity(0.55))
            store.saveOpacity(opacity)
            store.saveDisplayArea(.threeQuarters)
            store.saveDensity(.overlapping)
            #expect(
                store.load()
                    == DanmakuPreferences(
                        speedLevel: .five,
                        opacity: opacity,
                        displayArea: .threeQuarters,
                        density: .overlapping
                    )
            )

            defaults.set(2.5, forKey: "danmaku.speedLevel")
            #expect(store.load().speedLevel == .three)
            #expect(store.load().opacity == opacity)
            defaults.set(true, forKey: "danmaku.speedLevel")
            #expect(store.load().speedLevel == .three)
            defaults.set(6, forKey: "danmaku.speedLevel")
            #expect(store.load().speedLevel == .three)

            for invalidOpacity in [Double.nan, 0.1, 1.1] {
                defaults.set(invalidOpacity, forKey: "danmaku.opacity")
                #expect(store.load().opacity == .fullyOpaque)
            }
            defaults.set(true, forKey: "danmaku.opacity")
            #expect(store.load().opacity == .fullyOpaque)

            for invalidDisplayArea in [0, 50.5, 101] {
                defaults.set(invalidDisplayArea, forKey: "danmaku.displayArea")
                #expect(store.load().displayArea == .full)
            }
            defaults.set(true, forKey: "danmaku.displayArea")
            #expect(store.load().displayArea == .full)

            for invalidDensity in [-1, 1.5, 3] {
                defaults.set(invalidDensity, forKey: "danmaku.density")
                #expect(store.load().density == .normal)
            }
            defaults.set(true, forKey: "danmaku.density")
            #expect(store.load().density == .normal)
        }
    }

    @MainActor
    private func withIsolatedDefaults(
        _ body: (UserDefaults) throws -> Void
    ) rethrows {
        let suiteName = "PlaybackPreferencesControllerTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            Issue.record("无法创建隔离的 UserDefaults suite")
            return
        }
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        try body(defaults)
    }

    private func load(from defaults: UserDefaults) -> PlaybackPreferences {
        UserDefaultsPlaybackPreferencesStore(defaults: defaults).load()
    }
}

private final class InMemoryPlaybackPreferencesStore:
    PlaybackPreferencesStoring, @unchecked Sendable
{
    func load() -> PlaybackPreferences { .defaults }
    func saveVolume(_ volume: Float) {}
    func saveMuted(_ isMuted: Bool) {}
    func savePreferredRate(_ rate: Float) {}
}
