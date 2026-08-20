import BiliApplication
import BiliAuthFeature
import BiliModels
import Foundation
import Observation
import Synchronization
import Testing

@testable import BiliKit

struct AppNavigationCoordinatorTests {
    @Test
    @MainActor
    func accountSessionCoordinatorPublishesOnlyResolvedProcessChanges() {
        let coordinator = AccountSessionCoordinator()

        coordinator.publish(.unresolved)
        #expect(coordinator.generation == 0)
        #expect(coordinator.scope == .unresolved)

        coordinator.publish(.signedIn(accountID: 1))
        #expect(coordinator.generation == 1)
        #expect(coordinator.scope == .signedIn(accountID: 1))

        coordinator.publish(.signedIn(accountID: 1))
        #expect(coordinator.generation == 1)

        coordinator.publish(.signedOut)
        #expect(coordinator.generation == 2)
        #expect(coordinator.scope == .signedOut)
    }

    @Test
    @MainActor
    func accountSessionCoordinatorInvalidatesEveryRegisteredWindowSession() async {
        let coordinator = AccountSessionCoordinator()
        let first = RecordingSessionInvalidator()
        let second = RecordingSessionInvalidator()
        let closed = RecordingSessionInvalidator()
        _ = coordinator.registerSessionInvalidator(first)
        _ = coordinator.registerSessionInvalidator(second)
        let closedRegistration = coordinator.registerSessionInvalidator(closed)
        coordinator.unregisterSessionInvalidator(closedRegistration)

        await coordinator.invalidateAuthenticatedSession()

        #expect(await first.invalidationCount == 1)
        #expect(await second.invalidationCount == 1)
        #expect(await closed.invalidationCount == 0)
    }

    @Test
    @MainActor
    func sessionRegistrationDoesNotInvalidateObservedAccountState() {
        let coordinator = AccountSessionCoordinator()
        let invalidator = RecordingSessionInvalidator()
        let observationChanged = Mutex(false)

        withObservationTracking {
            _ = coordinator.generation
            _ = coordinator.scope
        } onChange: {
            observationChanged.withLock { $0 = true }
        }

        let registrationID = coordinator.registerSessionInvalidator(invalidator)
        coordinator.unregisterSessionInvalidator(registrationID)

        #expect(!observationChanged.withLock { $0 })
    }

    @Test
    func historyOwnershipTracksAccountIDWithoutFollowingProfileChanges() {
        let first = AccountIdentity(id: 1, displayName: "账号一", avatarURL: nil)
        let renamedFirst = AccountIdentity(id: 1, displayName: "新昵称", avatarURL: nil)
        let second = AccountIdentity(id: 2, displayName: "账号二", avatarURL: nil)

        let unresolved = AccountSessionScope.unresolved
        let signedOut = AccountSessionScope.signedOut
        let unknown = AccountSessionScope.signedIn(accountID: nil)
        let firstScope = AccountSessionScope.signedIn(accountID: first.id)
        let renamedScope = AccountSessionScope.signedIn(accountID: renamedFirst.id)
        let secondScope = AccountSessionScope.signedIn(accountID: second.id)

        #expect(!AccountSessionScope.isResolvedChange(from: unresolved, to: unknown))
        #expect(AccountSessionScope.isResolvedChange(from: signedOut, to: unknown))
        #expect(AccountSessionScope.isResolvedChange(from: unknown, to: firstScope))
        #expect(!AccountSessionScope.isResolvedChange(from: firstScope, to: renamedScope))
        #expect(AccountSessionScope.isResolvedChange(from: firstScope, to: secondScope))
        #expect(AccountSessionScope.isResolvedChange(from: secondScope, to: signedOut))
    }

    @Test
    func onlyLeavingHistorySourceDeactivatesItsRequests() {
        #expect(
            !HistoryRouteOwnership.deactivatesHistory(from: .history, to: .history)
        )
        #expect(
            HistoryRouteOwnership.deactivatesHistory(from: .history, to: .popular)
        )
        #expect(
            !HistoryRouteOwnership.deactivatesHistory(from: .popular, to: .history)
        )
    }

    @Test
    @MainActor
    func nativeBackReturnsEachSourceInOnePop() {
        for source in [AppTab.search, .home, .popular, .history] {
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
            startPlayback: { events.append("start:\($0.bvid)") },
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
            startPlayback: { events.append("start:\($0.bvid)") },
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
    func sameBVIDDifferentCIDIsANewAtomicSelectionIntent() {
        var intents: [PlaybackSelectionIntent] = []
        let coordinator = AppNavigationCoordinator(
            startPlayback: { intents.append($0) },
            stopPlayback: {}
        )

        coordinator.openPlayback(
            PlaybackSelectionIntent(bvid: "BV1SameA", preferredCID: 101)
        )
        coordinator.openPlayback(
            PlaybackSelectionIntent(bvid: "BV1SameA", preferredCID: 102)
        )

        #expect(intents.map(\.preferredCID) == [101, 102])
        #expect(coordinator.currentPlaybackIntent?.preferredCID == 102)
        #expect(coordinator.playbackPath.count == 1)
    }

    @Test
    @MainActor
    func retryKeepsSurfaceAndMediaIdentity() {
        var intents: [PlaybackSelectionIntent] = []
        let coordinator = AppNavigationCoordinator(
            startPlayback: { intents.append($0) },
            stopPlayback: {}
        )

        coordinator.openPlayback(
            PlaybackSelectionIntent(bvid: "BV1RetryA", preferredCID: 202)
        )
        let destination = coordinator.playbackPath.first
        coordinator.retryPlayback()

        #expect(coordinator.playbackPath.first == destination)
        #expect(coordinator.currentPlaybackBVID == "BV1RetryA")
        #expect(intents.map(\.preferredCID) == [202, 202])
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
        #expect(coordinator.selectedTab == .home)
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
            startPlayback: { events.append("start:\($0.bvid)") },
            stopPlayback: { events.append("stop") }
        )

        coordinator.openPlayback("")

        #expect(coordinator.playbackPath.isEmpty)
        #expect(coordinator.currentPlaybackBVID == nil)
        #expect(events.isEmpty)
    }
}

private actor RecordingSessionInvalidator: AuthenticatedSessionInvalidating {
    private(set) var invalidationCount = 0

    func invalidateAuthenticatedSession() {
        invalidationCount += 1
    }
}
