import AppKit

/// 播放详情区里内容原地变化时的淡入；时长与「减少动态效果」的判断只在这里。
///
/// 只用于同一视图原地更新（UP 主名片到达、楼中楼面板换内容）；首次配置、复用与整项重载都不淡入，
/// 由调用方判断。只动不透明度，不动尺寸与位置，行高与视口对齐照常即时完成。
@MainActor
enum NativePlaybackDetailsFade {
    /// 够看出内容换了，又不拖慢连续翻页；改它会同时改变名片与楼中楼的过渡。
    static let duration: CFTimeInterval = 0.25

    /// 交叉淡化：在当前 `CATransaction` 提交前、内容改动之前挂上，同一事务里之后的图层变化都会淡入呈现。
    ///
    /// 只适合尺寸不变的视图：尺寸也变时旧画面会被拉伸。
    static func crossfade(_ view: NSView, key: String) {
        guard isAllowed, let layer = view.layer else { return }
        let transition = CATransition()
        transition.type = .fade
        transition.duration = duration
        transition.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(transition, forKey: key)
    }

    /// 刚加入图层树的视图从透明淡入；视图须已有图层（父视图是 layer-backed）。
    static func fadeIn(_ view: NSView) {
        guard isAllowed, let layer = view.layer else { return }
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = 0
        animation.toValue = 1
        animation.duration = duration
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(animation, forKey: "native-playback-sidebar.fade-in")
    }

    private static var isAllowed: Bool {
        !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }
}
