import BiliApplication
import BiliAuthFeature
import Foundation
import Observation

@MainActor
@Observable
final class AccountSessionCoordinator: AuthenticatedSessionInvalidating {
    private(set) var generation: UInt64 = 0
    private(set) var scope = AccountSessionScope.unresolved
    @ObservationIgnored
    private var sessionInvalidators: [UUID: any AuthenticatedSessionInvalidating] = [:]
    @ObservationIgnored
    /// 由 `BiliKitMacApp` 持有的 coordinator 拥有整个进程生命周期；注册项随进程一起释放。
    private var processWatchProgressRepository: (any WatchProgressRepository)?

    var watchProgressRepository: (any WatchProgressRepository)? {
        processWatchProgressRepository
    }

    func publish(_ scope: AccountSessionScope) {
        guard scope != .unresolved, scope != self.scope else { return }
        self.scope = scope
        generation &+= 1
    }

    func registerSessionInvalidator(
        _ invalidator: any AuthenticatedSessionInvalidating
    ) -> UUID {
        let registrationID = UUID()
        sessionInvalidators[registrationID] = invalidator
        return registrationID
    }

    func unregisterSessionInvalidator(_ registrationID: UUID) {
        sessionInvalidators[registrationID] = nil
    }

    func resolveWatchProgressRepository(
        make: () -> (
            any WatchProgressRepository,
            any AuthenticatedSessionInvalidating
        )
    ) -> any WatchProgressRepository {
        if let processWatchProgressRepository {
            return processWatchProgressRepository
        }
        let (base, transportInvalidator) = make()
        let writer = SerializedWatchProgressRepository(base: base)
        processWatchProgressRepository = writer
        _ = registerSessionInvalidator(writer)
        _ = registerSessionInvalidator(transportInvalidator)
        return writer
    }

    func invalidateAuthenticatedSession() async {
        let invalidators = Array(sessionInvalidators.values)
        await withTaskGroup(of: Void.self) { group in
            for invalidator in invalidators {
                group.addTask {
                    await invalidator.invalidateAuthenticatedSession()
                }
            }
        }
    }
}

@MainActor
final class AppEnvironmentSessionRegistration {
    private weak var coordinator: AccountSessionCoordinator?
    private let invalidator: any AuthenticatedSessionInvalidating
    private var registrationID: UUID?

    init(
        coordinator: AccountSessionCoordinator,
        invalidator: any AuthenticatedSessionInvalidating
    ) {
        self.coordinator = coordinator
        self.invalidator = invalidator
    }

    func open() {
        guard registrationID == nil, let coordinator else { return }
        registrationID = coordinator.registerSessionInvalidator(invalidator)
    }

    func close() {
        guard let registrationID else { return }
        coordinator?.unregisterSessionInvalidator(registrationID)
        self.registrationID = nil
    }
}
