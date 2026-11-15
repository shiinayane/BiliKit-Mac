import AppKit
import BiliVideoCollectionUI

/// 右下角带「返回顶部」玻璃按钮（`NativeScrollToTopButton`）的滚动视图；播放侧栏评论区与 UP 主空间预览共用。
///
/// 按钮的外观、位置与显隐规则在 `NativeScrollToTopButton`；这里负责在布局时摆放它，并报告内容边距变化。点击后滚到哪里
/// 由 owner 决定。
@MainActor
final class NativeScrollToTopScrollView: NSScrollView {
    private let scrollToTop: NativeScrollToTopButton
    var topButton: NSButton { scrollToTop.button }
    /// 按钮从默认位置上移的距离，给叠在同一角的其他浮动控件让位；播放侧栏用它让出评论入口。
    ///
    /// 会在动画期间逐帧改，所以只重排这一个按钮，不让整个滚动视图重新布局。
    var topButtonLift: CGFloat {
        get { scrollToTop.lift }
        set {
            guard scrollToTop.lift != newValue else { return }
            scrollToTop.lift = newValue
            scrollToTop.layout(in: self)
        }
    }
    var onContentInsetsChange: ((NSEdgeInsets, NSEdgeInsets) -> Void)?
    private var viewportTracker = NativeScrollViewportTracker()

    init(topButtonLabel: String) {
        scrollToTop = NativeScrollToTopButton(label: topButtonLabel)
        super.init(frame: .zero)
        addSubview(scrollToTop.button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    /// 按当前滚动位置更新按钮显隐；`isBlocked` 时（内容被加载或失败状态盖住）始终隐藏。
    func updateTopButtonVisibility(isBlocked: Bool = false) {
        scrollToTop.updateVisibility(
            logicalOffset: NativeVideoScrollCoordinateSpace.logicalOffset(
                physicalOffset: contentView.bounds.minY,
                leadingInset: contentInsets.top
            ),
            isBlocked: isBlocked
        )
    }

    override func layout() {
        super.layout()
        scrollToTop.layout(in: self)
        guard let previousInsets = viewportTracker.update(for: self).previousInsets else { return }
        onContentInsetsChange?(previousInsets, contentInsets)
    }
}
