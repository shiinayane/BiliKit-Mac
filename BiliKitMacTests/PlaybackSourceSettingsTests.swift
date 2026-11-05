import BiliAPI
import BiliAuthFeature
import BiliModels
import BiliPlayback
import Foundation
import Synchronization
import Testing

@testable import BiliKit

/// 手动线路与 HDR 开关持久化、损坏时回退默认（HDR 开关缺失或损坏时按开）、已移除的响度开关残留被清掉，
/// 测速结果只用于排序展示、从不改动手动选择。
///
/// 测速只在所有窗口都已登录时进行；取消、登出与 owner 释放都停止测速，失败只映射为不可识别的状态。
@Suite(.timeLimit(.minutes(1)))
struct PlaybackSourceSettingsTests {
    @Test
    func everySelectionAndBenchmarkTargetHasADisplayName() {
        for selection in PlaybackSourceSelection.allCases {
            #expect(!selection.displayName.isEmpty)
        }
        for target in PlaybackRouteTarget.allCases {
            #expect(!target.appDisplayName.isEmpty)
        }
        #expect(
            PlaybackSourceSelection.serverAkamai.displayName
                == PlaybackRouteTarget.serverAkamai.appDisplayName
        )
    }

    @Test @MainActor
    func storeRestoresTheSavedRecord() {
        withIsolatedDefaults { defaults in
            let store = UserDefaultsPlaybackSourcePreferenceStore(defaults: defaults)
            #expect(store.load() == .defaults)

            let saved = PlaybackSourcePreferenceRecord(
                selection: .huaweiMainland,
                hdrVideoEnabled: false
            )
            store.save(saved)
            #expect(store.load() == saved)
        }
    }

    /// schema 或线路损坏、类型错写时整条记录回退默认。
    @Test(
        arguments: [
            ("playbackSourcePreference.selection", "unknown"),
            ("playbackSourcePreference.selection", 1),
            ("playbackSourcePreference.schema", 99),
            ("playbackSourcePreference.schema", "1"),
            ("playbackSourcePreference.schema", true),
            ("playbackSourcePreference.schema", 1.9)
        ] as [(String, any Sendable)]
    )
    @MainActor
    func storeFallsBackOnDamagedValues(key: String, damaged: any Sendable) {
        withIsolatedDefaults { defaults in
            let store = UserDefaultsPlaybackSourcePreferenceStore(defaults: defaults)
            store.save(
                PlaybackSourcePreferenceRecord(selection: .huaweiMainland, hdrVideoEnabled: true)
            )
            // 先移除再写：已存的 schema 是整数 1，UserDefaults 视 `true` 与它相等而不覆盖。
            defaults.removeObject(forKey: key)
            defaults.set(damaged, forKey: key)

            #expect(store.load() == .defaults)
        }
    }

    /// HDR 开关独立于线路：缺失或类型错写时按开，不影响已存的线路。
    @Test(arguments: [nil, "false", 0] as [(any Sendable)?])
    @MainActor
    func hdrToggleDefaultsOnWhenMissingOrDamaged(damaged: (any Sendable)?) {
        withIsolatedDefaults { defaults in
            let store = UserDefaultsPlaybackSourcePreferenceStore(defaults: defaults)
            store.save(
                PlaybackSourcePreferenceRecord(selection: .serverAkamai, hdrVideoEnabled: false)
            )
            defaults.removeObject(forKey: "playback.hdrVideo.enabled")
            if let damaged {
                defaults.set(damaged, forKey: "playback.hdrVideo.enabled")
            }

            #expect(
                store.load()
                    == PlaybackSourcePreferenceRecord(
                        selection: .serverAkamai,
                        hdrVideoEnabled: true
                    )
            )
        }
    }

    @Test @MainActor
    func speedTextUsesOneFractionDigitWithLocaleGrouping() {
        let result = PlaybackRouteMeasurement(
            target: .serverAkamai,
            effectiveBitsPerSecond: 1_234_500_000
        )
        let text = PlaybackSourceSettingsView.resultText(
            result,
            locale: Locale(identifier: "en_US")
        )
        #expect(text.contains("1,234.5 Mbps"))
    }

    /// 响度均一化已移除：先后两版开关的残留在读取时清掉，不影响线路选择。
    @Test(arguments: [
        "playback.loudnessNormalization.enabled",
        "playback.loudnessAttenuation.enabled"
    ])
    @MainActor
    func retiredLoudnessSettingsAreRemovedOnLoad(key: String) {
        withIsolatedDefaults { defaults in
            let store = UserDefaultsPlaybackSourcePreferenceStore(defaults: defaults)
            let saved = PlaybackSourcePreferenceRecord(
                selection: .serverAkamai,
                hdrVideoEnabled: true
            )
            store.save(saved)
            defaults.set(true, forKey: key)

            #expect(store.load() == saved)
            #expect(defaults.object(forKey: key) == nil)
        }
    }

    @Test @MainActor
    func benchmarkResultNeverChangesManualSelection() async throws {
        let store = MemoryPlaybackSourcePreferenceStore(
            record: PlaybackSourcePreferenceRecord(
                selection: .alibabaMainland,
                hdrVideoEnabled: true
            )
        )
        let model = makeSettingsModel(
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
        let model = makeSettingsModel(
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
        let model = makeSettingsModel(signedIn: false)
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
        let model = makeSettingsModel(
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
        let model = makeSettingsModel(
            discover: { _ in
                if let discoveryError = failure.discoveryError {
                    throw PlaybackRouteBenchmarkOperationError.mappingDiscoveryError(discoveryError)
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
            record: PlaybackSourcePreferenceRecord(selection: .serverAkamai, hdrVideoEnabled: true)
        )
        let model = makeSettingsModel(
            store: store,
            discover: Self.discoverUntilCancelled(started: invocation, cancelled: cancellation),
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
        var model: AppSettingsModel? = makeSettingsModel(
            discover: Self.discoverUntilCancelled(started: invocation, cancelled: cancellation),
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
        let model = makeSettingsModel(
            signedIn: false,
            discover: Self.discoverUntilCancelled(started: discovery, cancelled: cancellation),
            resetDiscovery: { await reset.record() },
            run: { _, _ in [] }
        )

        let window = UUID()
        model.synchronizeAuthentication(.signedOut, ownerID: window)
        model.startBenchmark()
        #expect(await discovery.count == 0)

        model.synchronizeAuthentication(.signedIn, ownerID: window)
        model.startBenchmark()
        await discovery.wait()
        model.synchronizeAuthentication(.signedOut, ownerID: window)
        await cancellation.wait()
        await reset.wait()

        #expect(model.state == .notTested)
        #expect(model.measurements.isEmpty)
    }

    /// 设置模型；`signedIn` 时以一个已登录窗口登记测速权限，与生产里窗口出现后的同步一致。
    @MainActor
    private func makeSettingsModel(
        store: MemoryPlaybackSourcePreferenceStore = MemoryPlaybackSourcePreferenceStore(),
        signedIn: Bool = true,
        discover: @escaping AppSettingsModel.Discover = { _ in [] },
        resetDiscovery: @escaping AppSettingsModel.ResetDiscovery = {},
        run: @escaping AppSettingsModel.Run = { _, _ in [] }
    ) -> AppSettingsModel {
        let model = AppSettingsModel(
            store: store,
            discover: discover,
            resetDiscovery: resetDiscovery,
            run: run
        )
        if signedIn {
            model.synchronizeAuthentication(.signedIn, ownerID: UUID())
        }
        return model
    }

    /// 样本发现：开始时记一次 `started`，然后挂起到任务被取消，取消时记一次 `cancelled` 再抛出取消。
    private static func discoverUntilCancelled(
        started: TestEventCounter,
        cancelled: TestEventCounter
    ) -> AppSettingsModel.Discover {
        { _ in
            await started.record()
            do {
                try await Task.sleep(for: .seconds(60))
                return []
            } catch is CancellationError {
                await cancelled.record()
                throw CancellationError()
            }
        }
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
}

private enum BenchmarkTestError: Error {
    case transportFailure
}

enum SettingsBenchmarkFailureFixture: CaseIterable, Sendable {
    case transport
    case missingCredential
    case invalidCredential
    case unavailableCredential
    case riskControlStatus
    case riskControlVoucher

    /// 样本发现阶段抛出的 API 错误；nil 表示发现成功、测速运行失败。
    var discoveryError: BiliAPIError? {
        switch self {
        case .transport: nil
        case .missingCredential: .authorizationRequired
        case .invalidCredential: .authenticationInvalid
        case .unavailableCredential: .authorizationUnavailable
        case .riskControlStatus: .httpStatus(412)
        case .riskControlVoucher: .riskControlVoucher
        }
    }

    var expectedState: PlaybackRouteBenchmarkState {
        switch self {
        case .transport: .networkOrProtocolFailure
        case .missingCredential: .authenticationRequired
        case .invalidCredential: .authenticationInvalid
        case .unavailableCredential: .authenticationUnavailable
        case .riskControlStatus, .riskControlVoucher: .restricted
        }
    }
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
