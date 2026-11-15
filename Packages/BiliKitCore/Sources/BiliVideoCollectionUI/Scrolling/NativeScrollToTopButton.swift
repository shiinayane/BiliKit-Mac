import AppKit

/// 滚动视图右下角的「返回顶部」玻璃按钮：外观、贴着安全区的位置，以及按滚动位置的显隐。
///
/// 播放侧栏的评论区、UP 主空间预览与整页空间页的网格共用这一份。由持有它的滚动视图创建、把 `button` 加为自己的子视图，
/// 并在 `layout()` 时调用 `layout(in:)`；点击后滚到哪里、怎样滚由滚动视图的 owner 决定（`button` 的 target 与 action）。显隐经
/// `NativeFadingVisibility` 淡入淡出。
@MainActor
package final class NativeScrollToTopButton {
    /// 按钮的尺寸与离滚动视图边缘的距离；播放侧栏评论入口收起时的圆钮取同一组值，两枚按钮上下对齐。
    package enum Geometry {
        package static let buttonSize: CGFloat = 44
        package static let edgeInset: CGFloat = 16
    }

    /// 内容滚过这个距离后显示：已经离开顶部一段才需要它，刚开始浏览时不出现按钮挡住内容。
    package static let visibilityOffset: CGFloat = 400

    package let button: NSButton
    /// 按钮从默认位置（贴右下角）上移的距离，给叠在同一角的其他浮动控件让位；播放侧栏用它让出评论入口。
    package var lift: CGFloat = 0
    private let visibility: NativeFadingVisibility

    /// `label` 是调用方已本地化的读屏名称与提示。
    package init(label: String) {
        button = NSButton(
            image: NSImage(systemSymbolName: "arrow.up", accessibilityDescription: label)
                ?? NSImage(),
            target: nil,
            action: nil
        )
        visibility = NativeFadingVisibility(button)
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.controlSize = .large
        if #available(macOS 26.0, *) {
            button.bezelStyle = .glass
        } else {
            button.bezelStyle = .circular
        }
        button.setAccessibilityLabel(label)
        button.toolTip = label
    }

    /// 按逻辑滚动偏移更新显隐；`isBlocked` 时（内容被加载或失败状态盖住）始终隐藏。
    package func updateVisibility(logicalOffset: CGFloat, isBlocked: Bool) {
        visibility.setShown(!isBlocked && logicalOffset >= Self.visibilityOffset)
    }

    /// 贴着滚动视图右下角、避开内容边距与安全区摆放；由滚动视图在 `layout()` 里调用，`lift` 变了也调用。
    package func layout(in scrollView: NSScrollView) {
        let safeTrailing = max(scrollView.contentInsets.right, scrollView.safeAreaInsets.right)
        let safeBottom = max(scrollView.contentInsets.bottom, scrollView.safeAreaInsets.bottom)
        let offset = Geometry.edgeInset + Geometry.buttonSize
        let bottomAlignedY = max(
            Geometry.edgeInset,
            scrollView.bounds.height - safeBottom - offset - lift
        )
        button.frame = NSRect(
            x: max(Geometry.edgeInset, scrollView.bounds.width - safeTrailing - offset),
            y: scrollView.isFlipped ? bottomAlignedY : safeBottom + Geometry.edgeInset + lift,
            width: Geometry.buttonSize,
            height: Geometry.buttonSize
        )
    }
}
