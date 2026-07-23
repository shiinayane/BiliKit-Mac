import Testing
@testable import BiliKit

struct AppNavigationModelTests {
    @Test
    @MainActor
    func playbackReturnAndSecondSelectionHaveOneSideEffectOwner() {
        var events: [String] = []
        let model = AppNavigationModel(
            startPlayback: { events.append("start:\($0)") },
            stopPlayback: { events.append("stop") }
        )

        model.openPlayback("BV1RouteA")
        model.returnFromPlayback()
        model.openPlayback("BV1RouteB")

        #expect(
            events == [
                "start:BV1RouteA",
                "stop",
                "start:BV1RouteB",
            ]
        )
        #expect(model.route == .playback(bvid: "BV1RouteB"))
    }

    @Test
    @MainActor
    func returnRestoresSearchSourceAndQueryWithoutRestartingPlayback() {
        var startCount = 0
        var stopCount = 0
        let model = AppNavigationModel(
            startPlayback: { _ in startCount += 1 },
            stopPlayback: { stopCount += 1 }
        )
        model.selectSection(.search)
        model.searchQuery = "手写搜索词"

        model.openPlayback("BV1SearchA")
        model.returnFromPlayback()

        #expect(model.route == .section(.search))
        #expect(model.searchQuery == "手写搜索词")
        #expect(model.returnSnapshot?.selectedBVID == "BV1SearchA")
        #expect(startCount == 1)
        #expect(stopCount == 1)
    }

    @Test
    @MainActor
    func closingPlaybackStopsOnceAndClearsReturnContext() {
        var stopCount = 0
        let model = AppNavigationModel(
            startPlayback: { _ in },
            stopPlayback: { stopCount += 1 }
        )

        model.openPlayback("BV1CloseA")
        model.closeWindow()
        model.closeWindow()

        #expect(stopCount == 1)
        #expect(model.route == .section(.popular))
        #expect(model.returnSnapshot == nil)
    }

    @Test
    @MainActor
    func selectingSidebarFromPlaybackStopsOnceAndClearsReturnContext() {
        var stopCount = 0
        let model = AppNavigationModel(
            startPlayback: { _ in },
            stopPlayback: { stopCount += 1 }
        )

        model.openPlayback("BV1SidebarA")
        model.selectSection(.search)

        #expect(stopCount == 1)
        #expect(model.route == .section(.search))
        #expect(model.returnSnapshot == nil)
    }

    @Test
    @MainActor
    func reopeningCurrentPlaybackDoesNotDuplicateLoad() {
        var startCount = 0
        let model = AppNavigationModel(
            startPlayback: { _ in startCount += 1 },
            stopPlayback: {}
        )

        model.openPlayback("BV1SameA")
        model.openPlayback("BV1SameA")

        #expect(startCount == 1)
    }

    @Test
    @MainActor
    func playbackRetryUsesTheAppOwnerWithoutChangingRoute() {
        var events: [String] = []
        let model = AppNavigationModel(
            startPlayback: { events.append("start:\($0)") },
            stopPlayback: { events.append("stop") }
        )

        model.openPlayback("BV1RetryA")
        model.retryPlayback()

        #expect(
            events == [
                "start:BV1RetryA",
                "start:BV1RetryA",
            ]
        )
        #expect(model.route == .playback(bvid: "BV1RetryA"))
    }

    @Test
    @MainActor
    func signingOutClearsPersonalizedReturnSourceWithoutStoppingPublicPlayback() {
        var stopCount = 0
        let model = AppNavigationModel(
            startPlayback: { _ in },
            stopPlayback: { stopCount += 1 }
        )
        model.selectSection(.history)
        model.openPlayback("BV1HistoryA")

        model.authenticationDidBecomeSignedOut()

        #expect(model.route == .playback(bvid: "BV1HistoryA"))
        #expect(model.returnSnapshot == nil)
        #expect(stopCount == 0)
    }
}
