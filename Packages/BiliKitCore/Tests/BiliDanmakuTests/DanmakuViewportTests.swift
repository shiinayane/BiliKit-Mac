import BiliApplication
import BiliModels
import Foundation
import Testing

@testable import BiliDanmaku

/// 固定取景框的契约：占用的车道全部在窗口的可见车道数之内才显示，跨过可见边界的整条不显示；滚动弹幕
/// 锚在右边缘，右缘（尾缘）越过窗口左边界时不再可见，窗口与规划画布一样宽时就是走完的时刻；顶部底部
/// 弹幕整个停留时长可见。
@Suite
struct DanmakuViewportTests {
    @Test(arguments: [DanmakuPresentationMode.scrolling, .top, .bottom])
    func onlyPlacementsWhoseLanesAllFitAreShown(mode: DanmakuPresentationMode) {
        // 200pt 高、全屏显示区域：5 条可见车道。
        let viewport = DanmakuViewport(width: 600, height: 200, displayAreaFraction: 1)

        #expect(viewport.visibleLaneCount == 5)
        #expect(viewport.showsLanes(of: placement(mode: mode, lane: 4, height: 30)))
        #expect(!viewport.showsLanes(of: placement(mode: mode, lane: 5, height: 30)))
        #expect(viewport.showsLanes(of: placement(mode: mode, lane: 3, height: 60)))
        #expect(!viewport.showsLanes(of: placement(mode: mode, lane: 4, height: 60)))
    }

    @Test
    func visibleLaneCountUsesTheDisplayArea() {
        let viewport = DanmakuViewport(width: 600, height: 720, displayAreaFraction: 0.25)

        #expect(viewport.visibleLaneCount == 5)
    }

    @Test
    func scrollingLeavesANarrowWindowWhenItsTrailingEdgeCrossesIt() {
        let scrolling = placement(mode: .scrolling, lane: 0, height: 30, width: 100, duration: 13)

        // 规划画布 1200pt：13 秒走完 1300pt，窗口 600pt 时走 700pt 后右缘越过窗口左边界。
        let narrow = DanmakuViewport(width: 600, height: 200, displayAreaFraction: 1)
        #expect(abs(narrow.visibleUntil(scrolling) - (10 + 7)) < 1e-9)
        let full = DanmakuViewport(width: 1_200, height: 200, displayAreaFraction: 1)
        #expect(full.visibleUntil(scrolling) == scrolling.expiresAtSeconds)
    }

    @Test(arguments: [DanmakuPresentationMode.top, .bottom])
    func fixedDanmakuStayVisibleForTheirWholeDuration(mode: DanmakuPresentationMode) {
        let fixed = placement(mode: mode, lane: 0, height: 30, duration: 4)
        let narrow = DanmakuViewport(width: 300, height: 200, displayAreaFraction: 1)

        #expect(narrow.visibleUntil(fixed) == fixed.expiresAtSeconds)
    }

    /// 规划画布 1200pt 上 10 秒进场的一条弹幕。
    private func placement(
        mode: DanmakuPresentationMode,
        lane: Int,
        height: Double,
        width: Double = 100,
        duration: Double = 4
    ) -> DanmakuLanePlacement {
        DanmakuLanePlacement(
            request: DanmakuLaneRequest(
                event: danmakuEvent(id: "viewport", time: 10, mode: mode),
                width: width,
                height: height,
                durationSeconds: duration,
                countBadge: nil
            ),
            laneIndex: lane,
            planningWidth: 1_200,
            admittedAtSeconds: 10,
            expiresAtSeconds: 10 + duration
        )
    }
}
