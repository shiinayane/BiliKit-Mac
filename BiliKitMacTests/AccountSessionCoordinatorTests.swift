import BiliApplication
import BiliModels
import Observation
import Synchronization
import Testing

@testable import BiliKit

/// 进程账户会话只在两侧都已解析且账户不同时推进代次，凭据失效作用到每个仍登记的窗口会话。
///
/// 账户切换只看 mid，从未解析到解析出结果不算切换；会话的登记与注销不触发账户状态的观察。
@Suite(.timeLimit(.minutes(1)))
struct AccountSessionCoordinatorTests {
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
}
