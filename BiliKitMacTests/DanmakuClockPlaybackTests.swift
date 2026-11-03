import AVFoundation
import AVKit
import AppKit
import BiliApplication
import BiliDanmaku
import BiliModels
import Synchronization
import Testing

@testable import BiliKit

/// 固定显示时间来自真实播放器的契约。
///
/// 证明的范围：弹幕 layer 挂在弹幕 overlay 的时钟层下，局部时间等于播放 item 的时间，暂停中 seek、开播、两倍速
/// 与再暂停之后都一致（时钟层在后台队列上异步落地，等到一致为止）；媒体时间
/// 0 的弹幕用时钟定义的哨兵开始，在真实播放下处于可见区间；暂停中 seek 之后开播，屏上仍是同一组
/// layer（呈现控制器没有清屏重建）；反复暂停、恢复与 seek 时，同一段播放里显示时间不后退，与 timebase 的
/// 偏差有界、不随轮数增长。
///
/// 依赖：测试宿主能连上窗口服务；用带音轨的本地静音媒体，开播、改速率与暂停时系统会按音频时钟重新锚定
/// timebase，通知来自真实播放器的内部队列。时间线快照是手工喂给控制器的，不经过 `AVPlayerTimelineAdapter`。
///
/// 不能证明：渲染服务器实际画出来的像素与位置、肉眼是否闪烁、真实 B 站 HLS 与码率切换、PiP 与 detached
/// 全屏下的同步。测试宿主的音频输出不一定是有线或蓝牙设备，起播回退的幅度与真机不同。
@Suite(.serialized, .timeLimit(.minutes(1)))
@MainActor
struct DanmakuClockPlaybackTests {
    /// 局部时间与 item 时间的容差（秒）：两者按同一个宿主时刻换算，只差浮点与 CMTime 取整误差；起播等待里的
    /// 差值由 `waitUntil` 等过去，不算进容差。
    private static let timeTolerance = 1e-3
    /// 反复操作的轮数与媒体时长：每轮播放一小段再 seek，落点留出离结尾的余量。
    private static let repeatedRounds = 50
    private static let repeatedMediaSeconds = 30.0
    /// 每轮播放的媒体时长（秒）：够起播等待结束、timebase 稳定推进。
    private static let playedSecondsPerRound = 0.15
    /// 同一段播放里相邻两次采样的局部时间按浮点比较；只容许舍入误差。
    private static let monotonicSlack = 1e-6
    /// 速率大于 0 时局部时间与 timebase 偏差的上界（秒）：每个样本按同一个宿主时刻换算两边，偏差只来自起播
    /// 等待；上界大于任何音频输出延迟（蓝牙最多约 0.22 秒），远小于一次 seek 的距离；偏差若随轮数累积会越过它。
    private static let deviationBound = 0.3

    @Test
    func danmakuTimeFollowsTheItemThroughPausedSeekPlayRateChangeAndPause() async throws {
        let fixture = try PlaybackFixture(mediaSeconds: 8)
        defer { fixture.tearDown() }
        let renderer = fixture.renderer
        let controller = fixture.controller
        let item = fixture.item
        let player = fixture.player
        #expect(await waitUntil(timeout: .seconds(10)) { item.status == .readyToPlay })

        // 暂停中 seek 到 2 秒，弹幕按 2 秒整屏挂上。
        player.pause()
        await player.seek(to: CMTime(seconds: 2, preferredTimescale: 600))
        let identity = PlaybackItemIdentity(bvid: "sync-fixture", cid: 1)
        controller.apply(snapshot(identity, position: 2, rate: 0, state: .paused, discontinuity: 2))
        controller.setSegments(
            [
                1: [
                    Self.event(id: "zero", time: 0, mode: .top),
                    Self.event(id: "scroll", time: 1.5),
                    Self.event(id: "top", time: 1.8, mode: .top)
                ]
            ],
            for: identity
        )
        #expect(
            await waitUntil(timeout: .seconds(5)) {
                danmakuLayers(of: renderer).count == 3
            }
        )
        let layers = danmakuLayers(of: renderer)
        await expectLocalTime(of: renderer.rootLayer, matches: item)

        // 媒体时间 0 的弹幕：开始时间是时钟定义的哨兵，此刻（2 秒）仍在它 4 秒的可见区间里。
        let animations = layers.flatMap { layer in
            (layer.animationKeys() ?? []).compactMap { layer.animation(forKey: $0) }
        }
        let zeroAnimation = try #require(
            animations.first { $0.beginTime == DanmakuTimebaseClock.beginTimeAtMediaZero }
        )
        let zeroLocal = renderer.rootLayer.convertTime(CACurrentMediaTime(), from: nil)
        #expect(zeroLocal >= zeroAnimation.beginTime)
        #expect(zeroLocal < zeroAnimation.beginTime + zeroAnimation.duration)

        // 开播：同一组 layer 继续走，不清屏。
        player.play()
        controller.apply(
            snapshot(identity, position: 2, rate: 1, state: .playing, discontinuity: 2)
        )
        #expect(await waitUntil(timeout: .seconds(5)) { item.currentTime().seconds > 2.4 })
        await expectLocalTime(of: renderer.rootLayer, matches: item)
        #expect(danmakuLayers(of: renderer).elementsEqual(layers, by: ===))

        // 两倍速：局部时间按两倍推进。
        player.rate = 2
        let rateChangedAt = item.currentTime().seconds
        #expect(
            await waitUntil(timeout: .seconds(5)) {
                item.currentTime().seconds > rateChangedAt + 0.6
            }
        )
        await expectLocalTime(of: renderer.rootLayer, matches: item)

        // 暂停：局部时间停在 item 停下的时间，之后不再推进。
        player.pause()
        #expect(
            await waitUntil(timeout: .seconds(5)) {
                let now = CACurrentMediaTime()
                return renderer.rootLayer.convertTime(now + 1, from: nil)
                    == renderer.rootLayer.convertTime(now, from: nil)
            }
        )
        await expectLocalTime(of: renderer.rootLayer, matches: item)
    }

    /// 反复「播放一小段 → 暂停 → 暂停中 seek」：后台线程每 1ms 采样弹幕层的局部时间与 item timebase，同一段
    /// 播放里速率大于 0 的相邻两次采样之间局部时间不后退；速率大于 0 时与 timebase 的偏差只来自起播等待（一个
    /// 音频输出延迟），每轮的上界都在同一个常数以内。
    @Test
    func repeatedPauseResumeAndSeekKeepDanmakuTimeMonotonicAndBounded() async throws {
        let fixture = try PlaybackFixture(mediaSeconds: Self.repeatedMediaSeconds)
        defer { fixture.tearDown() }
        let item = fixture.item
        let player = fixture.player
        #expect(await waitUntil(timeout: .seconds(10)) { item.status == .readyToPlay })
        let timebase = try #require(item.timebase)
        let sampler = TimeSampler(layer: fixture.renderer.rootLayer, timebase: timebase)
        sampler.start()

        for round in 0..<Self.repeatedRounds {
            sampler.setRound(round)
            let started = item.currentTime().seconds
            sampler.beginSegment()
            player.play()
            #expect(
                await waitUntil(timeout: .seconds(5)) {
                    item.currentTime().seconds > started + Self.playedSecondsPerRound
                }
            )
            sampler.beginSegment()
            player.pause()
            #expect(await waitUntil(timeout: .seconds(5)) { CMTimebaseGetRate(timebase) == 0 })
            // 落点在媒体里按黄金分割序列铺开，前后跳都有。
            let spread = (Double(round) * 0.618_033_988_749_895).truncatingRemainder(dividingBy: 1)
            let target = 1 + spread * (Self.repeatedMediaSeconds - 4)
            await player.seek(to: CMTime(seconds: target, preferredTimescale: 600))
        }
        let samples = sampler.stop()

        let backward = zip(samples, samples.dropFirst()).filter { earlier, later in
            earlier.segment == later.segment && earlier.rate > 0 && later.rate > 0
                && later.local < earlier.local - Self.monotonicSlack
        }
        #expect(backward.isEmpty, "速率大于 0 时显示时间后退 \(backward.count) 次")
        var deviations = Array(repeating: 0.0, count: Self.repeatedRounds)
        for sample in samples where sample.rate > 0 {
            let deviation = abs(sample.local - sample.media)
            deviations[sample.round] = max(deviations[sample.round], deviation)
        }
        let early = deviations.prefix(10).max() ?? 0
        let late = deviations.suffix(10).max() ?? 0
        #expect(
            deviations.allSatisfy { $0 < Self.deviationBound },
            "每轮最大偏差：前 10 轮 \(early)，后 10 轮 \(late)"
        )
    }

    /// 时钟层由 timebase 通知在后台队列上更新，改变播放状态之后等到局部时间与 item 时间一致。
    ///
    /// 两边按同一个宿主时刻换算：分两次各取此刻时，两倍速下读取之间隔 25ms 就差出 0.05 秒。
    private func expectLocalTime(
        of layer: CALayer,
        matches item: AVPlayerItem,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async {
        var local = 0.0
        var itemTime = 0.0
        let matched = await waitUntil(timeout: .seconds(5)) {
            guard let timebase = item.timebase else { return false }
            let host = CACurrentMediaTime()
            local = layer.convertTime(host, from: nil)
            itemTime = mediaTime(of: timebase, atHost: host)
            return abs(local - itemTime) < Self.timeTolerance
        }
        #expect(
            matched,
            "弹幕层局部时间 \(local) 与 item 时间 \(itemTime) 不一致",
            sourceLocation: sourceLocation
        )
    }

    private func snapshot(
        _ identity: PlaybackItemIdentity,
        position: Double,
        rate: Double,
        state: PlaybackTimelineState,
        discontinuity: UInt64
    ) -> PlaybackTimelineSnapshot {
        PlaybackTimelineSnapshot(
            identity: identity,
            positionSeconds: position,
            durationSeconds: 8,
            rate: rate,
            state: state,
            discontinuityGeneration: discontinuity
        )
    }

    private static func event(
        id: String,
        time: Double,
        mode: DanmakuPresentationMode = .scrolling
    ) -> DanmakuEvent {
        DanmakuEvent(
            id: id,
            timeSeconds: time,
            mode: mode,
            text: "同步弹幕 sync",
            fontSize: 25,
            colorRGB: 0xFFFFFF,
            colorStyle: .solid,
            weight: 1,
            isHighLike: false,
            isUploader: false
        )
    }
}

/// 真实播放器、弹幕宿主视图与窗口的一套组装；测试结束时调用 `tearDown`。
@MainActor
private struct PlaybackFixture {
    let renderer: CoreAnimationDanmakuRenderer
    let controller: DanmakuPresentationController
    let item: AVPlayerItem
    let player: AVPlayer
    private let view: NativePlayerHostView
    private let window: NSWindow
    private let media: SilentAudioFixture

    /// 写一段 `mediaSeconds` 秒的带音轨静音媒体，挂进无边框窗口里的播放器宿主并开始观察 item。
    init(mediaSeconds: Double) throws {
        media = try SilentAudioFixture(seconds: mediaSeconds)
        renderer = CoreAnimationDanmakuRenderer(
            beginTimeAtMediaZero: DanmakuTimebaseClock.beginTimeAtMediaZero
        )
        controller = DanmakuPresentationController(backend: renderer)
        view = NativePlayerHostView(
            renderer: renderer,
            controller: controller,
            beginMomentaryPlaybackRate: nil,
            endMomentaryPlaybackRate: nil
        )
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 360),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = view
        window.orderFrontRegardless()
        item = AVPlayerItem(url: media.mediaURL)
        let player = SeekTrackingPlayer(playerItem: item)
        player.automaticallyWaitsToMinimizeStalling = false
        self.player = player
        view.attachPlayer(player)
        view.layoutSubtreeIfNeeded()
    }

    func tearDown() {
        player.pause()
        view.danmakuOverlay.detachSurface()
        view.stopObservingPlayerItemChanges()
        view.player = nil
        window.orderOut(nil)
        media.remove()
    }
}

/// 在一条后台线程上每 1ms 采样一次弹幕层的局部时间与 timebase 的时间、速率，直到 `stop`。
///
/// 采样线程只读 layer 的时间换算与 timebase，不碰主线程状态；样本、轮次与播放段代号由 `state` 这把锁保护。
/// 每个样本只取一次宿主时刻，局部时间与媒体时间都按它换算，偏差与采样线程何时被抢占无关。
private final class TimeSampler: @unchecked Sendable {
    struct Sample {
        let round: Int
        /// 测量时所在的播放段；单调性只在同一段里比较。
        let segment: Int
        let local: Double
        let media: Double
        let rate: Double
    }

    /// 采样间隔（秒）。
    private static let interval = 0.001

    // layer 只用于读时间换算，Core Animation 允许在任意线程读；`@unchecked Sendable` 由此成立，其余可变状态
    // 都在 `state` 里。
    private let layer: CALayer
    private let timebase: CMTimebase
    private let state = Mutex((round: 0, segment: 0, samples: [Sample](), isStopped: false))
    private let finished = DispatchSemaphore(value: 0)

    init(layer: CALayer, timebase: CMTimebase) {
        self.layer = layer
        self.timebase = timebase
    }

    func start() {
        Thread { [self] in
            while true {
                let segment = state.withLock { $0.segment }
                let host = CACurrentMediaTime()
                let local = layer.convertTime(host, from: nil)
                let media = mediaTime(of: timebase, atHost: host)
                let rate = CMTimebaseGetRate(timebase)
                let isStopped = state.withLock { state in
                    // 测量期间换了段（seqlock）就丢弃这个样本：它可能一半属于上一段、一半属于下一段。
                    if state.segment == segment {
                        state.samples.append(
                            Sample(
                                round: state.round,
                                segment: segment,
                                local: local,
                                media: media,
                                rate: rate
                            )
                        )
                    }
                    return state.isStopped
                }
                if isStopped { break }
                Thread.sleep(forTimeInterval: Self.interval)
            }
            finished.signal()
        }.start()
    }

    func setRound(_ round: Int) {
        state.withLock { $0.round = round }
    }

    /// 进入新的播放段，由测试在 `play()` 与 `pause()` 之前各调用一次。
    ///
    /// 采样线程若睡过一整轮「暂停 → 往回 seek → 开播」，前后两个样本的速率都大于 0、局部时间却因 seek 后退；
    /// 按段号区分后，它们不会被当作同一段播放里的相邻样本。
    func beginSegment() {
        state.withLock { $0.segment += 1 }
    }

    /// 停止采样并等采样线程退出，返回全部样本。
    func stop() -> [Sample] {
        state.withLock { $0.isStopped = true }
        finished.wait()
        return state.withLock { $0.samples }
    }
}
