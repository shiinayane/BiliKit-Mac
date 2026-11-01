import AppKit
import QuartzCore

/// 可点的视频条目（网格的视频卡片、竖向视频行）的悬停、按下与焦点外观，唯一一份。
///
/// 只把外观写进调用方视图自己的 layer：底色、描边、按下时的缩放与变淡。不持有状态，悬停、按下与焦点由各视图
/// 自己维护，状态或外观变化时调用 `apply`；条目是否可用、正在播放等额外外观也由调用方处理。
@MainActor
package enum NativeInteractiveSurface {
    /// 一次要画的交互状态。
    package struct State: Equatable {
        package var isHovered: Bool
        package var isPressed: Bool
        /// 键盘选中或菜单打开时的强调色描边；同时悬停时描边仍取强调色。
        package var showsFocusRing: Bool

        package init(isHovered: Bool, isPressed: Bool, showsFocusRing: Bool) {
            self.isHovered = isHovered
            self.isPressed = isPressed
            self.showsFocusRing = showsFocusRing
        }

        package static let idle = State(isHovered: false, isPressed: false, showsFocusRing: false)
    }

    /// 悬停底色在 `labelColor` 上的不透明度，配合描边在透明的侧栏与网格背景上都看得出；调低会让悬停不易察觉。
    static let hoveredFillOpacity: CGFloat = 0.08
    /// 按下底色的不透明度，比悬停深，表示点击已被接住。
    static let pressedFillOpacity: CGFloat = 0.14
    /// 悬停或焦点描边的宽度；开启“增强对比度”时加粗。
    static let strokeWidth: CGFloat = 1
    static let increasedContrastStrokeWidth: CGFloat = 2
    /// 按下时的缩放与不透明度；“减弱动态效果”时不缩放。
    static let pressedScale: CGFloat = 0.985
    static let pressedOpacity: Float = 0.82
    /// 状态切换的过渡时长；“减弱动态效果”或 `animated` 为 false 时直接到位。
    static let transitionDuration: CFTimeInterval = 0.12

    /// 按 `appearance` 解析颜色后把 `state` 的外观写进 `layer`。
    ///
    /// 动态颜色必须按视图自己的外观解析，调用方在外观变化时要以 `animated: false` 重新调用。
    package static func apply(
        _ state: State,
        to layer: CALayer,
        appearance: NSAppearance,
        animated: Bool
    ) {
        let fillOpacity =
            state.isPressed ? pressedFillOpacity : (state.isHovered ? hoveredFillOpacity : 0)
        let showsStroke = state.isHovered || state.showsFocusRing
        let targetBackground = NSColor.labelColor
            .withAlphaComponent(fillOpacity).cgColor(for: appearance)
        let targetBorder =
            showsStroke
            ? (state.showsFocusRing ? NSColor.controlAccentColor : .secondaryLabelColor)
                .cgColor(for: appearance)
            : NSColor.clear.cgColor
        let targetBorderWidth: CGFloat =
            showsStroke
            ? (NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
                ? increasedContrastStrokeWidth : strokeWidth)
            : 0
        let reducesMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let targetTransform =
            state.isPressed && !reducesMotion
            ? CATransform3DMakeScale(pressedScale, pressedScale, 1)
            : CATransform3DIdentity
        let targetOpacity: Float = state.isPressed ? pressedOpacity : 1
        let duration = animated && !reducesMotion ? transitionDuration : 0
        let presentation = layer.presentation()

        // 先关掉隐式动画把 model 值一次写到目标，再从之前取得的 presentation 值显式补动画：
        // 悬停或按下中途反向时从当前看到的样子接着变，不会跳回起点。
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.backgroundColor = targetBackground
        layer.borderColor = targetBorder
        layer.borderWidth = targetBorderWidth
        layer.transform = targetTransform
        layer.opacity = targetOpacity
        CATransaction.commit()

        let transitions: [(keyPath: String, from: Any?, to: Any)] = [
            ("backgroundColor", presentation?.backgroundColor, targetBackground),
            ("borderColor", presentation?.borderColor, targetBorder),
            ("borderWidth", presentation?.borderWidth, targetBorderWidth),
            ("transform", presentation?.transform, targetTransform),
            ("opacity", presentation?.opacity, targetOpacity)
        ]
        for transition in transitions {
            let key = animationKey(transition.keyPath)
            guard duration > 0 else {
                layer.removeAnimation(forKey: key)
                continue
            }
            let animation = CABasicAnimation(keyPath: transition.keyPath)
            animation.fromValue = transition.from
            animation.toValue = transition.to
            animation.duration = duration
            animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
            layer.add(animation, forKey: key)
        }
    }

    private static func animationKey(_ keyPath: String) -> String {
        "native-interactive-surface.\(keyPath)"
    }
}
