import AppKit
import BiliUI

/// 浮在内容上的 AppKit 按钮的显隐：按 `OverlayFadePolicy` 淡入淡出，“减弱动态效果”开启时直接显隐。
///
/// 「返回顶部」按钮与相关推荐横排的左右翻页按钮共用。拥有一个视图的显隐目标与淡出代次；视图本身、它的位置与
/// 何时该显示由持有它的滚动视图决定。淡出只改透明度，完成后才设 `isHidden`：隐藏的视图不接受点击、也不在
/// 读屏树里，透明度为 0 却未隐藏的视图仍会挡住下面的内容并被 VoiceOver 读到。
@MainActor
final class NativeFadingVisibility {
    private let view: NSView
    /// 视图此刻应当显示还是隐藏；调用方可以每一帧都设，只有它翻转时才开始一次淡入或淡出。
    private var isShown: Bool
    /// 每次显隐目标翻转时递增；淡出的完成回调只在代次未变时把视图设为隐藏，淡出途中又改了目标（重新显示，
    /// 或又一次淡出）时，旧回调不再动视图。
    private var generation: UInt64 = 0

    /// 视图从隐藏开始，第一次 `setShown(true)` 时淡入。
    ///
    /// 隐藏的视图始终保持透明度 0。淡入的起点取上一次真正提交到屏幕的透明度：若到显示那一刻才把 1 改成 0
    /// 再在同一轮里动画到 1，起点仍是 1，按钮会直接出现，只有淡出过一次以后的淡入才正常。
    init(_ view: NSView) {
        self.view = view
        view.isHidden = true
        view.alphaValue = 0
        isShown = false
    }

    func setShown(_ shows: Bool) {
        guard shows != isShown else { return }
        isShown = shows
        generation &+= 1
        let view = view
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            view.alphaValue = shows ? 1 : 0
            view.isHidden = !shows
            return
        }
        // 隐藏时透明度已是 0（见 init）；淡出途中重新显示时从当前透明度淡回。
        if shows { view.isHidden = false }
        let generation = generation
        NSAnimationContext.runAnimationGroup { context in
            context.duration = OverlayFadePolicy.durationSeconds
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            view.animator().alphaValue = shows ? 1 : 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !shows, self.generation == generation else { return }
                view.isHidden = true
            }
        }
    }
}
