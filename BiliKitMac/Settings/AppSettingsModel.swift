import BiliPlayback
import Foundation
import Observation

enum PlaybackRouteBenchmarkState: Sendable, Equatable {
    case notTested
    case findingSample
    case testing(completed: Int, total: Int)
    case completed
    case cancelled
    case sampleUnavailable
    case authenticationFailure
    case networkOrProtocolFailure

    var isRunning: Bool {
        switch self {
        case .findingSample, .testing: true
        default: false
        }
    }
}

enum PlaybackRouteBenchmarkAccess: Sendable, Equatable {
    case resolving, signedOut, signedIn
    var allowsBenchmark: Bool { self == .signedIn }
}

enum PlaybackRouteBenchmarkOperationError: Error {
    case authenticationFailure
}

@MainActor
@Observable
final class AppSettingsModel {
    static let supportedBenchmarkSampleCounts = 1...3
    typealias Discover = @Sendable (Int) async throws -> [PlaybackRouteBenchmarkSample]
    typealias ResetDiscovery = @Sendable () async -> Void
    typealias Run =
        @Sendable (
            [PlaybackRouteBenchmarkSample],
            @escaping @Sendable (Int, Int) async -> Void
        ) async throws -> [PlaybackRouteMeasurement]

    private(set) var state: PlaybackRouteBenchmarkState = .notTested
    private(set) var benchmarkAccess: PlaybackRouteBenchmarkAccess
    private(set) var record: PlaybackSourcePreferenceRecord
    private(set) var measurements: [PlaybackRouteMeasurement] = []
    private(set) var benchmarkSampleCount = 1
    @ObservationIgnored private let store: any PlaybackSourcePreferenceStoring
    @ObservationIgnored private var discover: Discover
    @ObservationIgnored private var resetDiscovery: ResetDiscovery
    @ObservationIgnored private var run: Run
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var discoveryResetTask: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var authenticationAccessByOwner:
        [UUID: PlaybackRouteBenchmarkAccess] = [:]

    init(
        store: any PlaybackSourcePreferenceStoring,
        benchmarkAccess: PlaybackRouteBenchmarkAccess = .signedIn,
        discover: @escaping Discover,
        resetDiscovery: @escaping ResetDiscovery = {},
        run: @escaping Run
    ) {
        self.store = store
        self.benchmarkAccess = benchmarkAccess
        self.discover = discover
        self.resetDiscovery = resetDiscovery
        self.run = run
        record = store.load()
    }

    deinit {
        task?.cancel()
        discoveryResetTask?.cancel()
    }

    func synchronizeAuthentication(_ access: PlaybackRouteBenchmarkAccess) {
        synchronizeAuthentication(access, ownerID: Self.unscopedAuthenticationOwnerID)
    }

    func synchronizeAuthentication(
        _ access: PlaybackRouteBenchmarkAccess,
        ownerID: UUID
    ) {
        authenticationAccessByOwner[ownerID] = access
        applyAuthenticationAccess()
    }

    func removeAuthenticationOwner(_ ownerID: UUID) {
        authenticationAccessByOwner[ownerID] = nil
        applyAuthenticationAccess()
    }

    private static let unscopedAuthenticationOwnerID = UUID()

    private func applyAuthenticationAccess() {
        let access: PlaybackRouteBenchmarkAccess
        if authenticationAccessByOwner.values.contains(.signedOut) {
            access = .signedOut
        } else if authenticationAccessByOwner.values.contains(.signedIn) {
            access = .signedIn
        } else {
            access = .resolving
        }
        guard access != benchmarkAccess else { return }
        benchmarkAccess = access
        if !access.allowsBenchmark {
            cancelBenchmark(markCancelled: false)
            scheduleDiscoveryReset()
            state = .notTested
            measurements = []
        }
    }

    var selection: PlaybackSourceSelection {
        get { record.selection }
        set {
            let updated = PlaybackSourcePreferenceRecord(
                selection: newValue,
                loudnessNormalizationEnabled: record.loudnessNormalizationEnabled
            )
            record = updated
            store.save(updated)
        }
    }

    var loudnessNormalizationEnabled: Bool {
        get { record.loudnessNormalizationEnabled }
        set {
            let updated = PlaybackSourcePreferenceRecord(
                selection: record.selection,
                loudnessNormalizationEnabled: newValue
            )
            record = updated
            store.save(updated)
        }
    }

    var playbackSourcePreference: PlaybackSourcePreference {
        record.selection.preference
    }

    func setBenchmarkSampleCount(_ value: Int) {
        guard !state.isRunning,
            Self.supportedBenchmarkSampleCounts.contains(value)
        else { return }
        benchmarkSampleCount = value
    }

    static func maximumTrafficBytes(repetitions: Int) -> UInt64? {
        guard Self.supportedBenchmarkSampleCounts.contains(repetitions) else {
            return nil
        }
        let targetCount = UInt64(PlaybackRouteTarget.allCases.count)
        let perSample =
            targetCount
            * (BilivideoRouteBenchmark.maximumIndexBytes
                + BilivideoRouteBenchmark.maximumMediaProbeBytes)
            + BilivideoRouteBenchmark.maximumIndexBytes
        return UInt64(repetitions) * perSample
    }

    func startBenchmark() {
        guard benchmarkAccess.allowsBenchmark else { return }
        cancelBenchmark(markCancelled: false)
        let currentGeneration = UUID()
        let sampleCount = benchmarkSampleCount
        let pendingDiscoveryReset = discoveryResetTask
        generation = currentGeneration
        state = .findingSample
        measurements = []
        task = Task { [weak self, discover, run] in
            do {
                await pendingDiscoveryReset?.value
                try Task.checkCancellation()
                let samples = try await discover(sampleCount)
                try Task.checkCancellation()
                guard self?.benchmarkAccess.allowsBenchmark == true else {
                    throw CancellationError()
                }
                guard samples.count == sampleCount else {
                    self?.applyFailure(
                        .sampleUnavailable,
                        generation: currentGeneration
                    )
                    return
                }
                let result = try await run(samples) {
                    [weak self] completed, total in
                    await self?.applyProgress(
                        completed,
                        total: total,
                        generation: currentGeneration
                    )
                }
                try Task.checkCancellation()
                self?.applyResult(result, generation: currentGeneration)
            } catch is CancellationError {
                self?.applyCancellation(generation: currentGeneration)
            } catch PlaybackRouteBenchmarkOperationError.authenticationFailure {
                self?.applyFailure(
                    .authenticationFailure,
                    generation: currentGeneration
                )
            } catch {
                self?.applyFailure(
                    .networkOrProtocolFailure,
                    generation: currentGeneration
                )
            }
        }
    }

    func cancelBenchmark(markCancelled: Bool = true) {
        guard task != nil else { return }
        generation = UUID()
        task?.cancel()
        task = nil
        if markCancelled { state = .cancelled }
    }

    func closeSettings() {
        cancelBenchmark(markCancelled: false)
        scheduleDiscoveryReset()
        measurements = []
        state = .notTested
    }

    private func applyProgress(_ completed: Int, total: Int, generation: UUID) {
        guard self.generation == generation else { return }
        state = .testing(completed: completed, total: total)
    }

    private func scheduleDiscoveryReset() {
        discoveryResetTask?.cancel()
        let resetDiscovery = resetDiscovery
        discoveryResetTask = Task { await resetDiscovery() }
    }

    private func applyResult(_ result: [PlaybackRouteMeasurement], generation: UUID) {
        guard self.generation == generation else { return }
        task = nil
        measurements = result.enumerated().sorted { lhs, rhs in
            let leftSuccess = lhs.element.successfulRuns * rhs.element.totalRuns
            let rightSuccess = rhs.element.successfulRuns * lhs.element.totalRuns
            if leftSuccess != rightSuccess {
                return leftSuccess > rightSuccess
            }
            let lhsThroughput = Self.sortableThroughput(lhs.element)
            let rhsThroughput = Self.sortableThroughput(rhs.element)
            if lhsThroughput != rhsThroughput {
                return lhsThroughput > rhsThroughput
            }
            let lhsMinimum = Self.sortableMinimum(lhs.element)
            let rhsMinimum = Self.sortableMinimum(rhs.element)
            if lhsMinimum != rhsMinimum {
                return lhsMinimum > rhsMinimum
            }
            return lhs.offset < rhs.offset
        }.map(\.element)
        state = .completed
    }

    private static func sortableThroughput(_ result: PlaybackRouteMeasurement) -> Double {
        guard let throughput = result.effectiveBitsPerSecond,
            throughput.isFinite, throughput >= 0
        else { return -.infinity }
        return throughput
    }

    private static func sortableMinimum(_ result: PlaybackRouteMeasurement) -> Double {
        guard let throughput = result.minimumBitsPerSecond,
            throughput.isFinite, throughput >= 0
        else { return -.infinity }
        return throughput
    }

    private func applyCancellation(generation: UUID) {
        guard self.generation == generation else { return }
        task = nil
        state = .cancelled
    }

    private func applyFailure(
        _ failure: PlaybackRouteBenchmarkState,
        generation: UUID
    ) {
        guard self.generation == generation else { return }
        task = nil
        state = failure
    }
}
