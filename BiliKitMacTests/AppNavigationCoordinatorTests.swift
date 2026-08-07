import Foundation
import Testing

@testable import BiliKit

struct AppNavigationCoordinatorTests {
    @Test
    @MainActor
    func nativeBackReturnsEachSourceInOnePop() {
        for source in [AppTab.search, .popular, .history] {
            var stopCount = 0
            let coordinator = AppNavigationCoordinator(
                startPlayback: { _ in },
                stopPlayback: { stopCount += 1 }
            )
            coordinator.selectedTab = source

            coordinator.openPlayback("BV1Source")
            #expect(coordinator.playbackPath.count == 1)
            coordinator.playbackPath.removeLast()
            coordinator.playbackPath.removeAll()

            #expect(coordinator.selectedTab == source)
            #expect(coordinator.playbackPath.isEmpty)
            #expect(coordinator.currentPlaybackBVID == nil)
            #expect(stopCount == 1)
        }
    }

    @Test
    @MainActor
    func replacementKeepsSurfaceSourceAndDraftWhileOrderingSideEffects() {
        var events: [String] = []
        let coordinator = AppNavigationCoordinator(
            startPlayback: { events.append("start:\($0)") },
            stopPlayback: { events.append("stop") }
        )
        coordinator.selectedTab = .search
        coordinator.searchDraft = "手写搜索词"

        coordinator.openPlayback("BV1RouteA")
        let surfaceID = coordinator.playbackPath.first?.surfaceID
        coordinator.openPlayback("BV1RouteB")
        coordinator.openPlayback("BV1RouteC")

        #expect(coordinator.playbackPath.count == 1)
        #expect(coordinator.playbackPath.first?.surfaceID == surfaceID)
        #expect(coordinator.currentPlaybackBVID == "BV1RouteC")
        #expect(coordinator.selectedTab == .search)
        #expect(coordinator.searchDraft == "手写搜索词")
        #expect(
            events == [
                "start:BV1RouteA",
                "start:BV1RouteB",
                "start:BV1RouteC",
            ]
        )
    }

    @Test
    @MainActor
    func nonemptyPathWriteCannotForgeOrReplacePlayback() {
        var events: [String] = []
        let coordinator = AppNavigationCoordinator(
            startPlayback: { events.append("start:\($0)") },
            stopPlayback: { events.append("stop") }
        )
        let forgedDestination = PlaybackDestination(surfaceID: UUID())

        coordinator.playbackPath = [forgedDestination]
        #expect(coordinator.playbackPath.isEmpty)
        #expect(coordinator.currentPlaybackBVID == nil)

        coordinator.openPlayback("BV1Actual")
        let actualDestination = coordinator.playbackPath.first
        coordinator.playbackPath = [forgedDestination]

        #expect(coordinator.playbackPath.count == 1)
        #expect(coordinator.playbackPath.first == actualDestination)
        #expect(coordinator.currentPlaybackBVID == "BV1Actual")
        #expect(events == ["start:BV1Actual"])
    }

    @Test
    @MainActor
    func reopeningCurrentPlaybackDoesNotDuplicateLoad() {
        var startCount = 0
        let coordinator = AppNavigationCoordinator(
            startPlayback: { _ in startCount += 1 },
            stopPlayback: {}
        )

        coordinator.openPlayback("BV1SameA")
        coordinator.openPlayback("BV1SameA")

        #expect(startCount == 1)
        #expect(coordinator.playbackPath.count == 1)
    }

    @Test
    @MainActor
    func retryKeepsSurfaceAndMediaIdentity() {
        var events: [String] = []
        let coordinator = AppNavigationCoordinator(
            startPlayback: { events.append("start:\($0)") },
            stopPlayback: { events.append("stop") }
        )

        coordinator.openPlayback("BV1RetryA")
        let destination = coordinator.playbackPath.first
        coordinator.retryPlayback()

        #expect(coordinator.playbackPath.first == destination)
        #expect(coordinator.currentPlaybackBVID == "BV1RetryA")
        #expect(events == ["start:BV1RetryA", "start:BV1RetryA"])
    }

    @Test
    @MainActor
    func selectingAnotherSourceClosesPlaybackExactlyOnce() {
        var stopCount = 0
        let coordinator = AppNavigationCoordinator(
            startPlayback: { _ in },
            stopPlayback: { stopCount += 1 }
        )

        coordinator.openPlayback("BV1SidebarA")
        coordinator.selectedTab = .search
        coordinator.selectedTab = .search

        #expect(coordinator.selectedTab == .search)
        #expect(coordinator.playbackPath.isEmpty)
        #expect(coordinator.currentPlaybackBVID == nil)
        #expect(stopCount == 1)
    }

    @Test
    @MainActor
    func windowClosureIsIdempotentAndResetsWindowState() {
        var stopCount = 0
        let coordinator = AppNavigationCoordinator(
            startPlayback: { _ in },
            stopPlayback: { stopCount += 1 }
        )
        coordinator.selectedTab = .history
        coordinator.searchDraft = "待清理草稿"
        coordinator.openPlayback("BV1CloseA")

        coordinator.resetForWindowClosure()
        coordinator.resetForWindowClosure()

        #expect(stopCount == 1)
        #expect(coordinator.selectedTab == .popular)
        #expect(coordinator.searchDraft.isEmpty)
        #expect(coordinator.playbackPath.isEmpty)
        #expect(coordinator.currentPlaybackBVID == nil)
    }

    @Test
    @MainActor
    func authenticationChangeClosesPlaybackWithoutLosingSourceContext() {
        var stopCount = 0
        let coordinator = AppNavigationCoordinator(
            startPlayback: { _ in },
            stopPlayback: { stopCount += 1 }
        )
        coordinator.selectedTab = .search
        coordinator.searchDraft = "保留的来源草稿"
        coordinator.openPlayback("BV1Logout")

        coordinator.closePlaybackForAuthenticationChange()
        coordinator.closePlaybackForAuthenticationChange()

        #expect(stopCount == 1)
        #expect(coordinator.selectedTab == .search)
        #expect(coordinator.searchDraft == "保留的来源草稿")
        #expect(coordinator.playbackPath.isEmpty)
        #expect(coordinator.currentPlaybackBVID == nil)
    }

    @Test
    @MainActor
    func emptyBVIDDoesNotCreatePlaybackState() {
        var events: [String] = []
        let coordinator = AppNavigationCoordinator(
            startPlayback: { events.append("start:\($0)") },
            stopPlayback: { events.append("stop") }
        )

        coordinator.openPlayback("")

        #expect(coordinator.playbackPath.isEmpty)
        #expect(coordinator.currentPlaybackBVID == nil)
        #expect(events.isEmpty)
    }
}
