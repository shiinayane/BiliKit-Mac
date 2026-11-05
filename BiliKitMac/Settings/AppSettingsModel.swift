import BiliAPI
import BiliApplication
import BiliPlayback
import Foundation
import Observation

/// 线路测速在设置窗口里显示的状态，只存在于内存；关闭设置窗口或失去测速权限时回到 `notTested`。
enum PlaybackRouteBenchmarkState: Sendable, Equatable {
    case notTested
    case findingSample
    case testing(completed: Int, total: Int)
    case completed
    case cancelled
    case sampleUnavailable
    /// 认证三态与内容页一致；测速只提示，不触发账户复核。
    case authenticationRequired
    case authenticationInvalid
    case authenticationUnavailable
    case restricted
    case networkOrProtocolFailure

    var isRunning: Bool {
        switch self {
        case .findingSample, .testing: true
        default: false
        }
    }
}

/// 测速权限：各主窗口按自己的会话阶段报告（`AppRootView.benchmarkAccess`），由 `AppSettingsModel`
/// 汇总，只有已登录才允许开始测速。
enum PlaybackRouteBenchmarkAccess: Sendable, Equatable {
    case resolving, signedOut, signedIn
    var allowsBenchmark: Bool { self == .signedIn }
}

/// 测速流程里需要单独提示的失败，各自对应一个 `PlaybackRouteBenchmarkState`。
enum PlaybackRouteBenchmarkOperationError: Error {
    case authenticationRequired
    case authenticationInvalid
    case authenticationUnavailable
    case restricted

    /// 样本发现阶段的 API 认证类失败按无凭据、凭据失效、本地凭据读不到三态区分，风控收窄为受限；
    /// 其他错误（含取消）原样传播。
    static func mappingDiscoveryError(_ error: any Error) -> any Error {
        guard let apiError = error as? BiliAPIError else { return error }
        switch apiError {
        case .authorizationRequired:
            return Self.authenticationRequired
        case .authenticationInvalid:
            return Self.authenticationInvalid
        case .authorizationUnavailable:
            return Self.authenticationUnavailable
        default:
            return apiError.isRiskControlRestriction ? Self.restricted : apiError
        }
    }

    var state: PlaybackRouteBenchmarkState {
        switch self {
        case .authenticationRequired: .authenticationRequired
        case .authenticationInvalid: .authenticationInvalid
        case .authenticationUnavailable: .authenticationUnavailable
        case .restricted: .restricted
        }
    }
}

/// 设置窗口的模型：播放线路选择的读写，以及线路测速的运行与结果。
///
/// 进程唯一，由 `ProcessComposition` 构造；各窗口的播放引擎每次新 load 读取
/// `playbackSourcePreference`。偏好经 `PlaybackSourcePreferenceStoring` 持久化；
/// 测速状态与结果只在内存，设置窗口消失（`closeSettings()`）时清空，从不自动改选（见
/// docs/ARCHITECTURE.md「播放线路偏好与测速」）。不拥有样本发现与测速实现，
/// 只持有构造时注入的闭包（生产实现用进程级测速 API client）。
///
/// 拥有测速 `task` 与样本重置的 `discoveryResetTask`：开始新测速、取消、
/// 关闭设置窗口或失去测速权限时取消前者，`deinit` 两者都取消；新测速先等上一次的样本重置完成。
/// 全部在 MainActor 上运行。
@MainActor
@Observable
final class AppSettingsModel {
    typealias Discover = @Sendable (Int) async throws -> [PlaybackRouteBenchmarkSample]
    typealias ResetDiscovery = @Sendable () async -> Void
    typealias Run =
        @Sendable (
            [PlaybackRouteBenchmarkSample],
            @escaping @Sendable (Int, Int) async -> Void
        ) async throws -> [PlaybackRouteMeasurement]

    private(set) var state: PlaybackRouteBenchmarkState = .notTested
    private(set) var benchmarkAccess: PlaybackRouteBenchmarkAccess = .resolving
    private(set) var record: PlaybackSourcePreferenceRecord
    private(set) var measurements: [PlaybackRouteMeasurement] = []
    private(set) var benchmarkSampleCount = 1
    @ObservationIgnored private let store: any PlaybackSourcePreferenceStoring
    @ObservationIgnored private var discover: Discover
    @ObservationIgnored private var resetDiscovery: ResetDiscovery
    @ObservationIgnored private var run: Run
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var discoveryResetTask: Task<Void, Never>?
    /// 每次开始测速与取消在途测速时换成新值；任务的进度、结果、失败与取消回写都先比对，不等就丢弃，
    /// 被取代的任务不能覆盖新状态。
    @ObservationIgnored private var generation = UUID()
    /// 各主窗口报告的测速权限，键是窗口的 `benchmarkAuthenticationOwnerID`，关窗时注销。
    ///
    /// 按最保守的结果汇总：任一窗口未登录（含正在登出）即不允许测速，否则任一窗口已登录即允许，
    /// 其余（含还没有窗口报告）为确认中。
    @ObservationIgnored private var authenticationAccessByOwner:
        [UUID: PlaybackRouteBenchmarkAccess] = [:]

    /// `discover`、`resetDiscovery` 与 `run` 是样本发现与测速的网络边界，由 `ProcessComposition`
    /// 接到测速 API client 与 `BilivideoRouteBenchmark`。
    init(
        store: any PlaybackSourcePreferenceStoring,
        discover: @escaping Discover,
        resetDiscovery: @escaping ResetDiscovery,
        run: @escaping Run
    ) {
        self.store = store
        self.discover = discover
        self.resetDiscovery = resetDiscovery
        self.run = run
        record = store.load()
    }

    deinit {
        task?.cancel()
        discoveryResetTask?.cancel()
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
            save(
                PlaybackSourcePreferenceRecord(
                    selection: newValue,
                    hdrVideoEnabled: record.hdrVideoEnabled
                )
            )
        }
    }

    /// “HDR 视频”开关；与线路选择一样只影响之后新开始的播放。
    var hdrVideoEnabled: Bool {
        get { record.hdrVideoEnabled }
        set {
            save(
                PlaybackSourcePreferenceRecord(
                    selection: record.selection,
                    hdrVideoEnabled: newValue
                )
            )
        }
    }

    private func save(_ updated: PlaybackSourcePreferenceRecord) {
        record = updated
        store.save(updated)
    }

    var playbackSourcePreference: PlaybackSourcePreference {
        record.selection.preference
    }

    func setBenchmarkSampleCount(_ value: Int) {
        guard !state.isRunning,
            PlaybackRouteBenchmarkPolicy.supportedSampleCounts.contains(value)
        else { return }
        benchmarkSampleCount = value
    }

    /// 一次测速的流量上限，设置界面据此显示“最多约 N MiB”；样本数不在支持范围内时返回 nil。
    static func maximumTrafficBytes(repetitions: Int) -> UInt64? {
        guard PlaybackRouteBenchmarkPolicy.supportedSampleCounts.contains(repetitions) else {
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
            } catch let error as PlaybackRouteBenchmarkOperationError {
                self?.applyFailure(error.state, generation: currentGeneration)
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
