import AppKit
import BiliVideoCollectionUI

/// 相关推荐横排的滚动视图：不带滚动条的横向滚动、指针悬停或键盘焦点在横排内时淡入的左右翻页按钮
/// （`NativeFadingVisibility`）。
///
/// 视口布局与焦点变化各自合并到下一轮主队列再通知（`DispatchQueue.main.async`），不在当前布局过程中改动
/// 集合视图；两个“已安排”标志保证每轮最多一次，`reset()` 清掉视口那一个并断开回调。按钮隐藏前若持有焦点，先把焦点交给集合视图。
/// 用 AppKit 的理由见 ARCHITECTURE「原生 AppKit 集合视图」。
@MainActor
final class NativeVideoShelfScrollView: NSScrollView {
    var onViewportLayout: (() -> Void)?
    var onPageBackward: (() -> Void)?
    var onPageForward: (() -> Void)?
    var onWindowChange: ((NSWindow?) -> Void)?

    private let backwardButton = NativeVideoShelfPageButton()
    private let forwardButton = NativeVideoShelfPageButton()
    private let backwardVisibility: NativeFadingVisibility
    private let forwardVisibility: NativeFadingVisibility
    private var trackingArea: NSTrackingArea?
    private var isPointerInside = false
    private var canGoBackward = false
    private var canGoForward = false
    private var viewportTracker = NativeScrollViewportTracker()
    private var viewportUpdateScheduled = false
    private var focusUpdateScheduled = false
    private var isInteractionEnabled = true

    override init(frame frameRect: NSRect) {
        backwardVisibility = NativeFadingVisibility(backwardButton)
        forwardVisibility = NativeFadingVisibility(forwardButton)
        super.init(frame: frameRect)
        for (button, symbol, label) in [
            (backwardButton, "chevron.left", VideoDetailFeatureStrings.localized("上一排相关推荐")),
            (forwardButton, "chevron.right", VideoDetailFeatureStrings.localized("下一排相关推荐"))
        ] {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
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
            button.onFocusChange = { [weak self] in
                self?.updateFocusWithinSoon()
            }
            addSubview(button)
        }
        backwardButton.target = self
        backwardButton.action = #selector(pageBackward)
        forwardButton.target = self
        forwardButton.action = #selector(pageForward)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 横排始终不要横向滚动条，滚轮与触控板照常横向滚动，翻页交给左右按钮。
    ///
    /// 只在 `install` 里设 false 挡不住：内容比视口宽时，`NSCollectionView` 每次布局、每次滚动引起 bounds 变化都会把
    /// 外层的 `hasHorizontalScroller` 改回 true（实测调用栈来自它的私有 `_resizeToFitContentAndClipView`）。不拦的话，
    /// overlay 模式下滚动条从改回之后的那次滚动起出现，传统滚动条模式下一直显示并让出卡片行的高度。
    override var hasHorizontalScroller: Bool {
        get { super.hasHorizontalScroller }
        set { super.hasHorizontalScroller = false }
    }

    func install(collectionView: NSCollectionView) {
        documentView = collectionView
        // 横向滚动条由 `hasHorizontalScroller` 的覆写挡住；纵向本来就不需要。
        hasVerticalScroller = false
        verticalScroller = nil
        drawsBackground = false
        automaticallyAdjustsContentInsets = true
        usesPredominantAxisScrolling = true
        // 没有可见的横向滚动条时，`.automatic` 只在卡片比视口宽时回弹；显式允许，卡片不满一排时也照常回弹。
        horizontalScrollElasticity = .allowed
        verticalScrollElasticity = .none
        contentView.postsBoundsChangedNotifications = true
    }

    override func layout() {
        super.layout()
        let safeLeading = max(contentInsets.left, safeAreaInsets.left)
        let safeTrailing = max(contentInsets.right, safeAreaInsets.right)
        let buttonSize = NSSize(width: 44, height: 44)
        let y = max(0, (bounds.height - buttonSize.height) / 2)
        backwardButton.frame = NSRect(
            x: safeLeading + 12,
            y: y,
            width: buttonSize.width,
            height: buttonSize.height
        )
        forwardButton.frame = NSRect(
            x: max(
                safeLeading + 12,
                bounds.width - safeTrailing - buttonSize.width - 12
            ),
            y: y,
            width: buttonSize.width,
            height: buttonSize.height
        )
        updatePointerInsideFromWindow()

        let change = viewportTracker.update(for: self)
        guard change.sizeChanged || change.previousInsets != nil else { return }
        scheduleViewportUpdate()
    }

    private func scheduleViewportUpdate() {
        guard !viewportUpdateScheduled else { return }
        viewportUpdateScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.viewportUpdateScheduled = false
            self.onViewportLayout?()
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindowChange?(window)
        updateFocusWithinSoon()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let updated = NSTrackingArea(
            rect: .zero,
            options: [
                .mouseEnteredAndExited,
                .activeInKeyWindow,
                .inVisibleRect
            ],
            owner: self
        )
        addTrackingArea(updated)
        trackingArea = updated
    }

    override func mouseEntered(with event: NSEvent) {
        updatePointerInside(true)
    }

    override func mouseExited(with event: NSEvent) {
        updatePointerInside(false)
    }

    func updatePageAvailability(canGoBackward: Bool, canGoForward: Bool) {
        guard
            self.canGoBackward != canGoBackward
                || self.canGoForward != canGoForward
        else { return }
        self.canGoBackward = canGoBackward
        self.canGoForward = canGoForward
        updateButtons()
    }

    func setInteractionEnabled(_ isEnabled: Bool) {
        guard isInteractionEnabled != isEnabled else { return }
        isInteractionEnabled = isEnabled
        updateButtons()
    }

    func updateFocusWithinSoon() {
        guard !focusUpdateScheduled else { return }
        focusUpdateScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.focusUpdateScheduled = false
            self.updateButtons()
        }
    }

    func scrollHorizontally(to x: CGFloat, animated: Bool) {
        let target = NSPoint(x: x, y: contentView.bounds.origin.y)
        guard animated else {
            contentView.scroll(to: target)
            reflectScrolledClipView(contentView)
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.24
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            contentView.animator().setBoundsOrigin(target)
        }
    }

    func reset() {
        clearTransientControls()
        viewportUpdateScheduled = false
        onViewportLayout = nil
        onPageBackward = nil
        onPageForward = nil
        onWindowChange = nil
        documentView = nil
    }

    func clearFirstResponderIfNeeded() {
        guard
            let window,
            let responder = window.firstResponder as? NSView,
            responder === self || responder.isDescendant(of: self)
        else { return }
        window.makeFirstResponder(nil)
    }

    func clearTransientControls() {
        updatePointerInside(false)
    }

    @objc private func pageBackward() {
        guard isInteractionEnabled else { return }
        onPageBackward?()
    }

    @objc private func pageForward() {
        guard isInteractionEnabled else { return }
        onPageForward?()
    }

    func updatePointerInside(_ isInside: Bool) {
        guard isPointerInside != isInside else { return }
        isPointerInside = isInside
        updateButtons()
    }

    private func updatePointerInsideFromWindow() {
        guard let window else {
            updatePointerInside(false)
            return
        }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        updatePointerInside(bounds.contains(point))
    }

    private var keyboardShowsControls: Bool {
        if window?.firstResponder === backwardButton
            || window?.firstResponder === forwardButton
        {
            return true
        }
        return (documentView as? NativeVideoShelfCollectionView)?.showsKeyboardSelection
            == true
    }

    private func updateButtons() {
        let hidesControls = !isInteractionEnabled || (!isPointerInside && !keyboardShowsControls)
        moveFocusToCollectionIfNeeded(
            beforeHiding: backwardButton,
            hides: hidesControls || !canGoBackward
        )
        moveFocusToCollectionIfNeeded(
            beforeHiding: forwardButton,
            hides: hidesControls || !canGoForward
        )
        backwardButton.isEnabled = isInteractionEnabled && canGoBackward
        forwardButton.isEnabled = isInteractionEnabled && canGoForward
        backwardVisibility.setShown(!hidesControls)
        forwardVisibility.setShown(!hidesControls)
    }

    private func moveFocusToCollectionIfNeeded(beforeHiding button: NSButton, hides: Bool) {
        guard hides, window?.firstResponder === button else { return }
        window?.makeFirstResponder(documentView)
    }
}

/// 翻页按钮：焦点得失时通知滚动视图，按钮在焦点离开横排时随之隐藏。
@MainActor
final class NativeVideoShelfPageButton: NSButton {
    var onFocusChange: (() -> Void)?

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onFocusChange?() }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted { onFocusChange?() }
        return accepted
    }
}

/// 横排的集合视图：键盘获得焦点时选中第一张可见卡片，交互关闭（被遮挡）时不接受焦点。
@MainActor
final class NativeVideoShelfCollectionView: NativeVideoCardCollectionView {
    var itemIDAtIndex: ((Int) -> String?)?
    var onFocusChange: (() -> Void)?
    var isInteractionEnabled = true

    override func becomeFirstResponder() -> Bool {
        guard isInteractionEnabled else { return false }
        let accepted = super.becomeFirstResponder()
        if accepted {
            if selectionIndexPaths.isEmpty, let first = firstVisibleIndexPath {
                selectionIndexPaths = [first]
            }
            setShowsKeyboardSelection(true)
            onFocusChange?()
        }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted {
            hideKeyboardSelectionAppearance()
        }
        return accepted
    }

    override func mouseDown(with event: NSEvent) {
        guard isInteractionEnabled, !routesControlClickToContextMenu(event) else { return }
        let point = convert(event.locationInWindow, from: nil)
        let clickedIndexPath = indexPathForItem(at: point)
        super.mouseDown(with: event)
        hideKeyboardSelectionAppearance()
        guard
            let clickedIndexPath,
            let id = itemIDAtIndex?(clickedIndexPath.item)
        else { return }
        onActivateSelection?(id)
    }

    override func keyDown(with event: NSEvent) {
        guard isInteractionEnabled else {
            super.keyDown(with: event)
            return
        }
        if NativeVideoCollectionKeys.isActivation(event) {
            activateSelectedItem()
            return
        }
        if let delta = NativeVideoCollectionKeys.selectionDelta(for: event),
            moveSelection(by: delta)
        {
            return
        }
        super.keyDown(with: event)
    }

    func clearSelectionForContentReplacement() {
        hideKeyboardSelectionAppearance()
        selectionIndexPaths = []
        if window?.firstResponder === self {
            window?.makeFirstResponder(nil)
        }
    }

    func hideKeyboardSelectionAppearance() {
        guard showsKeyboardSelection else { return }
        setShowsKeyboardSelection(false)
        onFocusChange?()
    }

    func activateSelectedItem() {
        guard
            let id = Self.selectedItemID(
                selectionIndexPaths: selectionIndexPaths,
                itemIDAtIndex: itemIDAtIndex
            )
        else { return }
        onActivateSelection?(id)
    }

    static func selectedItemID(
        selectionIndexPaths: Set<IndexPath>,
        itemIDAtIndex: ((Int) -> String?)?
    ) -> String? {
        guard let index = selectionIndexPaths.first?.item else { return nil }
        return itemIDAtIndex?(index)
    }

    private var firstVisibleIndexPath: IndexPath? {
        indexPathsForVisibleItems().min { lhs, rhs in lhs.item < rhs.item }
    }

    private func moveSelection(by delta: Int) -> Bool {
        let itemCount = numberOfItems(inSection: 0)
        guard itemCount > 0 else { return false }
        let current: Int
        if let selected = selectionIndexPaths.first?.item {
            current = selected
        } else if let firstVisible = firstVisibleIndexPath?.item {
            current = delta < 0 ? min(itemCount - 1, firstVisible + 1) : firstVisible - 1
        } else {
            current = delta < 0 ? 1 : -1
        }
        selectWithKeyboard(itemAt: current + delta, scrollPosition: .nearestHorizontalEdge)
        return true
    }
}
