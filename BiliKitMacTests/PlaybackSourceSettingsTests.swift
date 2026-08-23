import BiliAPI
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
    func manualSelectionPersistsAndMapsToFuturePlaybackPreference() {
        let store = MemoryPlaybackSourcePreferenceStore()
        let model = makeModel(store: store)
        let oldSnapshot = model.playbackSourcePreference
        model.selection = .tencentOverseas

        #expect(oldSnapshot == .serverDefault)
        #expect(model.playbackSourcePreference == .experimentalBilivideoRoute(.tencentOverseas))
        #expect(store.load().selection == .tencentOverseas)
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
    func loudnessSettingDoesNotRewriteCurrentPreferenceSnapshot() {
        let store = MemoryPlaybackSourcePreferenceStore()
        let model = makeModel(store: store)
        let oldSnapshot = model.loudnessNormalizationEnabled

        model.loudnessNormalizationEnabled = true

        #expect(!oldSnapshot)
        #expect(model.loudnessNormalizationEnabled)
        #expect(store.load().loudnessNormalizationEnabled)
    }

    @Test @MainActor
    func trafficLimitIsDerivedFromNineteenBoundedSerialTargets() {
        let mebibyte: UInt64 = 1_024 * 1_024
        #expect(
            AppSettingsModel.maximumTrafficBytes(repetitions: 1)
                == 19 * (10 * mebibyte + 256 * 1_024) + 256 * 1_024
        )
        #expect(
            AppSettingsModel.maximumTrafficBytes(repetitions: 3)
                == 3 * (19 * (10 * mebibyte + 256 * 1_024) + 256 * 1_024)
        )
        #expect(AppSettingsModel.maximumTrafficBytes(repetitions: 4) == nil)
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
        try await waitUntil { model.state == .completed }

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
                    ),
                ]
            }
        )
        model.setBenchmarkSampleCount(3)
        model.startBenchmark()
        try await waitUntil { model.state == .completed }

        #expect(
            model.measurements.map(\.target) == [
                .bilivideo(.tencentMainland),
                .bilivideo(.alibabaMainland),
                .serverAkamai,
                .bilivideo(.tencentOverseas),
                .bilivideo(.huaweiMainland),
            ]
        )
    }

    @Test @MainActor
    func throughputTextKeepsOneFractionDigit() {
        let locale = Locale(identifier: "en_US_POSIX")
        let result = PlaybackRouteMeasurement(
            target: .serverAkamai,
            effectiveBitsPerSecond: 12_345_678,
            successfulRuns: 3,
            totalRuns: 3
        )

        #expect(
            PlaybackSourceSettingsView.resultText(
                result,
                locale: locale
            )
                == AppStrings.localized(
                    "综合 \("12.3 Mbps") · 最低 \("12.3 Mbps") · 中位 \("12.3 Mbps") · \(3)/\(3) 个样本成功",
                    locale: locale
                )
        )
    }

    @Test @MainActor
    func singleSampleResultStillShowsSuccessCount() {
        let locale = Locale(identifier: "en_US_POSIX")
        let result = PlaybackRouteMeasurement(
            target: .serverAkamai,
            effectiveBitsPerSecond: 12_345_678,
            successfulRuns: 1,
            totalRuns: 1
        )

        #expect(
            PlaybackSourceSettingsView.resultText(
                result,
                locale: locale
            )
                == AppStrings.localized(
                    "最慢片段吞吐 \("12.3 Mbps") · \(1)/\(1) 个样本成功",
                    locale: locale
                )
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
        let discovery = InvocationRecorder()
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
        try await waitUntil { await resetGate.isWaiting }
        #expect(await discovery.count == 0)

        await resetGate.release()
        try await waitUntil { await discovery.count == 1 }
    }

    @Test @MainActor
    func benchmarkFailureUsesNonIdentifyingProtocolState() async throws {
        let model = AppSettingsModel(
            store: MemoryPlaybackSourcePreferenceStore(),
            discover: { _ in [try Self.sample()] },
            run: { _, _ in throw BiliAPIError.transportFailure }
        )
        model.startBenchmark()
        try await waitUntil { model.state == .networkOrProtocolFailure }

        #expect(model.measurements.isEmpty)
        #expect(model.selection == .serverDefault)
    }

    @Test @MainActor
    func cancellationStopsWorkAndPreservesSelection() async throws {
        let cancellation = CancellationRecorder()
        let invocation = InvocationRecorder()
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
                    await cancellation.markCancelled()
                    throw CancellationError()
                }
            },
            run: { _, _ in [] }
        )
        model.startBenchmark()
        try await waitUntil { await invocation.count == 1 }
        model.cancelBenchmark()
        try await waitUntil { await cancellation.wasCancelled }
        #expect(model.state == .cancelled)
        #expect(model.selection == .serverAkamai)
    }

    @Test @MainActor
    func ownerDestructionCancelsDiscovery() async throws {
        let cancellation = CancellationRecorder()
        let invocation = InvocationRecorder()
        var model: AppSettingsModel? = AppSettingsModel(
            store: MemoryPlaybackSourcePreferenceStore(),
            discover: { _ in
                await invocation.record()
                do {
                    try await Task.sleep(for: .seconds(60))
                    return []
                } catch is CancellationError {
                    await cancellation.markCancelled()
                    throw CancellationError()
                }
            },
            run: { _, _ in [] }
        )
        weak let owner = model
        model?.startBenchmark()
        try await waitUntil { await invocation.count == 1 }
        model = nil

        try await waitUntil { await cancellation.wasCancelled }
        #expect(owner == nil)
    }

    @Test @MainActor
    func signedOutStatePreventsDiscoveryAndLogoutCancelsRunningBenchmark() async throws {
        let discovery = InvocationRecorder()
        let cancellation = CancellationRecorder()
        let reset = InvocationRecorder()
        let model = AppSettingsModel(
            store: MemoryPlaybackSourcePreferenceStore(),
            benchmarkAccess: .signedOut,
            discover: { _ in
                await discovery.record()
                do {
                    try await Task.sleep(for: .seconds(60))
                    return []
                } catch is CancellationError {
                    await cancellation.markCancelled()
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
        try await waitUntil { await discovery.count == 1 }
        model.synchronizeAuthentication(.signedOut)
        try await waitUntil { await cancellation.wasCancelled }
        try await waitUntil { await reset.count == 1 }

        #expect(model.state == .notTested)
        #expect(model.measurements.isEmpty)
    }

    @MainActor
    private func makeModel(store: MemoryPlaybackSourcePreferenceStore) -> AppSettingsModel {
        AppSettingsModel(store: store, discover: { _ in [] }, run: { _, _ in [] })
    }

    private static func sample() throws -> CDNBenchmarkDiscoveredSample {
        let primaryURL = try #require(
            URL(string: "https://a.bilivideo.com/v.m4s?t=1")
        )
        let backupURL = try #require(
            URL(string: "https://a.akamaized.net/v.m4s?h=1")
        )
        return CDNBenchmarkDiscoveredSample(
            videoRepresentation: MediaRepresentation(
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
            mediaHeaders: [:]
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

    @MainActor
    private func waitUntil(_ condition: () async -> Bool) async throws {
        while !(await condition()) {
            try await Task.sleep(for: .milliseconds(1))
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

private actor CancellationRecorder {
    private(set) var wasCancelled = false
    func markCancelled() { wasCancelled = true }
}

private actor InvocationRecorder {
    private(set) var count = 0
    func record() { count += 1 }
}

private actor ResetGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var isWaiting = false

    func wait() async {
        isWaiting = true
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func release() {
        continuation?.resume()
        continuation = nil
        isWaiting = false
    }
}
