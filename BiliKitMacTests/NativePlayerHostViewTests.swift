import AVFoundation
import AVKit
import AppKit
import BiliApplication
import BiliDanmaku
import BiliModels
import Testing

@testable import BiliKit

/// 播放器宿主视图与弹幕 overlay 的生命周期：Now Playing 交给进程级控制器，准备播放期间屏蔽原生控件的操作。
///
/// overlay 释放时呈现控制器与时钟随之释放；弹幕 surface 在窗口间挪动时保留已挂的弹幕；换 item 时在同一次调用
/// 里清屏并把时钟换绑到新 item。
@Suite(.serialized, .timeLimit(.minutes(1)))
struct NativePlayerHostViewTests {
    /// 局部时间与 item 时间的容差（秒）：两者按同一个宿主时刻换算，只差浮点与 CMTime 取整误差。
    private static let localTimeTolerance = 1e-3

    @Test
    @MainActor
    func nativePlayerViewLeavesNowPlayingOwnershipToProcessController() {
        let renderer = CoreAnimationDanmakuRenderer(
            beginTimeAtMediaZero: DanmakuTimebaseClock.beginTimeAtMediaZero
        )
        let controller = DanmakuPresentationController(backend: renderer)
        let view = NativePlayerHostView(
            renderer: renderer,
            controller: controller,
            beginMomentaryPlaybackRate: nil,
            endMomentaryPlaybackRate: nil
        )

        #expect(!view.updatesNowPlayingInfoCenter)
    }

    @Test
    @MainActor
    func playbackPreparationBlocksNativePlayerInputAndAccessibility() {
        let renderer = CoreAnimationDanmakuRenderer(
            beginTimeAtMediaZero: DanmakuTimebaseClock.beginTimeAtMediaZero
        )
        let controller = DanmakuPresentationController(backend: renderer)
        let view = NativePlayerHostView(
            renderer: renderer,
            controller: controller,
            beginMomentaryPlaybackRate: nil,
            endMomentaryPlaybackRate: nil
        )

        view.setPlaybackPreparationBlocked(false)
        #expect(view.controlsStyle == .default)
        #expect(!view.isAccessibilityHidden())

        view.setPlaybackPreparationBlocked(true)
        // 控制条样式不随准备状态切换：切回时 AVKit 会重建整套控制条。
        #expect(view.controlsStyle == .default)
        #expect(!view.acceptsFirstResponder)
        #expect(view.hitTest(.zero) == nil)
        #expect(view.isAccessibilityHidden())

        view.setPlaybackPreparationBlocked(false)
        #expect(view.controlsStyle == .default)
        #expect(!view.isAccessibilityHidden())
    }

    /// overlay 释放之后，呈现控制器与时钟（看它的时钟层）也随之释放：控制器接管 surface 时持有时钟，时钟的
    /// 写入回调只弱引用 overlay，不强持有控制器，没有引用环。
    @Test
    @MainActor
    func releasingTheOverlayReleasesTheControllerAndTheClock() async {
        weak var releasedController: DanmakuPresentationController?
        weak var releasedClockLayer: CALayer?
        do {
            let renderer = CoreAnimationDanmakuRenderer(
                beginTimeAtMediaZero: DanmakuTimebaseClock.beginTimeAtMediaZero
            )
            let controller = DanmakuPresentationController(backend: renderer)
            let overlay = DanmakuOverlayView(renderer: renderer, controller: controller)
            overlay.frame = NSRect(x: 0, y: 0, width: 400, height: 200)
            let window = NSWindow(
                contentRect: overlay.frame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            window.contentView?.addSubview(overlay)
            overlay.layoutSubtreeIfNeeded()
            releasedController = controller
            releasedClockLayer = renderer.rootLayer.superlayer
            #expect(releasedClockLayer != nil)
            overlay.removeFromSuperview()
        }

        #expect(await waitUntil { releasedController == nil && releasedClockLayer == nil })
    }

    /// 弹幕位置来自时钟层的显示时间，所以先绑定一个停在媒体时间 0 的 item：时钟从未绑定时读不到时间，
    /// 什么都不挂。
    @Test
    @MainActor
    func danmakuSurfaceSurvivesTemporaryWindowReparenting() async throws {
        let media = try SilentAudioFixture(seconds: 4)
        defer { media.remove() }
        let item = AVPlayerItem(url: media.mediaURL)
        let renderer = CoreAnimationDanmakuRenderer(
            beginTimeAtMediaZero: DanmakuTimebaseClock.beginTimeAtMediaZero
        )
        let backend = InstallSignalingBackend(renderer: renderer)
        let controller = DanmakuPresentationController(backend: backend)
        let overlay = DanmakuOverlayView(
            renderer: renderer,
            controller: controller
        )
        overlay.frame = NSRect(x: 0, y: 0, width: 800, height: 300)
        let firstWindow = NSWindow(
            contentRect: overlay.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let secondWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_200, height: 500),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        firstWindow.contentView?.addSubview(overlay)
        overlay.layoutSubtreeIfNeeded()
        overlay.bind(to: item)
        #expect(renderer.rootLayer.superlayer != nil)

        let identity = PlaybackItemIdentity(bvid: "fixture", cid: 1)
        let beforeReparent = danmakuEvent(at: 1, id: "before-reparent", mode: .scrolling)
        controller.apply(pausedSnapshot(identity: identity, position: 1))
        controller.setSegments([1: [beforeReparent]], for: identity)
        await backend.waitUntilInstalled(beforeReparent.id)
        #expect(danmakuLayers(of: renderer).count == 1)
        let firstLayer = try #require(danmakuLayers(of: renderer).first)

        overlay.removeFromSuperview()
        #expect(overlay.window == nil)
        #expect(renderer.rootLayer.superlayer != nil)
        #expect(danmakuLayers(of: renderer).contains { $0 === firstLayer })
        #expect(danmakuLayers(of: renderer).count == 1)

        overlay.frame = .zero
        overlay.layoutSubtreeIfNeeded()
        let duringReparent = danmakuEvent(at: 1.5, id: "during-reparent", mode: .top)
        controller.setSegments([1: [beforeReparent, duringReparent]], for: identity)
        await backend.waitUntilInstalled(duringReparent.id)
        #expect(danmakuLayers(of: renderer).count == 2)

        overlay.frame = secondWindow.contentView?.bounds ?? .zero
        secondWindow.contentView?.addSubview(overlay)
        overlay.layoutSubtreeIfNeeded()
        #expect(renderer.rootLayer.superlayer != nil)
        #expect(danmakuLayers(of: renderer).contains { $0 === firstLayer })
        #expect(danmakuLayers(of: renderer).count == 2)

        overlay.detachSurface()
        #expect(renderer.rootLayer.superlayer == nil)
        #expect(danmakuLayers(of: renderer).count == 0)
    }

    /// 弹幕时钟不会随 `replaceCurrentItem` 自动换绑：宿主在 `currentItem` 变化时、在这次调用之内先清屏，再
    /// 换绑到新 item 的 timebase，旧 item 的弹幕不会留在新 item 的时间线上；新 timebase 写入之后弹幕的局部
    /// 时间等于新 item 的时间，按原布局表挂回。
    ///
    /// 两个 item 用同一段带音轨的本地静音媒体：旧 item 先 seek 到 3 秒，新 item 从 0 开始，两者可区分。
    @Test
    @MainActor
    func danmakuClockFollowsTheCurrentItemAndClearsOnReplacement() async throws {
        let renderer = CoreAnimationDanmakuRenderer(
            beginTimeAtMediaZero: DanmakuTimebaseClock.beginTimeAtMediaZero
        )
        let controller = DanmakuPresentationController(backend: renderer)
        let view = NativePlayerHostView(
            renderer: renderer,
            controller: controller,
            beginMomentaryPlaybackRate: nil,
            endMomentaryPlaybackRate: nil
        )
        view.frame = NSRect(x: 0, y: 0, width: 800, height: 300)
        let window = NSWindow(
            contentRect: view.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView?.addSubview(view)
        view.layoutSubtreeIfNeeded()
        let media = try SilentAudioFixture(seconds: 8)
        defer { media.remove() }
        let mediaURL = media.mediaURL
        let first = AVPlayerItem(url: mediaURL)
        let second = AVPlayerItem(url: mediaURL)
        let player = SeekTrackingPlayer(playerItem: first)
        view.attachPlayer(player)
        defer { view.stopObservingPlayerItemChanges() }
        #expect(await waitUntil(timeout: .seconds(10)) { first.status == .readyToPlay })
        await player.seek(to: CMTime(seconds: 3, preferredTimescale: 600))
        #expect(
            await waitUntil(timeout: .seconds(5)) {
                first.currentTime().seconds > 2.9
                    && localTime(of: renderer.rootLayer, matches: first)
            }
        )

        let identity = PlaybackItemIdentity(bvid: "item-fixture", cid: 1)
        controller.apply(pausedSnapshot(identity: identity, position: 1))
        controller.setSegments(
            [1: [danmakuEvent(at: 1, id: "before-replacement", mode: .top)]],
            for: identity
        )
        #expect(await waitUntil { danmakuLayers(of: renderer).count == 1 })

        player.replaceCurrentItem(with: second)
        // currentItem 的 KVO 在 replaceCurrentItem 内部同步触发，宿主在同一次调用里清屏并换绑时钟（overlay 先清屏
        // 再换绑）：返回时屏已清空，不等下一个主线程回合。
        #expect(danmakuLayers(of: renderer).isEmpty)

        // 新 item 的快照到达、新 timebase 写入之后，按新 item 的时间挂回同一张布局表。
        controller.apply(pausedSnapshot(identity: identity, position: 0))
        #expect(
            await waitUntil(timeout: .seconds(5)) {
                danmakuLayers(of: renderer).count == 1
                    && localTime(of: renderer.rootLayer, matches: second)
            }
        )
        #expect(second.currentTime().seconds < 1)
        #expect(renderer.rootLayer.superlayer != nil)
    }

    /// 弹幕层的局部时间与 item 时间在同一个宿主时刻相差不到 `localTimeTolerance`；item 还没有 timebase 时不算一致。
    @MainActor
    private func localTime(of layer: CALayer, matches item: AVPlayerItem) -> Bool {
        guard let timebase = item.timebase else { return false }
        let host = CACurrentMediaTime()
        return abs(layer.convertTime(host, from: nil) - mediaTime(of: timebase, atHost: host))
            < Self.localTimeTolerance
    }

    private func danmakuEvent(
        at time: Double,
        id: String,
        mode: DanmakuPresentationMode
    ) -> DanmakuEvent {
        DanmakuEvent(
            id: id,
            timeSeconds: time,
            mode: mode,
            text: "reparent fixture",
            fontSize: 24,
            colorRGB: 0xFFFFFF,
            colorStyle: .solid,
            weight: 1,
            isHighLike: false,
            isUploader: false
        )
    }

    private func pausedSnapshot(
        identity: PlaybackItemIdentity,
        position: Double
    ) -> PlaybackTimelineSnapshot {
        PlaybackTimelineSnapshot(
            identity: identity,
            positionSeconds: position,
            durationSeconds: 100,
            rate: 0,
            state: .paused,
            discontinuityGeneration: 1
        )
    }
}

/// 把呈现控制器对 backend 的调用原样转给真实 renderer，并在弹幕挂上之后唤醒等它的测试。
///
/// 一条弹幕挂上之前要依次等时钟层第一次发布 D（时钟队列再回主线程）、后台排车道与后台栅格化，耗时随机器
/// 负载变化；测试等「挂上」这个事件，再同步检查 layer 树，不按固定时长轮询，超时只由 suite 的时间上限兜底。
@MainActor
private final class InstallSignalingBackend: DanmakuRenderingBackend {
    let renderer: CoreAnimationDanmakuRenderer
    /// 挂上过的弹幕 ID；之后被移除也不删，测试另行检查此刻的 layer 树。
    private var installedEventIDs: Set<String> = []
    private var waiters: [(eventID: String, continuation: CheckedContinuation<Void, Never>)] = []

    init(renderer: CoreAnimationDanmakuRenderer) {
        self.renderer = renderer
    }

    /// 等到 `eventID` 挂上过一次；已挂上过时立即返回。
    func waitUntilInstalled(_ eventID: String) async {
        guard !installedEventIDs.contains(eventID) else { return }
        await withCheckedContinuation { continuation in
            waiters.append((eventID, continuation))
        }
    }

    func prepare(
        _ event: DanmakuEvent,
        preparationID: UInt64,
        completion: @escaping @MainActor @Sendable (DanmakuPreparationResult) -> Void
    ) {
        renderer.prepare(event, preparationID: preparationID, completion: completion)
    }

    @discardableResult
    func install(
        _ placement: DanmakuLanePlacement,
        preparationID: UInt64,
        at position: Double
    ) -> DanmakuInstallResult {
        let result = renderer.install(placement, preparationID: preparationID, at: position)
        guard result.isInstalled else { return result }
        let eventID = placement.request.event.id
        installedEventIDs.insert(eventID)
        let ready = waiters.filter { $0.eventID == eventID }
        waiters.removeAll { $0.eventID == eventID }
        for waiter in ready { waiter.continuation.resume() }
        return result
    }

    @discardableResult
    func update(_ placement: DanmakuLanePlacement) -> Bool { renderer.update(placement) }
    func discardPreparation(preparationID: UInt64) {
        renderer.discardPreparation(preparationID: preparationID)
    }
    func cancelAllPreparations() { renderer.cancelAllPreparations() }
    func remove(eventID: String) { renderer.remove(eventID: eventID) }
    func clearAll() { renderer.clearAll() }
    func setOpacity(_ opacity: DanmakuOpacity) { renderer.setOpacity(opacity) }
    func setCommandCards(_ cards: [DanmakuCommandCard]) { renderer.setCommandCards(cards) }
    func updateSurfaceSize(width: Double, height: Double, backingScale: Double) {
        renderer.updateSurfaceSize(width: width, height: height, backingScale: backingScale)
    }
    func stop() { renderer.stop() }
}
