import Foundation

@MainActor
/// 把平台无关时间线收敛为有界 heartbeat 序列；远端失败只关闭报告，不控制播放器。
public final class WatchProgressSession {
    public typealias TargetResolver =
        @MainActor (
            PlaybackItemIdentity,
            PlaybackLoadIntent
        ) -> WatchProgressTarget?
    typealias PeriodicTicks = @MainActor (Double) -> AsyncStream<Void>

    private static let pendingLimit = 8

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
    private let periodicInterval: Double
    private let timestampProvider: @Sendable () -> Int64
    private let monotonicTimeProvider: @MainActor () -> Double
    private let sessionIDProvider: @Sendable () -> String
    private let periodicTicks: PeriodicTicks

    private var cancelTimelineObservation: (@MainActor @Sendable () -> Void)?
    private var periodicTask: Task<Void, Never>?
    private var reportTask: Task<Void, Never>?
    private var inFlight: PendingReport?
    private var active: ActiveSession?
    private var pending: [PendingReport] = []
    private var generation: UInt64 = 0
    private var sequence: UInt64 = 0
    private var reportingAccessEnabled = false
    private var isSuspended = false

    public init(
        useCase: WatchProgressUseCase,
        timeline: any PlaybackTimelineProviding,
        resolveTarget: @escaping TargetResolver,
        periodicInterval: Double = 15,
        timestampProvider: @escaping @Sendable () -> Int64 = {
            Int64(Date().timeIntervalSince1970)
        },
        sessionIDProvider: @escaping @Sendable () -> String = {
            UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        }
    ) {
        self.useCase = useCase
        self.timeline = timeline
        self.resolveTarget = resolveTarget
        self.periodicInterval = periodicInterval
        self.timestampProvider = timestampProvider
        monotonicTimeProvider = { ProcessInfo.processInfo.systemUptime }
        self.sessionIDProvider = sessionIDProvider
        periodicTicks = Self.systemPeriodicTicks(every:)
        precondition(periodicInterval > 0)
    }

    init(
        useCase: WatchProgressUseCase,
        timeline: any PlaybackTimelineProviding,
        resolveTarget: @escaping TargetResolver,
        periodicInterval: Double = 15,
        timestampProvider: @escaping @Sendable () -> Int64,
        monotonicTimeProvider: @escaping @MainActor () -> Double,
        sessionIDProvider: @escaping @Sendable () -> String,
        periodicTicks: @escaping PeriodicTicks
    ) {
        self.useCase = useCase
        self.timeline = timeline
        self.resolveTarget = resolveTarget
        self.periodicInterval = periodicInterval
        self.timestampProvider = timestampProvider
        self.monotonicTimeProvider = monotonicTimeProvider
        self.sessionIDProvider = sessionIDProvider
        self.periodicTicks = periodicTicks
        precondition(periodicInterval > 0)
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
            accountPlaybackTime(&active, until: monotonicTimeProvider())
            self.active = active
        }
        stopPeriodicTimer()
    }

    public func resumeAfterSuspension() {
        guard isSuspended else { return }
        isSuspended = false
        if var active {
            active.lastAccountingTime = monotonicTimeProvider()
            self.active = active
        }
        startPeriodicTimer()
    }

    func waitForCurrentReportForTesting() async {
        await reportTask?.value
    }

    func sendPeriodicHeartbeatForTesting() {
        sendPeriodicHeartbeat()
    }

    func pendingReportsForTesting() -> [WatchProgressReport] {
        pending.map(\.report)
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

        if active?.lastSnapshot.state == .ended, snapshot.state == .playing {
            active = nil
        }

        guard var active else {
            guard snapshot.state == .playing else { return }
            generation &+= 1
            let now = monotonicTimeProvider()
            let started = ActiveSession(
                target: target,
                sessionStartTimestamp: timestampProvider(),
                sessionID: sessionIDProvider(),
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
        accountPlaybackTime(&active, until: monotonicTimeProvider())
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
        let ticks = periodicTicks(periodicInterval)
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
        accountPlaybackTime(&session, until: monotonicTimeProvider())
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
                elapsedSeconds: max(0, monotonicTimeProvider() - session.monotonicStart),
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

    private static func systemPeriodicTicks(every interval: Double) -> AsyncStream<Void> {
        AsyncStream { continuation in
            let task = Task {
                do {
                    while !Task.isCancelled {
                        try await Task.sleep(for: .seconds(interval))
                        try Task.checkCancellation()
                        continuation.yield(())
                    }
                } catch {
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
