import AppKit
import BiliUI
import SwiftUI

enum NativeVideoShelfGeometry {
    static let cardWidth: CGFloat = 224
    static let cardHeight = VideoCardGeometry.height(forWidth: cardWidth)
    static let spacing: CGFloat = 16
    static let contentInset: CGFloat = 40
    static let bottomInset: CGFloat = 22
    static let viewportHeight: CGFloat = 232

    static var stride: CGFloat { cardWidth + spacing }

    static func pageCapacity(viewportWidth: CGFloat) -> Int {
        let availableWidth = max(cardWidth, viewportWidth - contentInset * 2)
        return max(1, Int(floor((availableWidth + spacing) / stride)))
    }

    static func documentWidth(itemCount: Int) -> CGFloat {
        guard itemCount > 0 else { return 0 }
        return contentInset * 2
            + CGFloat(itemCount) * cardWidth
            + CGFloat(itemCount - 1) * spacing
    }

    static func offset(for index: Int) -> CGFloat {
        CGFloat(max(0, index)) * stride
    }

    static func nearestIndex(offset: CGFloat, itemCount: Int) -> Int {
        guard itemCount > 0 else { return 0 }
        return min(itemCount - 1, max(0, Int(round(max(0, offset) / stride))))
    }
}

struct NativeVideoShelfUpdatePlan: Equatable {
    let identityChanged: Bool
    let changedExistingIDs: Set<String>

    init(
        previousContentIdentity: String,
        updatedContentIdentity: String,
        previousIDs: [String],
        previousContents: [String: NativeVideoCardPresentation],
        updatedIDs: [String],
        updatedContents: [String: NativeVideoCardPresentation]
    ) {
        identityChanged =
            previousContentIdentity != updatedContentIdentity
            || previousIDs != updatedIDs
        changedExistingIDs = Set(previousIDs).intersection(updatedIDs).filter {
            previousContents[$0] != updatedContents[$0]
        }
    }
}

struct NativeVideoShelfView: NSViewRepresentable {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled

    let contentIdentity: String
    let items: [NativeVideoCardPresentation]
    let imagePipeline: NativeVideoImagePipeline
    let onSelect: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            contentIdentity: contentIdentity,
            items: items,
            imagePipeline: imagePipeline,
            reduceMotion: reduceMotion,
            isInteractionEnabled: isEnabled,
            onSelect: onSelect
        )
    }

    func makeNSView(context: Context) -> NativeVideoShelfScrollView {
        context.coordinator.makeScrollView()
    }

    func updateNSView(
        _ view: NativeVideoShelfScrollView,
        context: Context
    ) {
        context.coordinator.update(
            contentIdentity: contentIdentity,
            items: items,
            reduceMotion: reduceMotion,
            isInteractionEnabled: isEnabled,
            onSelect: onSelect
        )
    }

    static func dismantleNSView(
        _ view: NativeVideoShelfScrollView,
        coordinator: Coordinator
    ) {
        coordinator.reset()
    }

    @MainActor
    final class Coordinator: NSObject, NSCollectionViewDelegateFlowLayout {
        private let scrollView = NativeVideoShelfScrollView()
        private let collectionView = NativeVideoShelfCollectionView()
        private let layout = NSCollectionViewFlowLayout()
        private let imagePipeline: NativeVideoImagePipeline
        private let configuredItems = NSHashTable<NativeVideoCollectionItem>.weakObjects()
        private var dataSource: NSCollectionViewDiffableDataSource<Int, String>?
        private var contentIdentity: String
        private var contents: NativeVideoCardContents
        private var reduceMotion: Bool
        private var isInteractionEnabled: Bool
        private var onSelect: (String) -> Void
        private var observers = NativeVideoNotificationObservers()
        private var windowObservers = NativeVideoNotificationObservers()
        private let hover = NativeVideoHoverTracker()
        private var operationGeneration: UInt64 = 0
        private var isResizingDocument = false
        private var isReset = false

        init(
            contentIdentity: String,
            items: [NativeVideoCardPresentation],
            imagePipeline: NativeVideoImagePipeline,
            reduceMotion: Bool,
            isInteractionEnabled: Bool,
            onSelect: @escaping (String) -> Void
        ) {
            self.contentIdentity = contentIdentity
            contents = NativeVideoCardContents(items)
            self.imagePipeline = imagePipeline
            self.reduceMotion = reduceMotion
            self.isInteractionEnabled = isInteractionEnabled
            self.onSelect = onSelect
        }

        func makeScrollView() -> NativeVideoShelfScrollView {
            layout.scrollDirection = .horizontal
            layout.itemSize = NSSize(
                width: NativeVideoShelfGeometry.cardWidth,
                height: NativeVideoShelfGeometry.cardHeight
            )
            layout.minimumInteritemSpacing = NativeVideoShelfGeometry.spacing
            layout.minimumLineSpacing = NativeVideoShelfGeometry.spacing
            layout.sectionInset = NSEdgeInsets(
                top: 0,
                left: NativeVideoShelfGeometry.contentInset,
                bottom: NativeVideoShelfGeometry.bottomInset,
                right: NativeVideoShelfGeometry.contentInset
            )

            collectionView.collectionViewLayout = layout
            collectionView.delegate = self
            collectionView.isSelectable = true
            collectionView.allowsMultipleSelection = false
            collectionView.backgroundColors = [.clear]
            collectionView.onActivateSelection = { [weak self] id in
                self?.selectAndActivate(id)
            }
            collectionView.itemIDAtIndex = { [weak self] index in
                guard let ids = self?.contents.orderedIDs, ids.indices.contains(index) else {
                    return nil
                }
                return ids[index]
            }
            collectionView.onFocusChange = { [weak scrollView] in
                scrollView?.updateFocusWithinSoon()
            }
            collectionView.register(
                NativeVideoCollectionItem.self,
                forItemWithIdentifier: .nativeVideoCard
            )
            collectionView.setAccessibilityLabel(AppStrings.localized("横向相关推荐"))

            dataSource = NativeVideoCardDataSource.make(
                collectionView: collectionView,
                presentation: { [weak self] id in self?.contents[id] },
                configure: { [weak self] item, presentation in
                    self?.configure(item, with: presentation)
                },
                showsKeyboardSelection: { [weak collectionView] in
                    collectionView?.showsKeyboardSelection == true
                }
            )

            scrollView.install(collectionView: collectionView)
            applyInteractionState(isInteractionEnabled, reconfiguresCards: false)
            scrollView.onViewportLayout = { [weak self] in
                self?.viewportDidLayout()
            }
            scrollView.onPageBackward = { [weak self] in self?.page(by: -1) }
            scrollView.onPageForward = { [weak self] in self?.page(by: 1) }
            scrollView.onWindowChange = { [weak self] window in
                self?.observeWindow(window)
            }

            observers.observeScrolling(of: scrollView) { [weak self] in self?.didScroll() }
            observers.observeAccessibilityDisplayOptions { [weak collectionView] in
                collectionView?.refreshVisibleCardAppearance()
            }

            operationGeneration &+= 1
            let initialGeneration = operationGeneration
            applySnapshot(animatingDifferences: false) { [weak self] in
                guard
                    let self,
                    !self.isReset,
                    self.operationGeneration == initialGeneration
                else { return }
                self.resizeDocument(invalidateLayout: true)
                self.scrollToLeading()
                self.updateHoverForCurrentPointerLocation()
            }
            return scrollView
        }

        func update(
            contentIdentity: String,
            items: [NativeVideoCardPresentation],
            reduceMotion: Bool,
            isInteractionEnabled: Bool,
            onSelect: @escaping (String) -> Void
        ) {
            guard !isReset else { return }
            self.reduceMotion = reduceMotion
            self.onSelect = onSelect
            applyInteractionState(isInteractionEnabled, reconfiguresCards: true)
            let updatedContents = NativeVideoCardContents(items)
            let plan = NativeVideoShelfUpdatePlan(
                previousContentIdentity: self.contentIdentity,
                updatedContentIdentity: contentIdentity,
                previousIDs: contents.orderedIDs,
                previousContents: contents.byID,
                updatedIDs: updatedContents.orderedIDs,
                updatedContents: updatedContents.byID
            )
            let resetsToLeading = self.contentIdentity != contentIdentity
            self.contentIdentity = contentIdentity
            contents = updatedContents

            if plan.identityChanged {
                operationGeneration &+= 1
                let generation = operationGeneration
                if resetsToLeading {
                    invalidateInteractionAndImageRequestsForContentReplacement()
                }
                applySnapshot(animatingDifferences: !resetsToLeading) { [weak self] in
                    guard
                        let self,
                        !self.isReset,
                        self.operationGeneration == generation
                    else { return }
                    self.resizeDocument(invalidateLayout: true)
                    if resetsToLeading { self.scrollToLeading() }
                    self.reconfigureVisibleCards()
                    self.updateHoverForCurrentPointerLocation()
                }
            } else if !plan.changedExistingIDs.isEmpty {
                reconfigureVisibleCards(ids: plan.changedExistingIDs)
            }
        }

        func reset() {
            guard !isReset else { return }
            scrollView.clearFirstResponderIfNeeded()
            isReset = true
            operationGeneration &+= 1
            hover.setHoveredItem(nil)
            for item in configuredItems.allObjects { item.invalidate() }
            observers.removeAll()
            windowObservers.removeAll()
            collectionView.onActivateSelection = nil
            collectionView.itemIDAtIndex = nil
            collectionView.onFocusChange = nil
            collectionView.delegate = nil
            collectionView.dataSource = nil
            dataSource = nil
            scrollView.reset()
            contents = NativeVideoCardContents()
            onSelect = { _ in }
        }

        private func applySnapshot(
            animatingDifferences: Bool,
            completion: (() -> Void)? = nil
        ) {
            dataSource?.apply(
                contents.makeSnapshot(),
                animatingDifferences: animatingDifferences,
                completion: completion
            )
        }

        private func configure(
            _ item: NativeVideoCollectionItem,
            with presentation: NativeVideoCardPresentation
        ) {
            configuredItems.add(item)
            item.configure(
                presentation: presentation,
                imagePipeline: imagePipeline,
                hoverChanged: { [weak self] item, isHovered in
                    self?.item(item, didChangeHover: isHovered)
                },
                activation: { [weak self] id in
                    self?.selectAndActivate(id)
                }
            )
            if !isInteractionEnabled {
                item.invalidateImageRequests()
                item.clearHover()
            }
        }

        private func selectAndActivate(_ id: String) {
            guard
                !isReset,
                isInteractionEnabled,
                contents[id] != nil
            else { return }
            if let indexPath = contents.indexPath(of: id) {
                collectionView.selectionIndexPaths = [indexPath]
            }
            onSelect(id)
        }

        private func reconfigureVisibleCards(ids: Set<String>? = nil) {
            for (item, presentation) in contents.visibleCards(in: collectionView, ids: ids) {
                configure(item, with: presentation)
            }
        }

        private func invalidateInteractionAndImageRequestsForContentReplacement() {
            scrollView.clearFirstResponderIfNeeded()
            hover.setHoveredItem(nil)
            collectionView.clearSelectionForContentReplacement()
            for item in configuredItems.allObjects {
                item.invalidateImageRequests()
                item.clearHover()
            }
        }

        private func applyInteractionState(
            _ isEnabled: Bool,
            reconfiguresCards: Bool
        ) {
            let changed = isInteractionEnabled != isEnabled
            isInteractionEnabled = isEnabled
            collectionView.isInteractionEnabled = isEnabled
            collectionView.isSelectable = isEnabled
            scrollView.setInteractionEnabled(isEnabled)
            scrollView.setAccessibilityHidden(!isEnabled)
            guard changed else { return }
            if isEnabled {
                if reconfiguresCards { reconfigureVisibleCards() }
                updateHoverForCurrentPointerLocation()
            } else {
                invalidateInteractionAndImageRequestsForContentReplacement()
            }
        }

        private func resizeDocument(invalidateLayout: Bool) {
            guard !isReset, !isResizingDocument else { return }
            isResizingDocument = true
            defer { isResizingDocument = false }
            let viewport = scrollView.contentSize
            let targetSize = NSSize(
                width: max(
                    viewport.width,
                    NativeVideoShelfGeometry.documentWidth(itemCount: contents.orderedIDs.count)
                ),
                height: max(viewport.height, NativeVideoShelfGeometry.viewportHeight)
            )
            let sizeChanged =
                abs(collectionView.frame.width - targetSize.width) > 0.5
                || abs(collectionView.frame.height - targetSize.height) > 0.5
            if sizeChanged { collectionView.setFrameSize(targetSize) }
            if invalidateLayout { layout.invalidateLayout() }
            if sizeChanged || invalidateLayout { collectionView.needsLayout = true }
            updatePageControls()
        }

        private func viewportDidLayout() {
            guard !isReset else { return }
            let logicalOffset = currentLogicalOffsetX
            resizeDocument(invalidateLayout: false)
            let clampedOffset = min(logicalOffset, maximumLogicalOffsetX)
            if abs(clampedOffset - logicalOffset) > 0.5 {
                applyLogicalScrollOffset(clampedOffset, animated: false)
            } else {
                updatePageControls()
            }
            updateHoverForCurrentPointerLocation()
        }

        private var currentLogicalOffsetX: CGFloat {
            NativeVideoScrollCoordinateSpace.logicalOffset(
                physicalOffset: scrollView.contentView.bounds.origin.x,
                leadingInset: scrollView.contentInsets.left
            )
        }

        private var maximumLogicalOffsetX: CGFloat {
            NativeVideoScrollCoordinateSpace.maximumLogicalOffset(
                documentLength: NativeVideoShelfGeometry.documentWidth(
                    itemCount: contents.orderedIDs.count
                ),
                viewportLength: scrollView.contentSize.width,
                leadingInset: scrollView.contentInsets.left,
                trailingInset: scrollView.contentInsets.right
            )
        }

        private func page(by direction: Int) {
            let current = NativeVideoShelfGeometry.nearestIndex(
                offset: currentLogicalOffsetX,
                itemCount: contents.orderedIDs.count
            )
            let capacity = NativeVideoShelfGeometry.pageCapacity(
                viewportWidth: max(
                    NativeVideoShelfGeometry.cardWidth,
                    scrollView.contentSize.width
                        - max(0, scrollView.contentInsets.left)
                        - max(0, scrollView.contentInsets.right)
                )
            )
            scroll(to: current + direction * capacity, animated: !reduceMotion)
        }

        private func scrollToLeading() {
            applyLogicalScrollOffset(0, animated: false)
        }

        private func scroll(to index: Int, animated: Bool) {
            guard !contents.orderedIDs.isEmpty else { return }
            let targetIndex = min(contents.orderedIDs.count - 1, max(0, index))
            applyLogicalScrollOffset(
                NativeVideoShelfGeometry.offset(for: targetIndex),
                animated: animated
            )
        }

        private func applyLogicalScrollOffset(_ requested: CGFloat, animated: Bool) {
            let logicalTarget = min(max(0, requested), maximumLogicalOffsetX)
            let physicalTarget = NativeVideoScrollCoordinateSpace.physicalOffset(
                logicalOffset: logicalTarget,
                leadingInset: scrollView.contentInsets.left
            )
            scrollView.scrollHorizontally(to: physicalTarget, animated: animated)
            updatePageControls()
        }

        private func didScroll() {
            guard !isReset else { return }
            updateHoverForCurrentPointerLocation()
            updatePageControls()
        }

        private func updatePageControls() {
            let offset = currentLogicalOffsetX
            scrollView.updatePageAvailability(
                canGoBackward: offset > 0.5,
                canGoForward: offset < maximumLogicalOffsetX - 0.5
            )
        }

        private func updateHoverForCurrentPointerLocation() {
            guard isInteractionEnabled else {
                hover.setHoveredItem(nil)
                return
            }
            hover.updateForCurrentPointerLocation(in: collectionView)
        }

        private func item(
            _ item: NativeVideoCollectionItem,
            didChangeHover isHovered: Bool
        ) {
            guard !isReset else { return }
            guard isInteractionEnabled else {
                if isHovered { item.clearHover() }
                return
            }
            hover.itemDidChangeHover(item, isHovered: isHovered)
        }

        private func observeWindow(_ window: NSWindow?) {
            windowObservers.removeAll()
            guard let window else {
                hover.setHoveredItem(nil)
                return
            }
            windowObservers.observe(NSWindow.didResignKeyNotification, object: window) {
                [weak self] in
                self?.hover.setHoveredItem(nil)
                self?.collectionView.hideKeyboardSelectionAppearance()
                self?.scrollView.clearTransientControls()
            }
        }

        func collectionView(
            _ collectionView: NSCollectionView,
            didEndDisplaying item: NSCollectionViewItem,
            forRepresentedObjectAt indexPath: IndexPath
        ) {
            guard let item = item as? NativeVideoCollectionItem else { return }
            guard collectionView.indexPath(for: item) == nil else { return }
            hover.itemDidEndDisplaying(item)
        }
    }
}

@MainActor
final class NativeVideoShelfScrollView: NSScrollView {
    var onViewportLayout: (() -> Void)?
    var onPageBackward: (() -> Void)?
    var onPageForward: (() -> Void)?
    var onWindowChange: ((NSWindow?) -> Void)?

    private let backwardButton = NativeVideoShelfPageButton()
    private let forwardButton = NativeVideoShelfPageButton()
    private var trackingArea: NSTrackingArea?
    private var isPointerInside = false
    private var canGoBackward = false
    private var canGoForward = false
    private var viewportTracker = NativeScrollViewportTracker()
    private var viewportUpdateScheduled = false
    private var focusUpdateScheduled = false
    private var isInteractionEnabled = true

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        for (button, symbol, label) in [
            (backwardButton, "chevron.left", AppStrings.localized("上一排相关推荐")),
            (forwardButton, "chevron.right", AppStrings.localized("下一排相关推荐"))
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
            button.isHidden = true
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

    func install(collectionView: NSCollectionView) {
        documentView = collectionView
        hasHorizontalScroller = true
        horizontalScroller = NativeVideoShelfHiddenScroller()
        hasVerticalScroller = false
        verticalScroller = nil
        drawsBackground = false
        automaticallyAdjustsContentInsets = true
        usesPredominantAxisScrolling = true
        horizontalScrollElasticity = .automatic
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
        if backwardButton.isHidden != hidesControls {
            backwardButton.isHidden = hidesControls
        }
        if forwardButton.isHidden != hidesControls {
            forwardButton.isHidden = hidesControls
        }
    }

    private func moveFocusToCollectionIfNeeded(beforeHiding button: NSButton, hides: Bool) {
        guard hides, window?.firstResponder === button else { return }
        window?.makeFirstResponder(documentView)
    }
}

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

@MainActor
final class NativeVideoShelfHiddenScroller: NSScroller {
    override class func scrollerWidth(
        for controlSize: NSControl.ControlSize,
        scrollerStyle: NSScroller.Style
    ) -> CGFloat {
        0
    }

    override func draw(_ dirtyRect: NSRect) {}
}

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
        guard isInteractionEnabled else { return }
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
