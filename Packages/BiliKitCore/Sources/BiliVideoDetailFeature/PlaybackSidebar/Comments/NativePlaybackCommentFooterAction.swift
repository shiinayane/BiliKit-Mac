import AppKit

/// 评论元信息一行里的一个操作（赞带数字、踩、回复、查看对话）：图标与文字按精确宽度排，点击区比看到的大。
///
/// 不用系统按钮：borderless `NSButton` 自带几 pt 不可控的内边距，元信息一行的节奏（图标与数字 3pt、操作之间 14pt）排不准。
/// 视图的 frame 由评论行按 `contentWidth` 加左右各 `hitPadding` 给出，上下撑满行框，所以相邻操作的点击区正好相接、
/// 不留空隙，看到的却只有图标与文字。与系统按钮一致：悬停不变色、不换手形指针，只在按住时加深；做过的表态用强调色；
/// 开着全键盘控制时能用 Tab 聚焦（画系统焦点环）并用空格或回车按下，读屏可直接按下。播放时空格与回车先被播放器快捷键
/// 拿走（侧栏里的系统按钮也一样，见 `PlayerKeyboardShortcutController.focusedResponderOwnsKeys`），这时只能用读屏或鼠标按。
/// 用 AppKit 的理由同评论行，见 ARCHITECTURE「原生 AppKit 集合视图」。
@MainActor
final class NativePlaybackCommentFooterAction: NSView {
    nonisolated override var isFlipped: Bool { true }

    /// 图标与文字之间的间距：赞的图标与数字读起来是一个整体。
    static let iconTitleSpacing: CGFloat = 3

    var onPress: (() -> Void)?
    /// 内容左右各向外延伸的点击区宽度；由评论行按操作间距的一半给出。
    var hitPadding: CGFloat = 0 {
        didSet { needsLayout = true }
    }
    var isEnabled = true {
        didSet { updateColors() }
    }
    /// 做过的表态（已赞、已踩）：强调色。
    var isActive = false {
        didSet { updateColors() }
    }
    /// 平时的颜色；「查看对话」是链接式的操作，用强调色。
    var restingColor: NSColor = .secondaryLabelColor {
        didSet { updateColors() }
    }

    private let imageView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let font: NSFont
    /// 按住且指针仍在点击区内；松开或拖出点击区时复位。
    private var isPressed = false {
        didSet { if isPressed != oldValue { updateColors() } }
    }

    init(font: NSFont) {
        self.font = font
        super.init(frame: .zero)
        imageView.symbolConfiguration = NSImage.SymbolConfiguration(
            pointSize: font.pointSize,
            weight: .regular
        )
        imageView.imageScaling = .scaleNone
        imageView.setAccessibilityElement(false)
        titleLabel.font = font
        titleLabel.setAccessibilityElement(false)
        addSubview(imageView)
        addSubview(titleLabel)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        updateColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// 设定图标（SF Symbol 名，nil 为没有）与文字（空串为没有）。
    func configure(symbolName: String?, title: String) {
        imageView.image = symbolName.flatMap {
            NSImage(systemSymbolName: $0, accessibilityDescription: nil)
        }
        imageView.isHidden = imageView.image == nil
        titleLabel.stringValue = title
        titleLabel.isHidden = title.isEmpty
        needsLayout = true
    }

    /// 看得见的内容宽度：图标、间距与文字，不含点击区的外延。
    var contentWidth: CGFloat {
        let imageWidth = imageView.isHidden ? 0 : ceil(imageView.intrinsicContentSize.width)
        let titleWidth = titleLabel.isHidden ? 0 : ceil(titleLabel.fittingSize.width)
        let spacing = imageWidth > 0 && titleWidth > 0 ? Self.iconTitleSpacing : 0
        return imageWidth + spacing + titleWidth
    }

    override func layout() {
        super.layout()
        var x = hitPadding
        if !imageView.isHidden {
            let size = imageView.intrinsicContentSize
            imageView.frame = NSRect(
                x: x,
                y: floor((bounds.height - size.height) / 2),
                width: ceil(size.width),
                height: size.height
            )
            x = imageView.frame.maxX + (titleLabel.isHidden ? 0 : Self.iconTitleSpacing)
        }
        if !titleLabel.isHidden {
            let size = titleLabel.fittingSize
            titleLabel.frame = NSRect(
                x: x,
                y: floor((bounds.height - size.height) / 2),
                width: ceil(size.width),
                height: size.height
            )
        }
    }

    /// 与系统按钮一样，只在全键盘控制开着时接受焦点：否则鼠标点按会把焦点从评论输入框抢走。
    override var acceptsFirstResponder: Bool { isEnabled && NSApp.isFullKeyboardAccessEnabled }
    override var canBecomeKeyView: Bool { acceptsFirstResponder }

    override var focusRingMaskBounds: NSRect { contentRect }

    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: contentRect, xRadius: 4, yRadius: 4).fill()
    }

    override func keyDown(with event: NSEvent) {
        guard isEnabled,
            event.charactersIgnoringModifiers == " " || event.specialKey == .carriageReturn
                || event.specialKey == .enter
        else { return super.keyDown(with: event) }
        onPress?()
    }

    /// 看得见的内容所占的区域（不含点击区的外延），焦点环画在它周围。
    private var contentRect: NSRect {
        NSRect(
            x: hitPadding,
            y: 0,
            width: max(0, bounds.width - hitPadding * 2),
            height: bounds.height
        )
        .insetBy(dx: -2, dy: 1)
    }

    override func mouseDown(with event: NSEvent) {
        // 自己处理按下，免得事件落到下面的集合视图开始选择；动作在松开时、指针仍在点击区内才执行，与系统按钮一致。
        guard isEnabled else { return }
        isPressed = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard isEnabled else { return }
        isPressed = bounds.contains(convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        let shouldPress = isPressed
        isPressed = false
        guard isEnabled, shouldPress,
            bounds.contains(convert(event.locationInWindow, from: nil))
        else { return }
        onPress?()
    }

    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        onPress?()
        return true
    }

    override func isAccessibilityEnabled() -> Bool { isEnabled }

    private func updateColors() {
        let color: NSColor =
            !isEnabled
            ? .tertiaryLabelColor
            : isPressed
                ? .labelColor
                : isActive ? .controlAccentColor : restingColor
        imageView.contentTintColor = color
        titleLabel.textColor = color
    }
}
