import AppKit
import BiliVideoCollectionUI

/// 右下角带“返回顶部”玻璃按钮的滚动视图；播放侧栏评论区与 UP 主空间共用。
///
/// 滚过 `topButtonVisibilityOffset` 后显示按钮；点击后滚到哪里由 owner 决定。这里负责外观、
/// 贴着安全区的位置、显隐规则与内容边距变化通知。
@MainActor
final class NativeScrollToTopScrollView: NSScrollView {
    /// 「返回顶部」按钮的尺寸与离侧栏边缘的距离；评论入口收起时的圆钮取同一组值，两枚按钮上下对齐。
    enum Geometry {
        static let buttonSize: CGFloat = 44
        static let edgeInset: CGFloat = 16
    }

    /// 内容滚过这个距离后显示“返回顶部”：已经离开顶部一段才需要它，刚开始浏览时不出现按钮挡住内容。
    static let topButtonVisibilityOffset: CGFloat = 400

    let topButton: NSButton
    /// 按钮从默认位置（贴右下角）上移的距离，给叠在同一角的其他浮动控件让位；播放侧栏用它让出评论入口。
    ///
    /// 会在动画期间逐帧改，所以只重排这一个按钮，不让整个滚动视图重新布局。
    var topButtonLift: CGFloat = 0 {
        didSet { if topButtonLift != oldValue { layoutTopButton() } }
    }
    var onContentInsetsChange: ((NSEdgeInsets, NSEdgeInsets) -> Void)?
    private var viewportTracker = NativeScrollViewportTracker()

    init(topButtonLabel: String) {
        topButton = NSButton(
            image: NSImage(
                systemSymbolName: "arrow.up",
                accessibilityDescription: topButtonLabel
            ) ?? NSImage(),
            target: nil,
            action: nil
        )
        super.init(frame: .zero)
        topButton.imagePosition = .imageOnly
        topButton.imageScaling = .scaleProportionallyDown
        topButton.controlSize = .large
        if #available(macOS 26.0, *) {
            topButton.bezelStyle = .glass
        } else {
            topButton.bezelStyle = .circular
        }
        topButton.setAccessibilityLabel(topButtonLabel)
        topButton.toolTip = topButtonLabel
        topButton.isHidden = true
        addSubview(topButton)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    /// 按当前滚动位置更新按钮显隐；`isBlocked` 时（内容被加载或失败状态盖住）始终隐藏。
    func updateTopButtonVisibility(isBlocked: Bool = false) {
        let offset = NativeVideoScrollCoordinateSpace.logicalOffset(
            physicalOffset: contentView.bounds.minY,
            leadingInset: contentInsets.top
        )
        topButton.isHidden = isBlocked || offset < Self.topButtonVisibilityOffset
    }

    override func layout() {
        super.layout()
        layoutTopButton()
        guard let previousInsets = viewportTracker.update(for: self).previousInsets else { return }
        onContentInsetsChange?(previousInsets, contentInsets)
    }

    private func layoutTopButton() {
        let safeTrailing = max(contentInsets.right, safeAreaInsets.right)
        let safeBottom = max(contentInsets.bottom, safeAreaInsets.bottom)
        let offset = Geometry.edgeInset + Geometry.buttonSize
        let bottomAlignedY = max(
            Geometry.edgeInset,
            bounds.height - safeBottom - offset - topButtonLift
        )
        topButton.frame = NSRect(
            x: max(Geometry.edgeInset, bounds.width - safeTrailing - offset),
            y: isFlipped ? bottomAlignedY : safeBottom + Geometry.edgeInset + topButtonLift,
            width: Geometry.buttonSize,
            height: Geometry.buttonSize
        )
    }
}
