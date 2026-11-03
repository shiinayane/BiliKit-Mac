import BiliApplication
import BiliModels
import Foundation
import QuartzCore
import Testing

@testable import BiliDanmaku

/// 互动弹幕在呈现端的契约：卡片只在弹幕开着、已有本视频时间线、时钟读得到 D 时交给 renderer，关闭、换 item、
/// 停止时撤下，别的视频的卡片不显示；
/// 卡片按媒体时间显隐、中心按位置比例落在窗口里并往里收。
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct DanmakuCommandPresentationTests {
    private let identity = PlaybackItemIdentity(bvid: "BV1CommandCards", cid: 9)

    @Test
    func cardsWaitForTheTimelineAndDisplayTimeAndFollowTheDanmakuSwitch() {
        let backend = RecordingRenderingBackend()
        let controller = DanmakuPresentationController(backend: backend)
        let clock = ManualDisplayClock()
        let owner = UUID()
        let cards = [Self.gradeCard]
        controller.attachSurface(ownerID: owner, clock: clock)

        // 新视频的卡片先于它的第一个快照到达时先记下；有了快照还要等时钟读得到 D。
        controller.setCommandCards(cards, for: identity)
        controller.apply(snapshot(identity: identity, position: 1, generation: 1))
        #expect(backend.commandCardChanges.isEmpty)
        clock.time = 1
        controller.displayClockDidChange(ownerID: owner)
        #expect(backend.commandCardChanges == [cards])

        controller.setEnabled(false)
        controller.setEnabled(true)
        // 换 item 时先撤下，等新 item 的快照确认 identity 再显示。
        controller.playerItemWillChange(ownerID: owner)
        controller.apply(snapshot(identity: identity, position: 2, generation: 1))
        controller.stopPresentation()
        #expect(backend.commandCardChanges == [cards, [], cards, [], cards, []])
    }

    /// 卡片属于另一个视频时不显示。
    @Test
    func cardsForAnotherVideoAreNotShown() {
        let backend = RecordingRenderingBackend()
        let controller = DanmakuPresentationController(backend: backend)
        let clock = ManualDisplayClock()
        clock.time = 1
        controller.attachSurface(ownerID: UUID(), clock: clock)
        let other = PlaybackItemIdentity(bvid: "BV1AnotherVideo", cid: 10)

        controller.setCommandCards([Self.gradeCard], for: other)
        controller.apply(snapshot(identity: identity, position: 1, generation: 1))

        #expect(backend.commandCardChanges.isEmpty)
    }

    /// renderer 端到端：卡片挂在弹幕锚点层之后的容器里，换 backing scale 重画后数量不变，`stop` 时移除。
    @Test
    func rendererInstallsRedrawsAndClearsCards() throws {
        let renderer = CoreAnimationDanmakuRenderer(beginTimeAtMediaZero: 1e-100)
        renderer.updateSurfaceSize(width: 800, height: 450, backingScale: 2)
        renderer.setCommandCards([Self.gradeCard])
        let container = try #require(renderer.rootLayer.sublayers?.last)
        #expect(container.sublayers?.count == 1)

        renderer.updateSurfaceSize(width: 800, height: 450, backingScale: 1)
        #expect(container.sublayers?.count == 1)
        #expect(container.sublayers?.first?.contentsScale == 1)

        renderer.stop()
        #expect(container.sublayers?.isEmpty ?? true)
    }

    @Test
    func cardsLayOutByFractionAndStayInsideTheWindow() {
        let size = CGSize(width: 200, height: 60)
        let surface = CGSize(width: 800, height: 450)
        let margin = DanmakuCommandCardLayers.edgeMargin

        #expect(
            DanmakuCommandCardLayers.center(
                for: DanmakuCardPosition(x: 0.5, y: 0.65),
                cardSize: size,
                in: surface
            ) == CGPoint(x: 400, y: 450 * 0.65)
        )
        #expect(
            DanmakuCommandCardLayers.center(
                for: DanmakuCardPosition(x: 0.97, y: 0.99),
                cardSize: size,
                in: surface
            ) == CGPoint(x: 800 - margin - 100, y: 450 - margin - 30)
        )
        #expect(
            DanmakuCommandCardLayers.center(
                for: DanmakuCardPosition(x: 0.9, y: 0.5),
                cardSize: size,
                in: CGSize(width: 150, height: 450)
            ).x == 75
        )
    }

    @Test(arguments: [false, true])
    func cardLayersFadeDuringTheirMediaTime(reducesMotion: Bool) throws {
        let layers = DanmakuCommandCardLayers { $0 }
        layers.updateSurface(size: CGSize(width: 800, height: 450), backingScale: 2)
        layers.setCards([Self.gradeCard], reducesMotion: reducesMotion)

        let layer = try #require(layers.containerLayer.sublayers?.first)
        let animation = try #require(
            layer.animation(forKey: DanmakuCommandCardLayers.animationKey) as? CAKeyframeAnimation
        )
        #expect(layer.opacity == 0)
        #expect(animation.beginTime == 12)
        #expect(animation.duration == 5)
        #expect(animation.keyTimes == [0, 0.04, 0.96, 1])
        let scale = layer.animation(forKey: DanmakuCommandCardLayers.scaleAnimationKey)
        #expect((scale == nil) == reducesMotion)
        #expect(layer.bounds.width == DanmakuCommandCardArtwork.cardWidth)
        #expect(layer.contents != nil)

        layers.updateSurface(size: CGSize(width: 400, height: 300), backingScale: 2)
        #expect(layers.containerLayer.sublayers?.first === layer)
        #expect(layer.position.x == 200)

        layers.setCards([], reducesMotion: reducesMotion)
        #expect(layers.containerLayer.sublayers?.isEmpty ?? true)
    }

    private static let gradeCard = DanmakuCommandCard(
        id: "command:1",
        timeSeconds: 12,
        durationSeconds: 5,
        position: DanmakuCardPosition(x: 0.5, y: 0.65),
        content: .grade(
            DanmakuGradeCard(title: "评分", averageScore: 9.9, participantCount: 8029, myScore: nil)
        )
    )
}
