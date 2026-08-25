@preconcurrency import AVFoundation
import BiliApplication
import Foundation
import Synchronization
import os

enum MomentaryRateRestorationAction: Equatable {
    case none
    case setCurrentRate
    case resumeAtDefaultRate
}

enum MomentaryRateRestorationPolicy {
    static func action(
        timeControlStatus: AVPlayer.TimeControlStatus,
        currentRate: Float,
        momentaryRate: Float
    ) -> MomentaryRateRestorationAction {
        let stillUsesMomentaryRate =
            abs(currentRate - momentaryRate) < 0.01
        switch timeControlStatus {
        case .paused:
            return .none
        case .playing:
            return stillUsesMomentaryRate ? .setCurrentRate : .none
        case .waitingToPlayAtSpecifiedRate:
            return currentRate == 0 || stillUsesMomentaryRate
                ? .resumeAtDefaultRate : .none
        @unknown default:
            return .none
        }
    }
}

final class PlaybackInteractionTracker: Sendable {
    private struct State {
        var revision: UInt64 = 0
        var internalSeekTarget: Double?
        var internalSeekInFlight = false
        var internalPlayStartInFlight = false
        var hasPlaybackStarted = false
        var observedNonPausedDuringInitialSeek = false
    }

    private let state = Mutex(State())

    var hasObservedInteraction: Bool {
        revision > 0
    }

    var revision: UInt64 {
        state.withLock { $0.revision }
    }

    func markObserved() {
        state.withLock {
            $0.revision &+= 1
            $0.internalSeekTarget = nil
            $0.internalSeekInFlight = false
            $0.internalPlayStartInFlight = false
            $0.observedNonPausedDuringInitialSeek = false
        }
    }

    func allowInternalSeek(to positionSeconds: Double) {
        state.withLock {
            $0.internalSeekTarget = positionSeconds
            $0.internalSeekInFlight = true
            $0.observedNonPausedDuringInitialSeek = false
        }
    }

    func markObservedAllowingInternalSeek(to positionSeconds: Double) {
        state.withLock {
            $0.revision &+= 1
            $0.internalSeekTarget = positionSeconds
            $0.internalSeekInFlight = true
            $0.observedNonPausedDuringInitialSeek = false
        }
    }

    /// 新 item 的系统初始 paused 不算用户操作；会话已有交互后，paused 必须使在途提交失效。
    func observeTimeControlStatus(
        isPaused: Bool,
        isPlaying: Bool,
        playbackRate: Float
    ) {
        state.withLock {
            if $0.internalPlayStartInFlight {
                if isPaused {
                    $0.revision &+= 1
                    $0.internalPlayStartInFlight = false
                } else if isPlaying {
                    $0.hasPlaybackStarted = true
                    $0.internalPlayStartInFlight = false
                }
                return
            }
            if $0.internalSeekInFlight, !isPaused {
                if isPlaying || playbackRate > 0 {
                    $0.observedNonPausedDuringInitialSeek = true
                }
                return
            }
            if $0.internalSeekInFlight,
                isPaused,
                $0.observedNonPausedDuringInitialSeek
            {
                $0.revision &+= 1
                $0.internalSeekTarget = nil
                $0.internalSeekInFlight = false
                $0.observedNonPausedDuringInitialSeek = false
                return
            }
            guard
                !isPaused || $0.revision > 0 || $0.hasPlaybackStarted
            else { return }
            $0.revision &+= 1
            if isPlaying {
                $0.hasPlaybackStarted = true
            }
            $0.internalSeekTarget = nil
            $0.internalSeekInFlight = false
            $0.observedNonPausedDuringInitialSeek = false
        }
    }

    func allowInternalPlayStart() {
        state.withLock { $0.internalPlayStartInFlight = true }
    }

    func completeInternalSeek(at positionSeconds: Double) {
        state.withLock {
            $0.internalSeekTarget = positionSeconds
            $0.internalSeekInFlight = false
            $0.observedNonPausedDuringInitialSeek = false
        }
    }

    func cancelInternalSeek() {
        state.withLock {
            $0.internalSeekTarget = nil
            $0.internalSeekInFlight = false
            $0.observedNonPausedDuringInitialSeek = false
        }
    }

    /// 内部首次定位允许同一目标产生一个或多个系统 time-jump；其他跳变立即记为用户意图。
    func observeTimeJump(at positionSeconds: Double) {
        state.withLock {
            if $0.internalSeekInFlight {
                // 准备阶段由 player host 禁用原生控制；受控外部 seek 会在命令入口先
                // 推进 revision，因此这里不能按 HLS 实际落点与目标的距离猜测来源。
                return
            }
            if $0.revision == 0,
                $0.internalSeekTarget == nil,
                positionSeconds <= 0.25
            {
                return
            }
            if let target = $0.internalSeekTarget,
                abs(target - positionSeconds) <= 0.5
            {
                return
            }
            $0.revision &+= 1
            $0.internalSeekTarget = nil
        }
    }
}

@MainActor
/// 把 AVPlayer/KVO/notification 事件投影为平台无关、identity-safe 的播放时间线。
///
/// 所有 callback 都同时核对当前 `AVPlayerItem` 与 item token；observer bag 在替换、失败和
/// clear 时统一释放，避免旧 item 继续推进字幕或弹幕。
final class AVPlayerTimelineAdapter {
    private struct PendingSeek {
        let operationID: UUID
        let targetSeconds: Double
        var observedLanding = false
    }

    private struct SeekLanding {
        let operationID: UUID
        let positionSeconds: Double
    }

    private struct MomentaryRateSession {
        let id: UUID
        let item: AVPlayerItem
        let rate: Float
    }

    var onEnded: (@MainActor () -> Void)?
    var onFailed: (@MainActor () -> Void)?
    var onSeekSupersededByExternalJump: (@MainActor (UUID) -> Void)?

    var currentSnapshot: PlaybackTimelineSnapshot {
        store.currentSnapshot
    }

    var hasObservedPlaybackInteraction: Bool {
        interactionTracker.hasObservedInteraction
    }

    var playbackInteractionRevision: UInt64 {
        interactionTracker.revision
    }

    private let player: AVPlayer
    private let store = PlaybackTimelineStore()
    private let observers = PlayerTimelineObserverBag()
    private var token: PlaybackTimelineItemToken?
    private var failedToken: PlaybackTimelineItemToken?
    private var momentaryRateSession: MomentaryRateSession?
    private var pendingSeek: PendingSeek?
    private var completedSeekLanding: SeekLanding?
    private var staleSeekLandings: [SeekLanding] = []
    private var interactionTracker = PlaybackInteractionTracker()

    init(player: AVPlayer) {
        self.player = player
        let initialRate = Self.validatedPlaybackRate(player.defaultRate) ?? 1
        player.defaultRate = initialRate
    }

    func updates() -> AsyncStream<PlaybackTimelineSnapshot> {
        store.updates()
    }

    func observe(
        _ observer: @escaping @MainActor (PlaybackTimelineSnapshot) -> Void
    ) -> @MainActor @Sendable () -> Void {
        store.observe(observer)
    }

    func begin(
        identity: PlaybackItemIdentity,
        loadIntent: PlaybackLoadIntent = PlaybackLoadIntent()
    ) {
        momentaryRateSession = nil
        observers.reset()
        pendingSeek = nil
        completedSeekLanding = nil
        staleSeekLandings.removeAll(keepingCapacity: true)
        interactionTracker = PlaybackInteractionTracker()
        token = store.beginItem(identity: identity, loadIntent: loadIntent)
        failedToken = nil
    }

    /// 为当前 item 安装位置、速率、状态、结束、失败与时间跳变观察，并替换旧观察集合。
    func installObservers(for item: AVPlayerItem) {
        observers.reset()
        guard let token else { return }
        let interactionTracker = interactionTracker

        let periodicTimeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 30),
            queue: .main
        ) { [weak self, weak item] time in
            Task { @MainActor in
                guard let self, let item, self.player.currentItem === item,
                    let seconds = Self.seconds(from: time)
                else { return }
                self.store.update(
                    token: token,
                    positionSeconds: seconds,
                    rate: Double(self.player.rate)
                )
            }
        }

        let rateObservation = player.observe(\.rate, options: [.initial, .new]) {
            [weak self, weak item] player, _ in
            Task { @MainActor in
                guard let self, let item, self.player.currentItem === item else {
                    return
                }
                self.store.update(token: token, rate: Double(player.rate))
            }
        }

        let timeControlObservation = player.observe(
            \.timeControlStatus,
            options: [.new]
        ) { [weak self, weak item] player, change in
            let observedStatus = change.newValue ?? player.timeControlStatus
            interactionTracker.observeTimeControlStatus(
                isPaused: observedStatus == .paused,
                isPlaying: observedStatus == .playing,
                playbackRate: player.rate
            )
            Task { @MainActor in
                guard let self, let item, self.player.currentItem === item else {
                    return
                }
                let currentState = self.store.currentSnapshot.state
                guard currentState != .failed else { return }
                switch observedStatus {
                case .paused:
                    guard currentState != .ended,
                        currentState != .loading
                            || interactionTracker.hasObservedInteraction
                    else {
                        return
                    }
                    self.store.update(token: token, rate: 0, state: .paused)
                case .waitingToPlayAtSpecifiedRate:
                    self.store.update(
                        token: token,
                        rate: Double(player.rate),
                        state: .buffering
                    )
                case .playing:
                    self.store.update(
                        token: token,
                        rate: Double(player.rate),
                        state: .playing
                    )
                @unknown default:
                    return
                }
            }
        }

        let endNotificationObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: item,
            queue: .main
        ) { [weak self, weak item] _ in
            MainActor.assumeIsolated {
                guard let self, let item, self.player.currentItem === item else {
                    return
                }
                self.store.update(
                    token: token,
                    positionSeconds: Self.seconds(from: item.currentTime()),
                    rate: 0,
                    state: .ended
                )
                self.momentaryRateSession = nil
                self.onEnded?()
            }
        }

        let statusObservation = item.observe(
            \.status,
            options: [.new]
        ) { [weak self, weak item] observedItem, _ in
            Task { @MainActor in
                guard observedItem.status == .failed,
                    let self,
                    let item
                else { return }
                self.fail(item: item, token: token)
            }
        }

        let failureNotificationObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.failedToPlayToEndTimeNotification,
            object: item,
            queue: .main
        ) { [weak self, weak item] _ in
            Task { @MainActor in
                guard let self, let item else { return }
                self.fail(item: item, token: token)
            }
        }

        let timeJumpNotificationObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.timeJumpedNotification,
            object: item,
            queue: .main
        ) { [weak self, weak item] _ in
            Task { @MainActor in
                guard let self, let item, self.player.currentItem === item,
                    let position = Self.seconds(from: item.currentTime())
                else { return }
                self.observeTimeJump(at: position)
            }
        }

        observers.replace(
            player: player,
            periodicTimeObserver: periodicTimeObserver,
            rateObservation: rateObservation,
            timeControlObservation: timeControlObservation,
            statusObservation: statusObservation,
            endNotificationObserver: endNotificationObserver,
            failureNotificationObserver: failureNotificationObserver,
            timeJumpNotificationObserver: timeJumpNotificationObserver
        )
    }

    func markReady(duration: CMTime) {
        guard let token else { return }
        store.markReady(
            token: token,
            durationSeconds: Self.seconds(from: duration)
        )
    }

    func markFailed() {
        momentaryRateSession = nil
        observers.reset()
        guard let token else { return }
        failedToken = token
        store.markFailed(token: token)
    }

    func play() {
        guard let token else { return }
        let preferredRate = Self.validatedPlaybackRate(player.defaultRate) ?? 1
        player.defaultRate = preferredRate
        player.playImmediately(atRate: preferredRate)
        store.update(
            token: token,
            rate: Double(preferredRate),
            state: .playing
        )
    }

    func playAfterInternalSeek() {
        interactionTracker.allowInternalPlayStart()
        play()
    }

    func pause() {
        guard let token else { return }
        interactionTracker.markObserved()
        momentaryRateSession = nil
        player.pause()
        store.update(token: token, rate: 0, state: .paused)
    }

    func setRate(_ rate: Double) throws {
        guard rate.isFinite, (0.25...4).contains(rate) else {
            throw AVPlayerEngineError.invalidPlaybackRate
        }
        momentaryRateSession = nil
        player.defaultRate = Float(rate)
        guard player.rate > 0, let token else { return }
        player.rate = Float(rate)
        store.update(token: token, rate: rate, state: .playing)
    }

    func beginMomentaryRate(_ rate: Double) throws -> UUID? {
        guard rate.isFinite, (0.25...4).contains(rate) else {
            throw AVPlayerEngineError.invalidPlaybackRate
        }
        guard let token,
            let item = player.currentItem,
            player.rate > 0
        else {
            return nil
        }

        let session = MomentaryRateSession(
            id: UUID(),
            item: item,
            rate: Float(rate)
        )
        momentaryRateSession = session
        player.rate = session.rate
        store.update(token: token, rate: rate, state: .playing)
        return session.id
    }

    func endMomentaryRate(sessionID: UUID) {
        guard let session = momentaryRateSession,
            session.id == sessionID
        else {
            return
        }
        momentaryRateSession = nil

        guard player.currentItem === session.item, let token
        else {
            return
        }
        let restorationAction = MomentaryRateRestorationPolicy.action(
            timeControlStatus: player.timeControlStatus,
            currentRate: player.rate,
            momentaryRate: session.rate
        )
        switch restorationAction {
        case .none:
            return
        case .setCurrentRate:
            player.rate = player.defaultRate
        case .resumeAtDefaultRate:
            player.play()
        }
        let restoredState: PlaybackTimelineState =
            player.timeControlStatus == .playing ? .playing : .buffering
        store.update(
            token: token,
            rate: Double(player.defaultRate),
            state: restoredState
        )
    }

    func prepareExplicitSeek(
        operationID: UUID,
        to positionSeconds: Double
    ) {
        prepareObservedSeek(operationID: operationID, to: positionSeconds)
    }

    func prepareTransportSeek(
        operationID: UUID,
        to positionSeconds: Double
    ) {
        prepareObservedSeek(operationID: operationID, to: positionSeconds)
    }

    func transportSeekFailed(operationID: UUID) {
        seekFailed(operationID: operationID)
    }

    func transportSeekCompleted(
        operationID: UUID,
        at positionSeconds: Double
    ) {
        seekCompleted(operationID: operationID, at: positionSeconds)
    }

    func prepareInitialSeek(operationID: UUID, to positionSeconds: Double) {
        interactionTracker.allowInternalSeek(to: positionSeconds)
        beginPendingSeek(operationID: operationID, to: positionSeconds)
    }

    func prepareResumeRestart(operationID: UUID) {
        interactionTracker.markObservedAllowingInternalSeek(to: 0)
        beginPendingSeek(operationID: operationID, to: 0)
    }

    func resumeRestartFailed(operationID: UUID) {
        seekFailed(operationID: operationID)
    }

    func resumeRestartCompleted(operationID: UUID) {
        seekCompleted(operationID: operationID, at: 0)
    }

    func initialSeekFailed(operationID: UUID) {
        seekFailed(operationID: operationID)
    }

    func initialSeekCompleted(
        operationID: UUID,
        at positionSeconds: Double
    ) {
        seekCompleted(operationID: operationID, at: positionSeconds)
    }

    func explicitSeekFailed(operationID: UUID) {
        seekFailed(operationID: operationID)
    }

    func explicitSeekCompleted(
        operationID: UUID,
        at positionSeconds: Double
    ) {
        seekCompleted(operationID: operationID, at: positionSeconds)
    }

    private func prepareObservedSeek(
        operationID: UUID,
        to positionSeconds: Double
    ) {
        interactionTracker.markObservedAllowingInternalSeek(to: positionSeconds)
        beginPendingSeek(operationID: operationID, to: positionSeconds)
    }

    private func beginPendingSeek(
        operationID: UUID,
        to positionSeconds: Double
    ) {
        if let pendingSeek, !pendingSeek.observedLanding {
            appendStaleSeekLanding(
                operationID: pendingSeek.operationID,
                positionSeconds: pendingSeek.targetSeconds
            )
        }
        if let completedSeekLanding {
            appendStaleSeekLanding(completedSeekLanding)
        }
        pendingSeek = PendingSeek(
            operationID: operationID,
            targetSeconds: positionSeconds
        )
        completedSeekLanding = nil
    }

    func observeTimeJump(at positionSeconds: Double) {
        interactionTracker.observeTimeJump(at: positionSeconds)
        guard store.currentSnapshot.state != .loading, let token else { return }
        if var pendingSeek {
            let currentDistance = abs(
                pendingSeek.targetSeconds - positionSeconds
            )
            if consumeStaleSeekLanding(
                at: positionSeconds,
                closerThan: currentDistance
            ) {
                return
            }
            if currentDistance <= 0.5 {
                discardEquivalentStaleSeekLandings(
                    to: pendingSeek.targetSeconds
                )
                pendingSeek.observedLanding = true
                self.pendingSeek = pendingSeek
                return
            }
            appendStaleSeekLanding(
                operationID: pendingSeek.operationID,
                positionSeconds: pendingSeek.targetSeconds
            )
            self.pendingSeek = nil
            completedSeekLanding = nil
            interactionTracker.markObserved()
            store.markDiscontinuity(
                token: token,
                positionSeconds: positionSeconds
            )
            onSeekSupersededByExternalJump?(pendingSeek.operationID)
            return
        }
        let completedDistance =
            completedSeekLanding.map {
                abs($0.positionSeconds - positionSeconds)
            } ?? .infinity
        if consumeStaleSeekLanding(
            at: positionSeconds,
            closerThan: completedDistance
        ) {
            return
        }
        if completedDistance <= 0.5 {
            if let completedSeekLanding {
                discardEquivalentStaleSeekLandings(
                    to: completedSeekLanding.positionSeconds
                )
            }
            completedSeekLanding = nil
            return
        }
        if let completedSeekLanding {
            appendStaleSeekLanding(completedSeekLanding)
        }
        completedSeekLanding = nil
        store.markDiscontinuity(
            token: token,
            positionSeconds: positionSeconds
        )
    }

    private func seekFailed(operationID: UUID) {
        guard pendingSeek?.operationID == operationID else { return }
        pendingSeek = nil
        interactionTracker.cancelInternalSeek()
    }

    func discardStaleSeekLanding(operationID: UUID) {
        staleSeekLandings.removeAll {
            $0.operationID == operationID
        }
    }

    private func discardEquivalentStaleSeekLandings(to positionSeconds: Double) {
        staleSeekLandings.removeAll {
            abs($0.positionSeconds - positionSeconds) <= 0.000_001
        }
    }

    private func seekCompleted(
        operationID: UUID,
        at positionSeconds: Double
    ) {
        guard let completedPendingSeek = pendingSeek,
            completedPendingSeek.operationID == operationID,
            let token
        else { return }
        pendingSeek = nil
        completedSeekLanding =
            completedPendingSeek.observedLanding
            ? nil
            : SeekLanding(
                operationID: operationID,
                positionSeconds: positionSeconds
            )
        interactionTracker.completeInternalSeek(at: positionSeconds)
        store.markDiscontinuity(
            token: token,
            positionSeconds: positionSeconds
        )
    }

    func clear() {
        momentaryRateSession = nil
        observers.reset()
        pendingSeek = nil
        completedSeekLanding = nil
        staleSeekLandings.removeAll(keepingCapacity: true)
        store.clear(token: token)
        token = nil
        failedToken = nil
    }

    private func appendStaleSeekLanding(
        operationID: UUID,
        positionSeconds: Double
    ) {
        appendStaleSeekLanding(
            SeekLanding(
                operationID: operationID,
                positionSeconds: positionSeconds
            )
        )
    }

    private func appendStaleSeekLanding(_ landing: SeekLanding) {
        staleSeekLandings.append(landing)
        if staleSeekLandings.count > 16 {
            staleSeekLandings.removeFirst()
        }
    }

    private func consumeStaleSeekLanding(
        at positionSeconds: Double,
        closerThan competingDistance: Double
    ) -> Bool {
        guard
            let candidate = staleSeekLandings.enumerated().min(
                by: {
                    abs($0.element.positionSeconds - positionSeconds)
                        < abs($1.element.positionSeconds - positionSeconds)
                }
            )
        else { return false }
        let distance = abs(candidate.element.positionSeconds - positionSeconds)
        guard distance <= 0.5, distance < competingDistance else { return false }
        staleSeekLandings.remove(at: candidate.offset)
        return true
    }

    private func fail(
        item: AVPlayerItem,
        token: PlaybackTimelineItemToken
    ) {
        guard player.currentItem === item,
            self.token == token,
            failedToken != token,
            store.currentSnapshot.state != .loading
        else { return }

        failedToken = token
        momentaryRateSession = nil
        observers.reset()
        store.markFailed(token: token)
        onFailed?()
    }

    private nonisolated static func seconds(from time: CMTime) -> Double? {
        let seconds = CMTimeGetSeconds(time)
        guard seconds.isFinite, seconds >= 0 else { return nil }
        return seconds
    }

    private static func validatedPlaybackRate(_ rate: Float) -> Float? {
        guard rate.isFinite, (0.25...4).contains(rate) else { return nil }
        return rate
    }
}

private final class PlayerTimelineObserverBag: Sendable {
    private struct Storage {
        var player: AVPlayer? = nil
        var periodicTimeObserver: Any? = nil
        var rateObservation: NSKeyValueObservation? = nil
        var timeControlObservation: NSKeyValueObservation? = nil
        var statusObservation: NSKeyValueObservation? = nil
        var endNotificationObserver: NSObjectProtocol? = nil
        var failureNotificationObserver: NSObjectProtocol? = nil
        var timeJumpNotificationObserver: NSObjectProtocol? = nil
    }

    private let storage = OSAllocatedUnfairLock(uncheckedState: Storage())

    deinit {
        reset()
    }

    func replace(
        player: AVPlayer,
        periodicTimeObserver: Any,
        rateObservation: NSKeyValueObservation,
        timeControlObservation: NSKeyValueObservation,
        statusObservation: NSKeyValueObservation,
        endNotificationObserver: NSObjectProtocol,
        failureNotificationObserver: NSObjectProtocol,
        timeJumpNotificationObserver: NSObjectProtocol
    ) {
        let previous = storage.withLockUnchecked { storage -> Storage in
            let previous = storage
            storage = Storage(
                player: player,
                periodicTimeObserver: periodicTimeObserver,
                rateObservation: rateObservation,
                timeControlObservation: timeControlObservation,
                statusObservation: statusObservation,
                endNotificationObserver: endNotificationObserver,
                failureNotificationObserver: failureNotificationObserver,
                timeJumpNotificationObserver: timeJumpNotificationObserver
            )
            return previous
        }
        Self.remove(previous)
    }

    func reset() {
        let previous = storage.withLockUnchecked { storage -> Storage in
            let previous = storage
            storage = Storage()
            return previous
        }
        Self.remove(previous)
    }

    private static func remove(_ storage: Storage) {
        if let player = storage.player,
            let periodicTimeObserver = storage.periodicTimeObserver
        {
            player.removeTimeObserver(periodicTimeObserver)
        }
        storage.rateObservation?.invalidate()
        storage.timeControlObservation?.invalidate()
        storage.statusObservation?.invalidate()
        if let endNotificationObserver = storage.endNotificationObserver {
            NotificationCenter.default.removeObserver(endNotificationObserver)
        }
        if let failureNotificationObserver = storage.failureNotificationObserver {
            NotificationCenter.default.removeObserver(failureNotificationObserver)
        }
        if let timeJumpNotificationObserver = storage.timeJumpNotificationObserver {
            NotificationCenter.default.removeObserver(timeJumpNotificationObserver)
        }
    }
}
