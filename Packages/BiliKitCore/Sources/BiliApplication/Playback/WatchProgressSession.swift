import Foundation

/// 把平台无关时间线收敛为有界 heartbeat 序列；远端失败只关闭报告，不控制播放器。
///
/// 每个窗口一个，由 App 的 `WatchProgressWindowConnection` 创建，并驱动 `start`／`stop`、
/// 系统睡眠时的 `suspend`／`resumeAfterSuspension` 与账户范围变化时的 `setReportingAccess`；
/// MainActor 隔离。拥有时间线同步观察、周期 tick Task、唯一的在途写入 Task 与有界待发队列；
/// 不拥有写入串行化与认证代次（进程级 `SerializedWatchProgressRepository`），也不拥有时间线本身。
///
/// 取消与清理：写入开关关闭时取消周期 Task 与在途写入并清空队列；`stop` 先停止观察与周期 Task，
/// 再为当前会话入队最终 ended，不取消在途写入，让退出边界尽量送达；`deinit` 取消剩余 Task。见
/// SECURITY-MODEL §3。
@MainActor
public final class WatchProgressSession {
    public typealias TargetResolver =
        @MainActor (
            PlaybackItemIdentity,
            PlaybackLoadIntent
        ) -> WatchProgressTarget?

    /// 会话读取的墙钟时间戳、单调时间、会话 ID 与周期 tick 来源，是本会话的时钟边界；App 传 `.live`。
    public struct Environment: Sendable {
        let timestamp: @Sendable () -> Int64
        let monotonicTime: @MainActor @Sendable () -> Double
        let sessionID: @Sendable () -> String
        let periodicTicks: @MainActor @Sendable (Double) -> AsyncStream<Void>

        public static var live: Environment {
            Environment(
                timestamp: { Int64(Date().timeIntervalSince1970) },
                monotonicTime: { ProcessInfo.processInfo.systemUptime },
                sessionID: {
                    UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
                },
                periodicTicks: { PeriodicTicks.system(every: .seconds($0)) }
            )
        }
    }

    /// 每个窗口的待发报告上限：周期报告只保留最新、边界挤掉周期、ended 一定入队。
    ///
    /// 调小会在网络慢时更早合并中间的暂停与恢复，调大只会积压更多过时的进度。
    private static let pendingLimit = 8
    /// 播放中 periodic heartbeat 的间隔；调小会增加写请求次数，调大会让服务端记录的进度更滞后。
    private static let periodicIntervalSeconds = 15.0

    /// 一次报告会话：从开始播放到结束（ended、换项、停止或登出）为止的目标、会话 ID、generation，
    /// 以及累计的播放时长与最大位置。
    ///
    /// 由 `active` 唯一持有，结束时置 nil。`reportingDisabled` 在本会话任一报告失败或被取消后置位，
    /// 之后不再入队；`didEnqueueEnded` 在会话到达 ended 时置位（报告已停用时并不真的入队），保证每个会话至多一次
    /// ended，置位后再开始播放就另起会话。
    private struct ActiveSession {
        let target: WatchProgressTarget
        let sessionStartTimestamp: Int64
        let sessionID: String
        let generation: UInt64
        let monotonicStart: Double
        var lastAccountingTime: Double
        var lastSnapshot: PlaybackTimelineSnapshot
        var playedSeconds = 0.0
        var maximumPositionSeconds = 0.0
        var reportingDisabled = false
        var didEnqueueEnded = false
    }

    private struct PendingReport {
        let report: WatchProgressReport
    }

    private enum ReportOutcome {
        case accepted
        case cancelled
        case failed(WatchProgressError)
    }

    private let useCase: WatchProgressUseCase
    private let timeline: any PlaybackTimelineProviding
    private let resolveTarget: TargetResolver
    private let environment: Environment

    private var cancelTimelineObservation: (@MainActor @Sendable () -> Void)?
    private var periodicTask: Task<Void, Never>?
    /// 唯一的在途写入 Task；与 `inFlight` 同时设置与清空，为 nil 且队列非空时 `drainPendingReport`
    /// 发出下一个。
    private var reportTask: Task<Void, Never>?
    private var inFlight: PendingReport?
    private var active: ActiveSession?
    private var pending: [PendingReport] = []
    /// 报告会话代次：每开始一个报告会话、以及写入开关变化时以 `&+=` 递增，并写进该会话的每个报告。
    ///
    /// 待发队列按它合并同一会话的周期报告与 ended；写入失败或被取消时，
    /// 按它移除同一会话排队中的报告，且只在当前会话仍是该代次时关闭报告。
    private var generation: UInt64 = 0
    /// 报告序号：每次生成报告前递增，跨会话单调。
    ///
    /// `finish` 以它确认完成的是仍在途的那次写入；登出时被丢弃的旧 Task 完成后序号与 `inFlight`
    /// 不匹配，结果被忽略。
    private var sequence: UInt64 = 0
    private var reportingAccessEnabled = false
    private var isSuspended = false

    public init(
        useCase: WatchProgressUseCase,
        timeline: any PlaybackTimelineProviding,
        resolveTarget: @escaping TargetResolver,
        environment: Environment
    ) {
        self.useCase = useCase
        self.timeline = timeline
        self.resolveTarget = resolveTarget
        self.environment = environment
    }

    deinit {
        if let cancelTimelineObservation {
            Task { @MainActor in cancelTimelineObservation() }
        }
        periodicTask?.cancel()
        reportTask?.cancel()
    }

    public func start() {
        guard cancelTimelineObservation == nil else { return }
        cancelTimelineObservation = timeline.observeTimeline { [weak self] snapshot in
            self?.consume(snapshot)
        }
    }

    /// 已解析账户 scope 是唯一写入开关；游客与 unresolved 不创建 report 或触发 repository。
    public func setReportingAccess(signedIn: Bool) {
        guard signedIn != reportingAccessEnabled else { return }
        reportingAccessEnabled = signedIn
        generation &+= 1
        if signedIn {
            consume(timeline.currentTimelineSnapshot)
        } else {
            stopPeriodicTimer()
            reportTask?.cancel()
            reportTask = nil
            inFlight = nil
            pending.removeAll(keepingCapacity: false)
            active = nil
        }
    }

    /// 对应窗口/详情 unload：保留当前位置的最终 ended，再停止时间线消费。
    public func stop() {
        cancelTimelineObservation?()
        cancelTimelineObservation = nil
        stopPeriodicTimer()
        finishActiveSession(completed: active?.lastSnapshot.state == .ended)
    }

    /// 系统睡眠不构造播放边界；只冻结真实播放计时与周期 timer。
    public func suspend() {
        guard !isSuspended else { return }
        isSuspended = true
        if var active {
            accountPlaybackTime(&active, until: environment.monotonicTime())
            self.active = active
        }
        stopPeriodicTimer()
    }

    public func resumeAfterSuspension() {
        guard isSuspended else { return }
        isSuspended = false
        if var active {
            active.lastAccountingTime = environment.monotonicTime()
            self.active = active
        }
        startPeriodicTimer()
    }

    private func consume(_ snapshot: PlaybackTimelineSnapshot) {
        guard reportingAccessEnabled, !isSuspended,
            let identity = snapshot.identity,
            let loadIntent = snapshot.loadIntent,
            let target = resolveTarget(identity, loadIntent)
        else {
            if reportingAccessEnabled, !isSuspended {
                stopPeriodicTimer()
                finishActiveSession(completed: active?.lastSnapshot.state == .ended)
            }
            return
        }

        if active?.target != target {
            stopPeriodicTimer()
            finishActiveSession(completed: active?.lastSnapshot.state == .ended)
        }

        // 已到达 ended 的会话不再继续：播完后跳回开头或拖回去再播（含单集循环的重播）是新的一次观看。跳转先把
        // ended 改成 paused，起播时还常先报 buffering；只看上一个快照是不是 ended、或只认 playing，都会让旧会话
        // 再报一次 resumed。这里在缓冲时就结束旧会话，等真正 playing 才开新会话。
        if active?.didEnqueueEnded == true, Self.isHeartbeatActive(snapshot.state) {
            active = nil
        }

        guard var active else {
            guard snapshot.state == .playing else { return }
            generation &+= 1
            let now = environment.monotonicTime()
            let started = ActiveSession(
                target: target,
                sessionStartTimestamp: environment.timestamp(),
                sessionID: environment.sessionID(),
                generation: generation,
                monotonicStart: now,
                lastAccountingTime: now,
                lastSnapshot: snapshot,
                maximumPositionSeconds: snapshot.positionSeconds
            )
            self.active = started
            enqueue(event: .started, snapshot: snapshot)
            startPeriodicTimer()
            return
        }

        let previous = active.lastSnapshot
        accountPlaybackTime(&active, until: environment.monotonicTime())
        active.maximumPositionSeconds = max(
            active.maximumPositionSeconds,
            snapshot.positionSeconds
        )
        active.lastSnapshot = snapshot
        self.active = active

        let boundaryEvent: WatchProgressEvent? =
            if Self.isHeartbeatActive(previous.state), snapshot.state == .paused {
                .paused
            } else if previous.state == .paused,
                Self.isHeartbeatActive(snapshot.state)
            {
                .resumed
            } else if snapshot.state == .ended, previous.state != .ended {
                .ended
            } else {
                nil
            }

        guard let boundaryEvent else { return }
        switch boundaryEvent {
        case .paused:
            stopPeriodicTimer()
        case .resumed:
            startPeriodicTimer()
        case .ended:
            stopPeriodicTimer()
            self.active?.didEnqueueEnded = true
        case .started, .periodic:
            break
        }
        enqueue(
            event: boundaryEvent,
            snapshot: snapshot,
            completed: boundaryEvent == .ended
        )
    }

    private func accountPlaybackTime(_ session: inout ActiveSession, until now: Double) {
        defer { session.lastAccountingTime = max(session.lastAccountingTime, now) }
        guard now.isFinite, now >= session.lastAccountingTime,
            session.lastSnapshot.state == .playing,
            session.lastSnapshot.rate > 0
        else { return }
        session.playedSeconds += now - session.lastAccountingTime
    }

    private func startPeriodicTimer() {
        guard periodicTask == nil, reportingAccessEnabled, !isSuspended,
            let active, !active.reportingDisabled,
            Self.isHeartbeatActive(active.lastSnapshot.state)
        else { return }
        let ticks = environment.periodicTicks(Self.periodicIntervalSeconds)
        periodicTask = Task { [weak self] in
            for await _ in ticks {
                guard !Task.isCancelled else { return }
                self?.sendPeriodicHeartbeat()
            }
        }
    }

    private func stopPeriodicTimer() {
        periodicTask?.cancel()
        periodicTask = nil
    }

    private func sendPeriodicHeartbeat() {
        guard let active, !active.reportingDisabled,
            reportingAccessEnabled, !isSuspended,
            Self.isHeartbeatActive(active.lastSnapshot.state)
        else {
            stopPeriodicTimer()
            return
        }
        enqueue(event: .periodic, snapshot: active.lastSnapshot)
    }

    private func finishActiveSession(completed: Bool) {
        guard var session = active else { return }
        active = nil
        guard !session.reportingDisabled, !session.didEnqueueEnded else { return }
        session.didEnqueueEnded = true
        enqueue(
            event: .ended,
            snapshot: session.lastSnapshot,
            completed: completed,
            suppliedSession: session
        )
    }

    private func enqueue(
        event: WatchProgressEvent,
        snapshot: PlaybackTimelineSnapshot,
        completed: Bool = false,
        suppliedSession: ActiveSession? = nil
    ) {
        guard reportingAccessEnabled, var session = suppliedSession ?? active,
            !session.reportingDisabled
        else { return }
        accountPlaybackTime(&session, until: environment.monotonicTime())
        if suppliedSession == nil {
            active = session
        }
        sequence &+= 1
        guard
            let report = WatchProgressReport(
                target: session.target,
                event: event,
                sessionStartTimestamp: session.sessionStartTimestamp,
                sessionID: session.sessionID,
                generation: session.generation,
                sequence: sequence,
                positionSeconds: snapshot.positionSeconds,
                maximumPositionSeconds: max(
                    session.maximumPositionSeconds,
                    snapshot.positionSeconds
                ),
                durationSeconds: snapshot.durationSeconds,
                elapsedSeconds: max(0, environment.monotonicTime() - session.monotonicStart),
                playedSeconds: session.playedSeconds,
                completed: completed
            )
        else { return }

        insertBounded(PendingReport(report: report))
        drainPendingReport()
    }

    /// 周期只保留同会话最新值；边界挤掉周期。
    ///
    /// 饱和时中间暂停/恢复按最新状态合并，
    /// ended 最终一定入队，并优先淘汰较旧的非终态边界。
    private func insertBounded(_ request: PendingReport) {
        let report = request.report
        if report.event == .periodic {
            pending.removeAll {
                $0.report.event == .periodic
                    && $0.report.generation == report.generation
            }
            guard pending.count < Self.pendingLimit else { return }
            pending.append(request)
            return
        }

        pending.removeAll { $0.report.event == .periodic }
        if report.event == .ended {
            pending.removeAll {
                $0.report.event == .ended
                    && $0.report.generation == report.generation
            }
            while pending.count >= Self.pendingLimit {
                if let index = pending.firstIndex(where: {
                    $0.report.event != .ended
                }) {
                    pending.remove(at: index)
                } else {
                    pending.removeFirst()
                }
            }
            pending.append(request)
            return
        }

        guard pending.count < Self.pendingLimit else {
            if let index = pending.lastIndex(where: {
                $0.report.generation == report.generation
                    && $0.report.event != .started
                    && $0.report.event != .ended
            }) {
                pending.remove(at: index)
                pending.append(request)
            }
            return
        }
        pending.append(request)
    }

    private func drainPendingReport() {
        guard reportTask == nil, !pending.isEmpty else { return }
        let request = pending.removeFirst()
        inFlight = request
        reportTask = Task { [self] in
            let outcome: ReportOutcome
            do {
                try await useCase.report(request.report)
                outcome = .accepted
            } catch is CancellationError {
                outcome = .cancelled
            } catch let error as WatchProgressError {
                outcome = .failed(error)
            } catch {
                outcome = .failed(.unavailable)
            }
            finish(request: request, outcome: outcome)
        }
    }

    private func finish(request: PendingReport, outcome: ReportOutcome) {
        guard inFlight?.report.sequence == request.report.sequence else { return }
        inFlight = nil
        reportTask = nil

        switch outcome {
        case .accepted:
            break
        case .cancelled, .failed:
            pending.removeAll {
                $0.report.generation == request.report.generation
            }
            if active?.generation == request.report.generation,
                active?.sessionID == request.report.sessionID
            {
                active?.reportingDisabled = true
                stopPeriodicTimer()
            }
        }
        drainPendingReport()
    }

    private static func isHeartbeatActive(_ state: PlaybackTimelineState) -> Bool {
        state == .playing || state == .buffering
    }
}
