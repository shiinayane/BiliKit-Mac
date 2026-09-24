import BiliAuthFeature
import BiliModels
import BiliPlayback
import Foundation
import Testing

@testable import BiliKit

@Suite(.timeLimit(.minutes(1)))
struct PlaybackSourceSettingsTests {
    @Test @MainActor
    func storePersistsKnownManualRouteAndFallsBackOnDamage() {
        withIsolatedDefaults { defaults in
            let store = UserDefaultsPlaybackSourcePreferenceStore(defaults: defaults)
            store.save(PlaybackSourcePreferenceRecord(selection: .huaweiMainland))
            #expect(store.load() == PlaybackSourcePreferenceRecord(selection: .huaweiMainland))
            defaults.set("unknown", forKey: "playbackSourcePreference.selection")
            #expect(store.load() == .defaults)
            defaults.set(99, forKey: "playbackSourcePreference.schema")
            #expect(store.load() == .defaults)
        }
    }

    @Test @MainActor
    func loudnessSettingDefaultsOffPersistsAndFallsBackOffWhenDamaged() {
        withIsolatedDefaults { defaults in
            let store = UserDefaultsPlaybackSourcePreferenceStore(
                defaults: defaults
            )
            store.save(.defaults)
            #expect(!store.load().loudnessNormalizationEnabled)

            store.save(
                PlaybackSourcePreferenceRecord(
                    selection: .serverAkamai,
                    loudnessNormalizationEnabled: true
                )
            )
            #expect(store.load().loudnessNormalizationEnabled)
            defaults.set(
                "damaged",
                forKey: "playback.loudnessNormalization.enabled"
            )
            #expect(!store.load().loudnessNormalizationEnabled)
            #expect(store.load().selection == .serverAkamai)
        }
    }

    @Test @MainActor
    func benchmarkResultNeverChangesManualSelection() async throws {
        let store = MemoryPlaybackSourcePreferenceStore(
            record: PlaybackSourcePreferenceRecord(selection: .alibabaMainland)
        )
        let model = AppSettingsModel(
            store: store,
            discover: { count in Array(repeating: try Self.sample(), count: count) },
            run: { samples, progress in
                let attemptCount = PlaybackRouteTarget.allCases.count * samples.count
                await progress(0, attemptCount)
                await progress(attemptCount, attemptCount)
                return [
                    PlaybackRouteMeasurement(
                        target: .serverAkamai,
                        effectiveBitsPerSecond: 8,
                        successfulRuns: samples.count,
                        totalRuns: samples.count
                    )
                ]
            }
        )
        model.setBenchmarkSampleCount(3)
        model.startBenchmark()
        await waitForObservedState { model.state == .completed }

        #expect(model.selection == .alibabaMainland)
        #expect(store.load().selection == .alibabaMainland)
        #expect(model.measurements.count == 1)
        #expect(model.measurements.first?.successfulRuns == 3)
        #expect(model.measurements.first?.totalRuns == 3)

        model.closeSettings()
        #expect(model.measurements.isEmpty)
        #expect(model.selection == .alibabaMainland)
    }

    @Test @MainActor
    func completedResultsPreferSampleSuccessRateThenHigherThroughput() async throws {
        let model = AppSettingsModel(
            store: MemoryPlaybackSourcePreferenceStore(),
            discover: { count in Array(repeating: try Self.sample(), count: count) },
            run: { _, _ in
                [
                    PlaybackRouteMeasurement(
                        target: .serverAkamai,
                        effectiveBitsPerSecond: 90_000_000,
                        successfulRuns: 2,
                        totalRuns: 3
                    ),
                    PlaybackRouteMeasurement(
                        target: .bilivideo(.alibabaMainland),
                        effectiveBitsPerSecond: 20_000_000,
                        successfulRuns: 3,
                        totalRuns: 3
                    ),
                    PlaybackRouteMeasurement(
                        target: .bilivideo(.tencentMainland),
                        effectiveBitsPerSecond: 40_000_000,
                        successfulRuns: 3,
                        totalRuns: 3
                    ),
                    PlaybackRouteMeasurement(
                        target: .bilivideo(.huaweiMainland),
                        effectiveBitsPerSecond: nil,
                        totalRuns: 3
                    ),
                    PlaybackRouteMeasurement(
                        target: .bilivideo(.tencentOverseas),
                        effectiveBitsPerSecond: 100_000_000,
                        successfulRuns: 1,
                        totalRuns: 3
                    )
                ]
            }
        )
        model.setBenchmarkSampleCount(3)
        model.startBenchmark()
        await waitForObservedState { model.state == .completed }

        #expect(
            model.measurements.map(\.target) == [
                .bilivideo(.tencentMainland),
                .bilivideo(.alibabaMainland),
                .serverAkamai,
                .bilivideo(.tencentOverseas),
                .bilivideo(.huaweiMainland)
            ]
        )
    }

    @Test @MainActor
    func signingOutDisablesBenchmarkBeforeConfirmedSessionChanges() {
        #expect(
            AppRootView.benchmarkAccess(
                sessionPhase: .signedIn,
                isSigningOut: true
            ) == .signedOut
        )
        #expect(
            AppRootView.benchmarkAccess(
                sessionPhase: .signedIn,
                isSigningOut: false
            ) == .signedIn
        )
    }

    @Test @MainActor
    func authenticationAccessUsesDenyWinsAcrossWindows() {
        let model = makeModel(store: MemoryPlaybackSourcePreferenceStore())
        let firstWindow = UUID()
        let secondWindow = UUID()

        model.synchronizeAuthentication(.signedIn, ownerID: firstWindow)
        model.synchronizeAuthentication(.signedIn, ownerID: secondWindow)
        model.synchronizeAuthentication(.signedOut, ownerID: firstWindow)
        model.synchronizeAuthentication(.signedIn, ownerID: secondWindow)
        #expect(model.benchmarkAccess == .signedOut)

        model.synchronizeAuthentication(.signedIn, ownerID: firstWindow)
        #expect(model.benchmarkAccess == .signedIn)
    }

    @Test @MainActor
    func newDiscoveryWaitsForLifecycleResetToFinish() async throws {
        let resetGate = ResetGate()
        let discovery = TestEventCounter()
        let model = AppSettingsModel(
            store: MemoryPlaybackSourcePreferenceStore(),
            discover: { _ in
                await discovery.record()
                return [try Self.sample()]
            },
            resetDiscovery: { await resetGate.wait() },
            run: { _, _ in [] }
        )

        model.closeSettings()
        model.startBenchmark()
        await resetGate.entered.wait()
        #expect(await discovery.count == 0)

        await resetGate.release()
        await discovery.wait()
    }

    @Test(arguments: SettingsBenchmarkFailureFixture.allCases) @MainActor
    func benchmarkFailureMapsToNonIdentifyingStateAndKeepsSelection(
        _ failure: SettingsBenchmarkFailureFixture
    ) async {
        let model = AppSettingsModel(
            store: MemoryPlaybackSourcePreferenceStore(),
            discover: { _ in
                if failure == .authentication {
                    throw PlaybackRouteBenchmarkOperationError.authenticationFailure
                }
                return [try Self.sample()]
            },
            run: { _, _ in throw BenchmarkTestError.transportFailure }
        )
        model.startBenchmark()
        await waitForObservedState { model.state == failure.expectedState }

        #expect(model.measurements.isEmpty)
        #expect(model.selection == .serverDefault)
    }

    @Test @MainActor
    func cancellationStopsWorkAndPreservesSelection() async throws {
        let cancellation = TestEventCounter()
        let invocation = TestEventCounter()
        let store = MemoryPlaybackSourcePreferenceStore(
            record: PlaybackSourcePreferenceRecord(selection: .serverAkamai)
        )
        let model = AppSettingsModel(
            store: store,
            discover: { _ in
                await invocation.record()
                do {
                    try await Task.sleep(for: .seconds(60))
                    return []
                } catch is CancellationError {
                    await cancellation.record()
                    throw CancellationError()
                }
            },
            run: { _, _ in [] }
        )
        model.startBenchmark()
        await invocation.wait()
        model.cancelBenchmark()
        await cancellation.wait()
        #expect(model.state == .cancelled)
        #expect(model.selection == .serverAkamai)
    }

    @Test @MainActor
    func ownerDestructionCancelsDiscovery() async throws {
        let cancellation = TestEventCounter()
        let invocation = TestEventCounter()
        var model: AppSettingsModel? = AppSettingsModel(
            store: MemoryPlaybackSourcePreferenceStore(),
            discover: { _ in
                await invocation.record()
                do {
                    try await Task.sleep(for: .seconds(60))
                    return []
                } catch is CancellationError {
                    await cancellation.record()
                    throw CancellationError()
                }
            },
            run: { _, _ in [] }
        )
        weak let owner = model
        model?.startBenchmark()
        await invocation.wait()
        model = nil

        await cancellation.wait()
        #expect(owner == nil)
    }

    @Test @MainActor
    func signedOutStatePreventsDiscoveryAndLogoutCancelsRunningBenchmark() async throws {
        let discovery = TestEventCounter()
        let cancellation = TestEventCounter()
        let reset = TestEventCounter()
        let model = AppSettingsModel(
            store: MemoryPlaybackSourcePreferenceStore(),
            benchmarkAccess: .signedOut,
            discover: { _ in
                await discovery.record()
                do {
                    try await Task.sleep(for: .seconds(60))
                    return []
                } catch is CancellationError {
                    await cancellation.record()
                    throw CancellationError()
                }
            },
            resetDiscovery: { await reset.record() },
            run: { _, _ in [] }
        )

        model.startBenchmark()
        #expect(await discovery.count == 0)

        model.synchronizeAuthentication(.signedIn)
        model.startBenchmark()
        await discovery.wait()
        model.synchronizeAuthentication(.signedOut)
        await cancellation.wait()
        await reset.wait()

        #expect(model.state == .notTested)
        #expect(model.measurements.isEmpty)
    }

    @MainActor
    private func makeModel(store: MemoryPlaybackSourcePreferenceStore) -> AppSettingsModel {
        AppSettingsModel(store: store, discover: { _ in [] }, run: { _, _ in [] })
    }

    private static func sample() throws -> PlaybackRouteBenchmarkSample {
        let primaryURL = try #require(
            URL(string: "https://a.bilivideo.com/v.m4s?t=1")
        )
        let backupURL = try #require(
            URL(string: "https://a.akamaized.net/v.m4s?h=1")
        )
        return PlaybackRouteBenchmarkSample(
            template: MediaRepresentation(
                id: 80,
                kind: .video,
                codecs: "avc1.640028",
                mimeType: "video/mp4",
                bandwidth: 1,
                videoAttributes: nil,
                primaryURL: primaryURL,
                backupURLs: [backupURL],
                segmentBase: SegmentBase(
                    initialization: try MediaByteRange(start: 0, endInclusive: 9),
                    index: try MediaByteRange(start: 10, endInclusive: 19)
                )
            ),
            headers: [:]
        )
    }

    @MainActor
    private func withIsolatedDefaults(_ body: (UserDefaults) -> Void) {
        let name = "PlaybackSourceSettingsTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: name) else { return }
        defaults.removePersistentDomain(forName: name)
        defer { defaults.removePersistentDomain(forName: name) }
        body(defaults)
    }
}

private enum BenchmarkTestError: Error {
    case transportFailure
}

enum SettingsBenchmarkFailureFixture: CaseIterable, Sendable {
    case transport
    case authentication

    var expectedState: PlaybackRouteBenchmarkState {
        switch self {
        case .transport: .networkOrProtocolFailure
        case .authentication: .authenticationFailure
        }
    }
}

private final class MemoryPlaybackSourcePreferenceStore: PlaybackSourcePreferenceStoring,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var record: PlaybackSourcePreferenceRecord
    init(record: PlaybackSourcePreferenceRecord = .defaults) { self.record = record }
    func load() -> PlaybackSourcePreferenceRecord { lock.withLock { record } }
    func save(_ record: PlaybackSourcePreferenceRecord) { lock.withLock { self.record = record } }
}

private actor ResetGate {
    let entered = TestEventCounter()
    private var continuation: CheckedContinuation<Void, Never>?
    private var isReleased = false

    func wait() async {
        await entered.record()
        guard !isReleased else { return }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func release() {
        isReleased = true
        continuation?.resume()
        continuation = nil
    }
}
