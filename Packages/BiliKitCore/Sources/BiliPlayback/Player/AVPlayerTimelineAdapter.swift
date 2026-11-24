@preconcurrency import AVFoundation
import BiliApplication
import Foundation

/// 把 AVPlayer/KVO/notification 事件投影为平台无关、identity-safe 的播放时间线。
///
/// 所有 callback 都同时核对当前 `AVPlayerItem` 与 item token；observer bag 在替换、失败和
/// clear 时统一释放，避免旧 item 继续推进弹幕、观看进度等时间线消费方。
///
/// `discontinuityGeneration` 由 engine 的 seek 收尾与 `AVPlayerItem` 的 time-jump 通知推进；同一次 seek
/// 的迟到或重复跳变按落点吞掉，不重复推进（Now Playing 依赖它只在真正不连续时前进）。原生拖动的每一步都
/// 推进它；每次从暂停恢复播放，系统都报一次原地的时间跳变（刚在原处 seek 过、落点还在吞的除外），同样推进
/// 一次。
@MainActor
final class AVPlayerTimelineAdapter {
    /// 已发出、尚未收尾的 seek：目标位置，以及是否已观察到落在目标附近的系统 time-jump。
    ///
    /// 收尾时把是否已观察到一并记进落点；未观察到就被新 seek 取代时，目标转入过期落点，
    /// 迟到的跳变据此被吞掉。
    private struct PendingSeek {
        let operationID: UUID
        let targetSeconds: Double
        var observedLanding = false
    }

    /// 一次 seek 的落点，用来辨认迟到或重复的系统 time-jump。
    ///
    /// `observedJump` 表示已经见过落在这里的系统跳变：之后再落在这里的跳变（例如暂停中 seek 后开播时
    /// 系统再报一次）仍按同一次 seek 吞掉；被新 seek 或外部跳变取代时，已见过的落点不再转入过期落点，
    /// 否则之后真正回到这个位置的跳变会被误吞。
    private struct SeekLanding {
        let operationID: UUID
        let positionSeconds: Double
        var observedJump = false
    }

    /// 按住期间的临时倍速；只有同一 ID、同一 item 时 `endMomentaryRate` 才恢复速率。
    private struct MomentaryRateSession {
        let id: UUID
        let item: AVPlayerItem
        let rate: Float
    }

    var onFailed: (@MainActor () -> Void)?
    var onSeekSupersededByExternalJump: (@MainActor (UUID) -> Void)?
    /// 当前 item 失败时、写 failed 之前调用，参数是失败前的快照；返回 true 表示 engine 改为换源接手，时间线不写
    /// failed、也不调用 `onFailed`，失败前的位置与状态留给 engine 读取。
    var recoversFromFailure: (@MainActor (PlaybackTimelineSnapshot) -> Bool)?
    /// 播放器绕过 engine 开始播放或等数据时调用。
    ///
    /// AVPlayerView 自带的控件直接让 AVPlayer 播放，时间线并未经 `play` 记为播放。返回 true 表示 engine 已停住
    /// 播放器接管这次开播，这次状态变化不写进时间线。
    var onPlaybackStartedOutsideEngine: (@MainActor () -> Bool)?

    var currentSnapshot: PlaybackTimelineSnapshot {
        store.currentSnapshot
    }

    var hasObservedPlaybackInteraction: Bool {
        interactionTracker.hasObservedInteraction
    }

    var playbackInteractionRevision: UInt64 {
        interactionTracker.revision
    }

    /// 记住的过期 seek 落点上限；只用来辨认迟到的系统 time-jump，最早的先丢。
    private static let maximumStaleSeekLandings = 16

    private let player: AVPlayer
    private let store = PlaybackTimelineStore()
    private let observers = PlayerTimelineObserverBag()
    /// 当前 item 的时间线 token，由 `begin` 向 store 领取，`clear` 时置 nil。
    ///
    /// 每个 observer 捕获安装时的 token，store 丢弃与当前不符的写入，旧 item 的回调不会推进时间线。
    private var token: PlaybackTimelineItemToken?
    /// 已报告失败的 token：status 与 failedToPlayToEnd 两路失败对同一 item 只报告一次。
    private var failedToken: PlaybackTimelineItemToken?
    private var momentaryRateSession: MomentaryRateSession?
    private var pendingSeek: PendingSeek?
    /// 最近一次已收尾的 seek 落点；之后落在附近的系统跳变都按这次 seek 吞掉，直到播放离开落点
    /// （`observePeriodicPosition`），或被新 seek、外部跳变、换 item、clear 取代。
    private var completedSeekLanding: SeekLanding?
    private var staleSeekLandings: [SeekLanding] = []
    private var interactionTracker = PlaybackInteractionTracker()
    private var startPositionSeconds: Double = 0
    /// 当前 item 已开始准备、还没 `markReady`。
    ///
    /// 期间的失败由 engine 的就绪等待处理（含回退阶梯），time-jump 不是播放中的不连续。不看时间线状态：换源的
    /// item 准备期间时间线是 paused。
    private var isAwaitingReadiness = false

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

    /// `startPositionSeconds` 是 playlist 的起播位置（从头为 0），就绪时据此标记时间轴不连续。
    func begin(
        identity: PlaybackItemIdentity,
        loadIntent: PlaybackLoadIntent = PlaybackLoadIntent(),
        startPositionSeconds: Double = 0
    ) {
        resetItemState(startPositionSeconds: startPositionSeconds)
        token = store.beginItem(identity: identity, loadIntent: loadIntent)
    }

    /// 换源：同一 identity 与 intent 的新 item 从 `startPositionSeconds` 起播，时间线保留位置并记为暂停（见
    /// `PlaybackTimelineStore.beginReplacementItem`），就绪时按实际位置标记不连续。
    func beginReplacement(startPositionSeconds: Double) {
        resetItemState(startPositionSeconds: startPositionSeconds)
        token = store.beginReplacementItem()
    }

    private func resetItemState(startPositionSeconds: Double) {
        momentaryRateSession = nil
        observers.reset()
        pendingSeek = nil
        completedSeekLanding = nil
        staleSeekLandings.removeAll(keepingCapacity: true)
        self.startPositionSeconds = startPositionSeconds
        interactionTracker = PlaybackInteractionTracker(
            startPositionSeconds: startPositionSeconds
        )
        failedToken = nil
        isAwaitingReadiness = true
    }

    /// 为当前 item 安装位置、速率、状态、结束、失败与时间跳变观察，并替换旧观察集合。
    ///
    /// periodic observer 与 item 通知都指定 `queue: .main`，回调已在主线程，用 `MainActor.assumeIsolated`
    /// 同步执行。三路 KVO（rate、timeControlStatus、item status）在改动发生的线程同步回调：在后台线程改速率
    /// 或 seek 时实测会落在非主线程，所以仍经 Task 跳回主线程。
    func installObservers(for item: AVPlayerItem) {
        observers.reset()
        guard let token else { return }
        let interactionTracker = interactionTracker

        let periodicTimeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(
                value: 1,
                timescale: CMTimeScale(PlaybackTimelineSnapshot.periodicSnapshotsPerMediaSecond)
            ),
            queue: .main
        ) { [weak self, weak item] time in
            MainActor.assumeIsolated {
                guard let self, let item, self.player.currentItem === item,
                    self.token == token,
                    let seconds = Self.seconds(from: time)
                else { return }
                self.observePeriodicPosition(seconds)
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
                // engine 自己的 `play` 已同步把时间线写成 buffering 或 playing，到这里只剩绕过 engine 的开播。
                if observedStatus != .paused,
                    currentState != .playing, currentState != .buffering,
                    !self.isAwaitingReadiness,
                    self.onPlaybackStartedOutsideEngine?() == true
                {
                    return
                }
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
                // 结束通知与系统随后的 paused 报告先后不定；这里仍报告未暂停时，那次 paused 还没到。
                if self.player.timeControlStatus != .paused {
                    interactionTracker.expectEndOfItemPause()
                }
                self.store.update(
                    token: token,
                    positionSeconds: Self.seconds(from: item.currentTime()),
                    rate: 0,
                    state: .ended
                )
                self.momentaryRateSession = nil
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
            MainActor.assumeIsolated {
                guard let self, let item else { return }
                self.fail(item: item, token: token)
            }
        }

        let timeJumpNotificationObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.timeJumpedNotification,
            object: item,
            queue: .main
        ) { [weak self, weak item] _ in
            MainActor.assumeIsolated {
                guard let self, let item, self.player.currentItem === item,
                    let position = Self.seconds(from: item.currentTime())
                else { return }
                self.observeTimeJump(at: position)
            }
        }

        observers.replace(
            player: player,
            periodicTimeObserver: periodicTimeObserver,
            keyValueObservations: [rateObservation, timeControlObservation, statusObservation],
            notificationObservers: [
                endNotificationObserver,
                failureNotificationObserver,
                timeJumpNotificationObserver
            ]
        )
    }

    /// 周期回调的主线程入口：写入位置与速率，并在播放离开上次 seek 落点后结束那个落点的有效期。
    ///
    /// 已见过系统跳变的落点只在播放位置仍在落点附近时吞掉重复跳变（暂停中 seek 后开播那一次）；位置
    /// 离开超过容差后，之后回到原处的原生 seek 是新的不连续，不能再被吞掉。还没见过跳变的落点保留，
    /// 等迟到的跳变。
    func observePeriodicPosition(_ seconds: Double) {
        guard let token else { return }
        if let completedSeekLanding, completedSeekLanding.observedJump,
            abs(seconds - completedSeekLanding.positionSeconds)
                > SeekPolicy.landingMatchToleranceSeconds
        {
            self.completedSeekLanding = nil
        }
        store.update(
            token: token,
            positionSeconds: seconds,
            rate: Double(player.rate)
        )
    }

    func markReady(duration: CMTime) {
        guard let token else { return }
        isAwaitingReadiness = false
        store.markReady(
            token: token,
            durationSeconds: Self.seconds(from: duration)
        )
        // 从 playlist 起播位置开始的 item 一就绪就位于该处；标记不连续，Now Playing 据此按起播位置
        // 重新发布已播时长，而不是把 0 到起播位置之间当作连续前进。
        guard startPositionSeconds > 0 else { return }
        store.markDiscontinuity(
            token: token,
            positionSeconds: Self.seconds(from: player.currentTime())
                ?? startPositionSeconds
        )
    }

    func markFailed() {
        momentaryRateSession = nil
        observers.reset()
        guard let token else { return }
        failedToken = token
        store.markFailed(token: token)
    }

    /// 按 `defaultRate` 起播；空格、Now Playing 远程播放、评论时间戳跳转与从头播放都经这里。
    ///
    /// 用 `play()` 而不用 `playImmediately(atRate:)`，与 AVKit 自带播放按钮一致：落点处没有缓冲时系统先等到
    /// 数据够了再开播，而不是开播后立刻卡住；等数据期间由 App 播放器浮层的加载转圈呈现。
    func play() {
        guard let token else { return }
        let preferredRate = Self.validatedPlaybackRate(player.defaultRate) ?? 1
        player.defaultRate = preferredRate
        player.play()
        publishRequestedPlayback(token: token)
    }

    /// 发出播放请求后按播放器当下的状态写时间线：已在播放写 `.playing`，等数据写 `.buffering`，速率取
    /// `defaultRate`。
    ///
    /// 不乐观写 `.playing`：系统等数据时 KVO 随后会报 waiting，时间线会从 `.playing` 退回 `.buffering` 再前进，
    /// Now Playing 与观看进度多看到一次翻转；按当下状态写，之后的 KVO 只会把 `.buffering` 推进到 `.playing`。
    private func publishRequestedPlayback(token: PlaybackTimelineItemToken) {
        store.update(
            token: token,
            rate: Double(player.defaultRate),
            state: player.timeControlStatus == .playing ? .playing : .buffering
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

    func beginMomentaryRate(_ rate: Double) throws -> UUID? {
        guard PlaybackRate.isSupported(rate) else {
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
        publishRequestedPlayback(token: token)
    }

    func prepareRestartFromBeginning(operationID: UUID) {
        interactionTracker.markObservedAllowingInternalSeek(to: 0)
        beginPendingSeek(operationID: operationID, to: 0)
    }

    /// 用户或 transport 发起的 seek：先记为用户交互，再登记待定落点。
    func prepareObservedSeek(
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
        if let completedSeekLanding, !completedSeekLanding.observedJump {
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
        guard !isAwaitingReadiness, let token else { return }
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
            if currentDistance <= SeekPolicy.landingMatchToleranceSeconds {
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
        if completedDistance <= SeekPolicy.landingMatchToleranceSeconds,
            var completedSeekLanding
        {
            discardEquivalentStaleSeekLandings(
                to: completedSeekLanding.positionSeconds
            )
            // 落点继续有效：暂停中 seek 后开播时系统会在原处再报一次跳变，它不是新的不连续。
            completedSeekLanding.observedJump = true
            self.completedSeekLanding = completedSeekLanding
            return
        }
        if let completedSeekLanding, !completedSeekLanding.observedJump {
            appendStaleSeekLanding(completedSeekLanding)
        }
        completedSeekLanding = nil
        store.markDiscontinuity(
            token: token,
            positionSeconds: positionSeconds
        )
    }

    func seekFailed(operationID: UUID) {
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

    func seekCompleted(
        operationID: UUID,
        at positionSeconds: Double
    ) {
        guard let completedPendingSeek = pendingSeek,
            completedPendingSeek.operationID == operationID,
            let token
        else { return }
        pendingSeek = nil
        completedSeekLanding = SeekLanding(
            operationID: operationID,
            positionSeconds: positionSeconds,
            observedJump: completedPendingSeek.observedLanding
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
        isAwaitingReadiness = false
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
        if staleSeekLandings.count > Self.maximumStaleSeekLandings {
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
        guard distance <= SeekPolicy.landingMatchToleranceSeconds,
            distance < competingDistance
        else { return false }
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
            !isAwaitingReadiness
        else { return }

        failedToken = token
        momentaryRateSession = nil
        observers.reset()
        if recoversFromFailure?(store.currentSnapshot) == true { return }
        store.markFailed(token: token)
        onFailed?()
    }

    private nonisolated static func seconds(from time: CMTime) -> Double? {
        let seconds = CMTimeGetSeconds(time)
        guard seconds.isFinite, seconds >= 0 else { return nil }
        return seconds
    }

    private static func validatedPlaybackRate(_ rate: Float) -> Float? {
        guard PlaybackRate.isSupported(rate) else { return nil }
        return rate
    }
}

/// 当前 item 的 AVPlayer 观察集合（periodic observer、KVO 与 item 通知 observer）。
///
/// 由 `AVPlayerTimelineAdapter` 独占持有：`replace` 先注销旧集合再记下新集合，`reset` 在换 item、失败与
/// clear 时注销；isolated deinit 兜底注销。MainActor 隔离，不加锁：adapter 在主线程以外被释放时，运行时把
/// deinit 排到主线程执行，注销晚一拍；这期间到达的回调按 item 与 token 比对，adapter 已释放时弱引用为
/// nil，都不会写进时间线。
@MainActor
private final class PlayerTimelineObserverBag {
    /// 安装 periodic observer 的 player，只用于注销它。
    private var player: AVPlayer?
    private var periodicTimeObserver: Any?
    private var keyValueObservations: [NSKeyValueObservation] = []
    private var notificationObservers: [any NSObjectProtocol] = []

    isolated deinit {
        reset()
    }

    func replace(
        player: AVPlayer,
        periodicTimeObserver: Any,
        keyValueObservations: [NSKeyValueObservation],
        notificationObservers: [any NSObjectProtocol]
    ) {
        reset()
        self.player = player
        self.periodicTimeObserver = periodicTimeObserver
        self.keyValueObservations = keyValueObservations
        self.notificationObservers = notificationObservers
    }

    func reset() {
        if let player, let periodicTimeObserver {
            player.removeTimeObserver(periodicTimeObserver)
        }
        player = nil
        periodicTimeObserver = nil
        for observation in keyValueObservations {
            observation.invalidate()
        }
        keyValueObservations = []
        for observer in notificationObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        notificationObservers = []
    }
}
