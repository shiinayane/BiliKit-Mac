import CoreMedia
import Dispatch
import Foundation
import QuartzCore
import Synchronization
import Testing

@testable import BiliKit

/// 固定弹幕时钟层的契约：每次速率变化或时间跳变之后本地时间与绑定 timebase 的时间一致（播放、暂停、跳
/// 时间、倍速）；同一纪元里播放中显示时间只进不退，timebase 低于它时原地停住、等直线追上后重合，反复
/// 起播、暂停与 seek 误差不累积，换绑后立即严格跟随；主线程被挡住时照样停下，绑定时不等通知就同步，换绑
/// 后旧 timebase 的变化不影响时钟层，解绑后停在速率 0、读不到显示时间；与其他线程的 Core Animation 提交
/// 并发时不死锁；其他线程按发布值求出的显示时间与 Core Animation 换算的本地时间是同一条线，从未绑定时
/// 读不到，换绑立即作废旧发布值，每次写入之后都会唤醒主线程读到它。
///
/// 用以宿主时钟为源的真实 `CMTimebase`，它的通知与播放器 item 的 timebase 走同一条路径。时钟层的更新
/// 在后台队列上异步落地，所以每次改变 timebase 之后等到时钟层与它一致；同时比对此刻与
/// `lookahead` 秒之后的宿主时间，一并证明速率，不需要等真实时间流逝。
@Suite(.timeLimit(.minutes(1)))
@MainActor
struct DanmakuTimebaseClockTests {
    /// 本地时间与 timebase 时间的容差（秒）：两者按同一个宿主时间换算，只差浮点与 CMTime 取整误差。
    private static let tolerance = 1e-3
    /// 额外比对的未来宿主时间偏移（秒）：速率差 0.01 在这里就是 0.1 秒，远大于容差。
    private static let lookahead = 10.0
    /// 与后台提交并发的时钟写入次数：未修正时几百次之内就会死锁。
    private static let concurrentCommitRounds = 2_000
    /// 模拟 timebase 新直线晚于此刻才经过冻结值的等待 δ（秒）。
    ///
    /// 测试从不真等到 start：所有断言都按事先算出的宿主时刻换算，δ 不占墙钟时间，所以取远超任何调度延迟的值，
    /// 时钟队列的写入一定在 start 之前落地。取音频延迟量级（几百毫秒）时，队列若晚于 start 才执行，写入的是严格
    /// 跟随的直线，等待窗口里的采样全部偏离冻结值。
    private static let anchoredStartDelay = 10.0
    /// 反复起播、暂停与 seek 的轮数。
    private static let repeatedRoundCount = 200
    /// 相邻采样按浮点比较，只容许 CMTime 取整与浮点舍入。
    private static let monotonicSlack = 1e-6
    /// 等待结束之后比对误差的偏移（秒）：只要越过等待的终点即可。
    private static let settleOffset = 0.001
    /// 主线程忙等时钟层停下的上限（秒），只作超时；正常在 timebase 停下后 1ms 内完成。
    private static let blockedMainThreadTimeout = 2.0

    @Test
    func bindingSynchronizesImmediatelyWithoutWaitingForANotification() async throws {
        let timebase = try makeTimebase(time: 5, rate: 0)
        let clock = DanmakuTimebaseClock()

        clock.bind(timebase)

        #expect(await converges(clock, to: timebase))
    }

    @Test
    func clockFollowsPlayPauseJumpAndRateChanges() async throws {
        let timebase = try makeTimebase(time: 0, rate: 0)
        let clock = DanmakuTimebaseClock()
        clock.bind(timebase)
        #expect(await converges(clock, to: timebase))

        CMTimebaseSetRate(timebase, rate: 1)
        #expect(await converges(clock, to: timebase))

        // 暂停：此刻与将来的本地时间都等于冻结的 timebase 时间。
        CMTimebaseSetRate(timebase, rate: 0)
        #expect(await converges(clock, to: timebase))

        CMTimebaseSetTime(timebase, time: CMTime(seconds: 42, preferredTimescale: 600))
        #expect(await converges(clock, to: timebase))

        CMTimebaseSetRate(timebase, rate: 2)
        #expect(await converges(clock, to: timebase))

        // 播放中向前跳时间：速率保持，时间换到新位置。
        CMTimebaseSetTime(timebase, time: CMTime(seconds: 70, preferredTimescale: 600))
        #expect(await converges(clock, to: timebase))
    }

    /// 起播时 timebase 的新直线在 δ 之后才经过冻结值（系统按音频输出延迟重锚），此刻读数比冻结值小 δ × 速率：
    /// 等待窗口里本地时间停在冻结值，之后与 timebase 重合；暂停后往回 seek 仍严格跟随。
    @Test
    func playingClockWaitsAtTheFrozenTimeUntilTheAnchoredLineCatchesUp() async throws {
        let frozen = 20.0
        let timebase = try makeTimebase(time: frozen, rate: 0)
        let clock = DanmakuTimebaseClock()
        clock.bind(timebase)
        #expect(await converges(clock, to: timebase))

        let host = CACurrentMediaTime()
        let start = startPlaying(timebase, at: frozen, after: Self.anchoredStartDelay)
        #expect(mediaTime(of: timebase, atHost: host) < frozen - Self.anchoredStartDelay / 2)
        #expect(await waitUntil { clock.layer.speed == 1 })
        // 前提：写入在 start 之前落地，写的是带等待的直线。不成立时这里先报出来，而不是下面的采样偏差。
        #expect(abs(clock.layer.beginTime - start) < Self.tolerance)

        for sample in stride(from: host, to: start, by: Self.anchoredStartDelay / 10) {
            #expect(abs(clock.layer.convertTime(sample, from: nil) - frozen) < Self.tolerance)
        }
        for offset in [0, 1, Self.lookahead] {
            let sample = start + offset
            let local = clock.layer.convertTime(sample, from: nil)
            #expect(abs(local - mediaTime(of: timebase, atHost: sample)) < Self.tolerance)
        }
        // 主线程读到的发布值就是这条带等待的直线：等待窗口里同样停在冻结值。
        #expect(await waitUntil { publishedTimeMatchesTheLayer(clock) })

        CMTimebaseSetRate(timebase, rate: 0)
        CMTimebaseSetTime(timebase, time: CMTime(seconds: 3, preferredTimescale: 600))
        #expect(await converges(clock, to: timebase))
    }

    /// 播放中 timebase 往回跳（4x HLS 的跳变风暴）：本地时间停在跳之前，等 timebase 追上再走。
    @Test
    func playingClockDoesNotFollowABackwardJump() async throws {
        let timebase = try makeTimebase(time: 20, rate: 0)
        let clock = DanmakuTimebaseClock()
        clock.bind(timebase)
        #expect(await converges(clock, to: timebase))
        CMTimebaseSetRate(timebase, rate: 2)
        #expect(await converges(clock, to: timebase))

        let host = CACurrentMediaTime()
        let before = mediaTime(of: timebase, atHost: host)
        CMTimebaseSetTime(
            timebase,
            time: CMTime(seconds: before - 1, preferredTimescale: 1_000_000_000)
        )
        // 以跳之前取的 host 判断写入已落地，不与当前时刻比较：等待窗口只有 0.5 秒，测试机慢时检查前就已过完。
        #expect(await waitUntil { clock.layer.beginTime > host })

        // 往回跳 1 秒、速率 2：停在跳之前的值，0.5 秒后追上，之后与 timebase 重合。
        let held = clock.layer.convertTime(host, from: nil)
        #expect(held >= before - Self.tolerance)
        let caughtUp = clock.layer.beginTime
        #expect(abs(clock.layer.convertTime(caughtUp, from: nil) - held) < Self.tolerance)
        let later = caughtUp + Self.lookahead
        #expect(
            abs(clock.layer.convertTime(later, from: nil) - mediaTime(of: timebase, atHost: later))
                < Self.tolerance
        )
    }

    /// 换绑到一个正在播放、时间更早的 timebase：下限只在同一纪元里成立，立即跟随新时间线。
    @Test
    func rebindingToAnEarlierPlayingTimebaseFollowsItImmediately() async throws {
        let old = try makeTimebase(time: 100, rate: 1)
        let new = try makeTimebase(time: 5, rate: 1)
        let clock = DanmakuTimebaseClock()
        clock.bind(old)
        #expect(await converges(clock, to: old))

        clock.bind(new)

        #expect(await converges(clock, to: new))
    }

    /// 换走再换回同一个 timebase（A→B→A），期间 A 在播放中被移到更早的位置：换回是新纪元，不沿用 A 上次的
    /// 下限，立即跟随。
    ///
    /// 这是防御性修正的护栏，不是反例：BiliKit 每次换 item 都新建 `AVPlayerItem`，A→B→A 目前不可达；按
    /// timebase 对象判断的旧写法只在换到 B 的同步还没执行就换回 A 时才会出错，这里能否撞上取决于调度。
    @Test
    func rebindingBackToTheSameTimebaseDoesNotKeepItsFloor() async throws {
        let first = try makeTimebase(time: 100, rate: 1)
        let second = try makeTimebase(time: 5, rate: 0)
        let clock = DanmakuTimebaseClock()
        clock.bind(first)
        #expect(await converges(clock, to: first))

        clock.bind(second)
        CMTimebaseSetTime(first, time: CMTime(seconds: 40, preferredTimescale: 600))
        clock.bind(first)

        #expect(await converges(clock, to: first))
    }

    /// 反复「锚定起播 → 暂停 → 速率 0 往回 seek → 速率 0 向前 seek」：每轮等待窗口里与之后本地时间都不后退，
    /// 等待结束之后与 timebase 重合，误差不随轮数增长。
    @Test
    func repeatedStartPauseAndSeekRoundsDoNotAccumulateError() async throws {
        let timebase = try makeTimebase(time: 100, rate: 0)
        let clock = DanmakuTimebaseClock()
        clock.bind(timebase)
        #expect(await converges(clock, to: timebase))

        var errors: [Double] = []
        for round in 0..<Self.repeatedRoundCount {
            // δ 在 10～200ms 里按黄金分割序列铺开，确定且覆盖均匀。
            let spread = (Double(round) * 0.618_033_988_749_895).truncatingRemainder(dividingBy: 1)
            let delay = 0.01 + 0.19 * spread
            let frozen = mediaTime(of: timebase, atHost: CACurrentMediaTime())
            let host = CACurrentMediaTime()
            let start = startPlaying(timebase, at: frozen, after: delay)
            #expect(await waitUntil { clock.layer.speed == 1 })

            // 起播之前停在 frozen：之后的采样从它开始都不后退。
            let window = stride(from: host, through: start + delay, by: delay / 8)
            let samples = [frozen] + window.map { clock.layer.convertTime($0, from: nil) }
            #expect(
                zip(samples, samples.dropFirst()).allSatisfy { $0 <= $1 + Self.monotonicSlack }
            )
            // 写入若晚于 start 落地（调度延迟），时钟层是严格跟随、从写入时刻起走，所以在两者较晚的那一刻之后比对。
            let settled = max(start, clock.layer.beginTime) + Self.settleOffset
            let local = clock.layer.convertTime(settled, from: nil)
            errors.append(abs(local - mediaTime(of: timebase, atHost: settled)))

            CMTimebaseSetRate(timebase, rate: 0)
            #expect(await converges(clock, to: timebase))
            let paused = mediaTime(of: timebase, atHost: CACurrentMediaTime())
            CMTimebaseSetTime(timebase, time: CMTime(seconds: paused - 3, preferredTimescale: 600))
            #expect(await converges(clock, to: timebase))
            CMTimebaseSetTime(timebase, time: CMTime(seconds: paused + 5, preferredTimescale: 600))
            #expect(await converges(clock, to: timebase))
        }

        #expect(errors.allSatisfy { $0 < Self.tolerance })
        let early = errors.prefix(10).max() ?? 0
        let late = errors.suffix(10).max() ?? 0
        #expect(late < Self.tolerance, "前 10 轮最大误差 \(early)，后 10 轮 \(late)")
    }

    @Test
    func rebindingIgnoresTheOldTimebase() async throws {
        let old = try makeTimebase(time: 3, rate: 0)
        let new = try makeTimebase(time: 7, rate: 0)
        let clock = DanmakuTimebaseClock()
        clock.bind(old)
        #expect(await converges(clock, to: old))
        clock.bind(new)
        #expect(await converges(clock, to: new))

        CMTimebaseSetRate(old, rate: 1)
        CMTimebaseSetTime(old, time: CMTime(seconds: 100, preferredTimescale: 600))
        // 时钟的同步按投递顺序串行执行：新 timebase 的这次变化落地时，旧 timebase 可能引起的同步都已处理完，
        // 而它们读的都是当前绑定的新 timebase。
        CMTimebaseSetTime(new, time: CMTime(seconds: 9, preferredTimescale: 600))

        #expect(await converges(clock, to: new))
    }

    @Test
    func neverBoundClockHasNoDisplayTime() {
        #expect(DanmakuTimebaseClock().displayTime() == nil)
    }

    /// 发布值求出的显示时间夹在读取前后两个宿主时间的 Core Animation 本地时间之间。
    @Test
    func publishedDisplayTimeIsTheClockLayersLine() async throws {
        let timebase = try makeTimebase(time: 20, rate: 0)
        let clock = DanmakuTimebaseClock()
        clock.bind(timebase)
        #expect(await converges(clock, to: timebase))
        #expect(await waitUntil { publishedTimeMatchesTheLayer(clock) })

        CMTimebaseSetRate(timebase, rate: 2)
        #expect(await converges(clock, to: timebase))
        #expect(await waitUntil { publishedTimeMatchesTheLayer(clock) })
    }

    /// 解绑之后没有 item 也就没有显示时间：时钟层停住，发布值一直读不到，不会冒充下一个视频的时间。
    @Test
    func unbindingLeavesNoDisplayTime() async throws {
        let timebase = try makeTimebase(time: 300, rate: 1)
        let clock = DanmakuTimebaseClock()
        clock.bind(timebase)
        #expect(await waitUntil { clock.displayTime() != nil })

        clock.bind(nil)
        #expect(clock.displayTime() == nil)
        #expect(await waitUntil { clock.layer.speed == 0 })
        let now = CACurrentMediaTime()
        #expect(
            clock.layer.convertTime(now + Self.lookahead, from: nil)
                == clock.layer.convertTime(now, from: nil)
        )

        CMTimebaseSetTime(timebase, time: CMTime(seconds: 5, preferredTimescale: 600))
        #expect(clock.displayTime() == nil)
    }

    /// 换绑立即作废旧 timebase 的发布值：返回之后读到的不是 nil 就是新 timebase 的时间，旧时间线不会冒充新时间线；
    /// 新 timebase 第一次写入后一定有读数。
    @Test
    func rebindingInvalidatesThePublishedTimeUntilTheNewTimebaseWrites() async throws {
        let old = try makeTimebase(time: 100, rate: 1)
        let new = try makeTimebase(time: 5, rate: 0)
        let clock = DanmakuTimebaseClock()
        clock.bind(old)
        #expect(await waitUntil { clock.displayTime() != nil })

        clock.bind(new)
        // `bind` 返回前已投递同步，时钟队列可能在主线程读取之前就为新纪元发布了 5，所以不要求此刻为 nil。旧的
        // 在 100 附近、新的停在 5，两者能明确区分，结果与读取时刻无关。
        #expect(clock.displayTime().map { abs($0 - 5) < Self.tolerance } ?? true)

        #expect(await waitUntil { clock.displayTime() != nil })
        #expect(abs((clock.displayTime() ?? 0) - 5) < Self.tolerance)
    }

    /// 每次写入之后都有一次唤醒，唤醒时读到的已是这次写入：暂停中跳时间之后不需要别的触发。
    @Test
    func everyWriteIsFollowedByAWakeThatSeesIt() async throws {
        let timebase = try makeTimebase(time: 20, rate: 0)
        let clock = DanmakuTimebaseClock()
        let wakes = WakeRecorder()
        clock.setWriteHandler { [weak clock] in wakes.record(clock?.displayTime()) }
        clock.bind(timebase)
        #expect(await waitUntil { abs((wakes.lastSeen ?? 0) - 20) < Self.tolerance })

        for target in [42.0, 7, 300] {
            CMTimebaseSetTime(timebase, time: CMTime(seconds: target, preferredTimescale: 600))
            #expect(await waitUntil { abs((wakes.lastSeen ?? 0) - target) < Self.tolerance })
        }
    }

    /// 主线程被挡住时，时钟层照样在 timebase 停下的时刻停下。
    ///
    /// 模拟暂停时主线程被播放器挡住：后台线程把速率设为 0，主线程等它返回之后一直忙等、不让出。时钟层的
    /// 同步不经过主线程，所以在主线程恢复之前就已停下；同步若依赖主线程，这里会超时。
    @Test
    func clockStopsWhileTheMainThreadIsBlocked() async throws {
        let timebase = try makeTimebase(time: 5, rate: 1)
        let clock = DanmakuTimebaseClock()
        clock.bind(timebase)
        #expect(await converges(clock, to: timebase))

        pauseWithoutYieldingTheMainThread(timebase, clock: clock)

        #expect(clock.layer.speed == 0)
        #expect(matches(clock, timebase))
    }

    /// 时钟写入与别的线程的 Core Animation 提交并发时不死锁。
    ///
    /// 时钟队列写时钟层的同时，另一条线程不停提交事务（AppKit 在显示链接线程上推进动画就是这样），主线程同时
    /// 读本地时间：三方都能继续。持着全局锁提交会与对方反序加锁而死锁，这里会卡住。
    @Test
    func clockWritesDoNotDeadlockWithAnotherThreadsCommits() async throws {
        let timebase = try makeTimebase(time: 0, rate: 0)
        let clock = DanmakuTimebaseClock()
        clock.bind(timebase)
        #expect(await converges(clock, to: timebase))
        let committer = BackgroundCommitter()
        committer.start()
        defer { committer.stop() }

        for step in 0..<Self.concurrentCommitRounds {
            CMTimebaseSetTime(timebase, time: CMTime(value: CMTimeValue(step), timescale: 600))
            _ = clock.layer.convertTime(CACurrentMediaTime(), from: nil)
        }

        #expect(await converges(clock, to: timebase))
    }

    /// 在一条后台线程上不停提交改自己 layer 的显式事务，直到 `stop`。
    private final class BackgroundCommitter: Sendable {
        private let isStopped = Atomic<Bool>(false)

        func start() {
            Thread { [self] in
                let layer = CALayer()
                var opacity: Float = 0
                while !isStopped.load(ordering: .acquiring) {
                    opacity = opacity < 1 ? opacity + 0.01 : 0
                    CATransaction.begin()
                    CATransaction.setDisableActions(true)
                    layer.opacity = opacity
                    CATransaction.commit()
                }
            }.start()
        }

        func stop() {
            isStopped.store(true, ordering: .releasing)
        }
    }

    /// 记录每次写入通知时读到的显示时间。
    @MainActor
    private final class WakeRecorder {
        private(set) var lastSeen: Double?

        func record(_ seconds: Double?) {
            lastSeen = seconds
        }
    }

    /// 此刻读到的发布值，落在读取前后两个宿主时间的 Core Animation 本地时间之间。
    private func publishedTimeMatchesTheLayer(_ clock: DanmakuTimebaseClock) -> Bool {
        let before = CACurrentMediaTime()
        guard let published = clock.displayTime() else { return false }
        let after = CACurrentMediaTime()
        return published >= clock.layer.convertTime(before, from: nil) - Self.tolerance
            && published <= clock.layer.convertTime(after, from: nil) + Self.tolerance
    }

    /// 让暂停在 `frozen` 的 timebase 以速率 1 起播，新直线在宿主时间 `delay` 秒之后才经过 `frozen`（系统按音频
    /// 输出延迟重锚时就是这样）；返回经过的那一刻。
    private func startPlaying(
        _ timebase: CMTimebase,
        at frozen: Double,
        after delay: Double
    ) -> Double {
        let start = CMClockGetTime(CMClockGetHostTimeClock()).seconds + delay
        CMTimebaseSetRateAndAnchorTime(
            timebase,
            rate: 1,
            anchorTime: CMTime(seconds: frozen, preferredTimescale: 1_000_000_000),
            immediateSourceTime: CMTime(seconds: start, preferredTimescale: 1_000_000_000)
        )
        return start
    }

    private func makeTimebase(time: Double, rate: Double) throws -> CMTimebase {
        var timebase: CMTimebase?
        let status = CMTimebaseCreateWithSourceClock(
            allocator: kCFAllocatorDefault,
            sourceClock: CMClockGetHostTimeClock(),
            timebaseOut: &timebase
        )
        let created = try #require(status == noErr ? timebase : nil)
        CMTimebaseSetTime(created, time: CMTime(seconds: time, preferredTimescale: 600))
        CMTimebaseSetRate(created, rate: rate)
        return created
    }

    /// 等到时钟层与 timebase 一致。
    private func converges(_ clock: DanmakuTimebaseClock, to timebase: CMTimebase) async -> Bool {
        await waitUntil { matches(clock, timebase) }
    }

    /// 时钟层在此刻与 `lookahead` 秒之后的本地时间都等于 timebase 在同一宿主时间的时间。
    private func matches(_ clock: DanmakuTimebaseClock, _ timebase: CMTimebase) -> Bool {
        let host = CACurrentMediaTime()
        return [0, Self.lookahead].allSatisfy { offset in
            let expected = mediaTime(of: timebase, atHost: host + offset)
            let local = clock.layer.convertTime(host + offset, from: nil)
            return abs(local - expected) < Self.tolerance
        }
    }

    /// 在后台线程把速率设为 0 并等它返回，然后在主线程上忙等时钟层停下，期间不让出主线程。
    private func pauseWithoutYieldingTheMainThread(
        _ timebase: CMTimebase,
        clock: DanmakuTimebaseClock
    ) {
        let paused = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            CMTimebaseSetRate(timebase, rate: 0)
            paused.signal()
        }
        paused.wait()
        let deadline = CACurrentMediaTime() + Self.blockedMainThreadTimeout
        while clock.layer.speed != 0, CACurrentMediaTime() < deadline {}
    }
}
