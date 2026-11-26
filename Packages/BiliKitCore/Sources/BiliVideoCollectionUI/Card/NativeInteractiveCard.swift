import AppKit
import BiliUI

/// 网格卡片视图（视频卡片、人物卡片）共用的交互状态与读屏按钮语义，唯一一份；用 AppKit 的理由见 ARCHITECTURE「原生
/// AppKit 集合视图」。
///
/// 拥有悬停、选中、键盘焦点、按下与菜单目标五个状态，自己的 tracking area（`updateTrackingAreas` 时整块替换，随视图
/// 释放），以及集合项交来的激活与悬停回调（`reset` 时清空）。外观写进自己的 layer（`NativeInteractiveSurface`），
/// 内容与排版、读屏标签与帮助由子类负责；子类在 `resetContent` 里清掉自己的内容，在 `accessibilityStateParts` 里给出
/// 读屏值里“已选择”之前的状态。不可激活的卡片（`isActivatable` 为 false）不画悬停与按下，读屏按下不激活；
/// 键盘选中框照常显示，焦点可以停在上面。
@MainActor
class NativeInteractiveCardView: NSView {
    /// 读屏自定义操作与「显示菜单」的转发对象，即拥有这张卡片的集合项（见 `NativeVideoCardMenu.swift`）。
    weak var menuHost: (any NativeVideoMenuTargetItem)?
    private var activation: (() -> Void)?
    private var hoverDidChange: ((Bool) -> Void)?
    private var trackingArea: NSTrackingArea?
    private var isHovered = false
    private var selected = false
    private var showsKeyboardFocus = false
    private var isPressed = false
    /// 菜单打开期间的上下文描边，与键盘选中框同一外观。
    private var isContextMenuTarget = false
    private(set) var isActivatable = true

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = NativeInteractiveSurface.cornerRadius
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 读屏值里排在“已选择”之前的状态（人物卡片的互关与特别关注）；视频卡片没有。
    var accessibilityStateParts: [String] { [] }

    /// 子类在 `reset` 里清掉自己的内容；此时交互状态已经回到初始值，外观与读屏值随后一并刷新。
    func resetContent() {}

    /// 子类每次配置时调用：换上这次的激活与悬停回调。
    func configureInteraction(
        hoverDidChange: @escaping (Bool) -> Void,
        activation: @escaping () -> Void
    ) {
        self.activation = activation
        self.hoverDidChange = hoverDidChange
    }

    func setSelected(_ selected: Bool) {
        self.selected = selected
        updateAccessibilityValue()
        updateInteractionAppearance()
    }

    func setKeyboardFocusVisible(_ isVisible: Bool) {
        guard showsKeyboardFocus != isVisible else { return }
        showsKeyboardFocus = isVisible
        updateInteractionAppearance()
    }

    func setContextMenuTarget(_ isTarget: Bool) {
        guard isContextMenuTarget != isTarget else { return }
        isContextMenuTarget = isTarget
        updateInteractionAppearance()
    }

    func setPressed(_ isPressed: Bool) {
        self.isPressed = isPressed
        updateInteractionAppearance()
    }

    func setHovered(_ isHovered: Bool) {
        guard self.isHovered != isHovered else { return }
        self.isHovered = isHovered
        updateInteractionAppearance()
        hoverDidChange?(isHovered)
    }

    /// 可用性变化时同步外观：不可激活时忽略悬停与按下。
    func setActivatable(_ activatable: Bool) {
        guard isActivatable != activatable else { return }
        isActivatable = activatable
        updateInteractionAppearance(animated: false)
    }

    /// 复用与拆除时调用：清空回调与状态，悬停着的卡片先报告离开，集合项的悬停仲裁不会留着一张已复用的卡片。
    func reset() {
        layer?.removeAllAnimations()
        let wasHovered = isHovered
        activation = nil
        isHovered = false
        selected = false
        showsKeyboardFocus = false
        isPressed = false
        isContextMenuTarget = false
        resetContent()
        updateInteractionAppearance(animated: false)
        setAccessibilityLabel(nil)
        setAccessibilityHelp(nil)
        setAccessibilityValue(nil)
        if wasHovered { hoverDidChange?(false) }
        hoverDidChange = nil
    }

    func refreshEnvironmentAppearance() {
        updateInteractionAppearance(animated: false)
        needsLayout = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        // 悬停与键盘选中的描边、底色是按外观解析后写进 layer 的，换主题时要重新解析。
        updateInteractionAppearance(animated: false)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        // tracking area 按整块 bounds 发事件，不管卡片有没有被别的视图盖住；进入与移动时都按点击判定
        // （`isHitByPointer`）决定悬停，指针从被盖住的部分移到露出的部分时才能画上。
        let updated = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow],
            owner: self
        )
        addTrackingArea(updated)
        trackingArea = updated
    }

    override func mouseEntered(with event: NSEvent) { updateHover(for: event) }
    override func mouseMoved(with event: NSEvent) { updateHover(for: event) }
    override func mouseExited(with event: NSEvent) { setHovered(false) }

    private func updateHover(for event: NSEvent) {
        setHovered(isHitByPointer(atWindowPoint: event.locationInWindow))
    }

    override func accessibilityPerformPress() -> Bool {
        guard isActivatable, let activation else { return false }
        activation()
        return true
    }

    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
        menuHost?.accessibilityCardActions
    }

    /// 不可用卡片仍有可执行的菜单项时（稍后再看里失效视频的「从稍后再看移除」）保持读屏可用，否则读屏可能不列出操作、
    /// 也不提供「显示菜单」；按下仍由 `accessibilityPerformPress` 拒绝，不会激活。
    override func isAccessibilityEnabled() -> Bool {
        isActivatable || accessibilityCustomActions() != nil
    }

    override func accessibilityPerformShowMenu() -> Bool {
        menuHost?.presentCardMenu() ?? false
    }

    /// 子类的状态段（`accessibilityStateParts`）变化后调用。
    func updateAccessibilityValue() {
        setAccessibilityValue(
            VideoCardAccessibilityText.value(
                states: accessibilityStateParts,
                isSelected: selected,
                isActivatable: isActivatable
            )
        )
    }

    private func updateInteractionAppearance(animated: Bool = true) {
        guard let layer else { return }
        // 不可用卡片不画悬停与按下：它们暗示点了会有反应；键盘选中框仍画，表示焦点停在这里。
        NativeInteractiveSurface.apply(
            NativeInteractiveSurface.State(
                isHovered: isHovered && isActivatable,
                isPressed: isPressed && isActivatable,
                showsFocusRing: (selected && showsKeyboardFocus) || isContextMenuTarget
            ),
            to: layer,
            appearance: effectiveAppearance,
            animated: animated
        )
    }
}

/// 网格卡片的集合项基类：把集合视图的选中、按下高亮与悬停、焦点、菜单目标转给卡片视图，唯一一份。
///
/// 只转发，不拥有状态；卡片视图由子类持有并经 `interactiveCard` 给出，`loadView` 把它装成自己的视图并登记为
/// 读屏菜单的转发对象。
@MainActor
package class NativeInteractiveCardItem: NativeLayoutSizedCollectionItem {
    /// 子类持有的卡片视图；子类必须覆盖。
    var interactiveCard: NativeInteractiveCardView {
        preconditionFailure("NativeInteractiveCardItem 的子类必须给出卡片视图")
    }

    package override var isSelected: Bool {
        didSet { interactiveCard.setSelected(isSelected) }
    }

    package override var highlightState: NSCollectionViewItem.HighlightState {
        didSet { interactiveCard.setPressed(highlightState == .forSelection) }
    }

    package override func loadView() {
        view = interactiveCard
        interactiveCard.menuHost = self as? any NativeVideoMenuTargetItem
    }

    package func setHovered(_ isHovered: Bool) { interactiveCard.setHovered(isHovered) }
    package func clearHover() { interactiveCard.setHovered(false) }
    package func setKeyboardFocusVisible(_ isVisible: Bool) {
        interactiveCard.setKeyboardFocusVisible(isVisible)
    }
    package func setContextMenuTarget(_ isTarget: Bool) {
        interactiveCard.setContextMenuTarget(isTarget)
    }
    package func refreshEnvironmentAppearance() { interactiveCard.refreshEnvironmentAppearance() }
}
