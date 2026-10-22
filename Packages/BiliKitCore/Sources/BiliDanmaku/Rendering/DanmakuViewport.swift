import BiliModels
import Foundation

/// 取景框：窗口在规划画布上露出的部分，决定布局表里哪些弹幕此刻可见。
///
/// 布局表按规划画布（承载窗口的屏幕）排一次，窗口尺寸不是布局输入（见 docs/ARCHITECTURE.md「弹幕」）。
/// 可见条件是 placement、媒体时间与窗口尺寸的纯函数：
/// - 车道从各自的锚定边数起（滚动与顶部从顶边，底部从底边），占用的车道全部小于可见车道数才显示；
///   跨过可见边界的多车道弹幕整条不显示。
/// - 滚动弹幕锚在右边缘，从进场到右缘（尾缘）越过窗口左边界之前可见：
///   t_i ≤ t < t_i + 时长 × (窗口宽 + w) / (规划宽 + w)。顶部与底部弹幕在整个停留时长内可见。
///
/// 由 `DanmakuPresentationController` 按窗口尺寸与显示区域构造，交给 `DanmakuMaterializer`。
struct DanmakuViewport: Sendable, Equatable {
    let width: Double
    /// 窗口里可见的车道数，与规划画布的车道数用同一个计算（`DanmakuLaneConfiguration.laneCount`）。
    let visibleLaneCount: Int

    init(width: Double, height: Double, displayAreaFraction: Double) {
        self.width = width.isFinite ? max(width, 0) : 0
        visibleLaneCount = DanmakuLaneConfiguration.laneCount(
            surfaceHeight: height.isFinite ? max(height, 0) : 0,
            displayAreaFraction: displayAreaFraction
        )
    }

    /// 此刻是否应在屏：车道全部落在窗口里，且在 `position` 之后仍可见（含尚未进场的前瞻弹幕）。
    ///
    /// materializer 决定挂上、保留与迟到纹理是否挂上都只用这一个判断。
    func shows(_ placement: DanmakuLanePlacement, at position: Double) -> Bool {
        showsLanes(of: placement) && visibleUntil(placement) > position
    }

    /// 占用的车道是否全部落在窗口里。
    func showsLanes(of placement: DanmakuLanePlacement) -> Bool {
        let span = placement.laneSpan
        return span > 0 && placement.laneIndex + span <= visibleLaneCount
    }

    /// 弹幕在窗口里可见到哪个媒体时刻为止。
    ///
    /// 滚动弹幕按 placement 自己的匀速运动换算右缘（尾缘）越过窗口左边界的时刻；窗口不比规划画布窄
    /// 时就是 `expiresAtSeconds`。
    func visibleUntil(_ placement: DanmakuLanePlacement) -> Double {
        switch placement.request.event.mode {
        case .top, .bottom:
            return placement.expiresAtSeconds
        case .scrolling:
            let request = placement.request
            let travel = DanmakuMotionPolicy.scrollingTravel(
                textWidth: request.width,
                planningWidth: placement.planningWidth
            )
            guard travel > 0 else { return placement.admittedAtSeconds }
            let fraction = min((width + request.width) / travel, 1)
            return placement.admittedAtSeconds + request.durationSeconds * fraction
        }
    }
}
