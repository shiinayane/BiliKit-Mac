import AppKit

/// 网格的滚动视图：每次 `tile()` 与 `layout()` 之后都先报告 contentInsets 的变化，再回调 `onViewportLayout`，由
/// Coordinator 重排与保持位置。
///
/// 视口尺寸是否变化只由 Coordinator 按它最近一次排版的尺寸判断，这里不再比较尺寸：两份各带容差、基准不同的
/// 比较会分叉，Coordinator 认定尺寸已变、这里却不再回调，网格就一直停在等待排版的状态。`tile()` 也要回调：
/// 传统滚动条随 document 高度或滚动出现、消失时，AppKit 只重新 tile、不一定再 layout，视口宽度就在 layout 之外变了。
/// 离开窗口之前回调 `onWillLeaveWindow`：集合视图离开窗口后会回收全部卡片，保活的网格要在这之前收走卡片正显示的图。
/// 只由 `NativeVideoGridView` 创建；用 AppKit 的理由见 ARCHITECTURE「原生 AppKit 集合视图」。
@MainActor
final class NativeVideoGridScrollView: NSScrollView {
    var onWillLeaveWindow: (() -> Void)?
    var onViewportLayout: (() -> Void)?
    var onContentInsetsChange: ((NSEdgeInsets, NSEdgeInsets) -> Void)?
    private var viewportTracker = NativeScrollViewportTracker()

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil, window != nil { onWillLeaveWindow?() }
        super.viewWillMove(toWindow: newWindow)
    }

    override func tile() {
        super.tile()
        reportViewport()
    }

    override func layout() {
        super.layout()
        reportViewport()
    }

    /// insets 先于视口报告：Coordinator 按旧 insets 换算出逻辑偏移后，重排才按新 insets 恢复位置。
    private func reportViewport() {
        if let previousInsets = viewportTracker.update(for: self).previousInsets {
            onContentInsetsChange?(previousInsets, contentInsets)
        }
        onViewportLayout?()
    }
}
