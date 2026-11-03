import Foundation
import Testing

@testable import BiliKit

/// 浏览态与播放态各自恢复用户拖出的宽度，且总在该状态的范围内；没有记录时用该状态的默认宽度。
struct SidebarWidthStoreTests {
    @Test
    func eachModeRestoresItsOwnRecordedWidth() {
        withIsolatedDefaults { defaults in
            let store = SidebarWidthStore(defaults: defaults)

            store.record(250, for: .browsing)
            store.record(700, for: .playback)

            #expect(store.restoredWidth(for: .browsing) == 250)
            #expect(store.restoredWidth(for: .playback) == 700)
        }
    }

    @Test
    func missingRecordFallsBackToIdealWidth() {
        withIsolatedDefaults { defaults in
            let store = SidebarWidthStore(defaults: defaults)

            #expect(store.restoredWidth(for: .browsing) == SidebarColumnMode.browsing.idealWidth)
            #expect(store.restoredWidth(for: .playback) == SidebarColumnMode.playback.idealWidth)
        }
    }

    @Test
    func restoredWidthStaysWithinTheModeRange() {
        withIsolatedDefaults { defaults in
            let store = SidebarWidthStore(defaults: defaults)

            defaults.set(5_000.0, forKey: "sidebarWidth.playback")
            defaults.set(10.0, forKey: "sidebarWidth.browsing")

            #expect(store.restoredWidth(for: .playback) == SidebarColumnMode.playback.maximumWidth)
            #expect(store.restoredWidth(for: .browsing) == SidebarColumnMode.browsing.minimumWidth)
        }
    }
}
