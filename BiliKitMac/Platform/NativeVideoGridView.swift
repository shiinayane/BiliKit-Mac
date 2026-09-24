import AppKit
import BiliUI
import SwiftUI

typealias NativeVideoGridTailState = NearEndTailState<String>

struct NativeVideoGridUpdatePlan: Equatable {
    let identityChanged: Bool
    let insertedIDs: [String]
    let removedIDs: [String]
    let changedExistingIDs: Set<String>
    let isStrictTailAppend: Bool

    var animatesDifferences: Bool { identityChanged && !isStrictTailAppend }
    var restoresViewportAnchor: Bool { identityChanged && !isStrictTailAppend }

    init<Content: Equatable>(
        previousIDs: [String],
        previousContents: [String: Content],
        updatedIDs: [String],
        updatedContents: [String: Content]
    ) {
        identityChanged = previousIDs != updatedIDs
        let previousSet = Set(previousIDs)
        let updatedSet = Set(updatedIDs)
        insertedIDs = updatedIDs.filter { !previousSet.contains($0) }
        removedIDs = previousIDs.filter { !updatedSet.contains($0) }
        changedExistingIDs = Set(
            updatedIDs.filter {
                previousSet.contains($0) && previousContents[$0] != updatedContents[$0]
            }
        )
        isStrictTailAppend =
            updatedIDs.count > previousIDs.count
            && Array(updatedIDs.prefix(previousIDs.count)) == previousIDs
            && removedIDs.isEmpty
            && insertedIDs == Array(updatedIDs.dropFirst(previousIDs.count))
    }
}

struct NativeVideoGridScrollResetGate {
    private var requestID: UInt64

    init(initialRequestID: UInt64) {
        requestID = initialRequestID
    }

    mutating func consume(_ candidateRequestID: UInt64) -> Bool {
        guard candidateRequestID != requestID else { return false }
        requestID = candidateRequestID
        return true
    }
}

struct NativeVideoGridScrollResetState: Equatable {
    private(set) var requestID: UInt64 = 0
    var acknowledgedRequestID: UInt64 = 0

    mutating func request() {
        requestID &+= 1
    }
}

struct NativeVideoGridViewportAnchor: Equatable {
    let id: String
    let offsetFromViewportTop: CGFloat
}

enum NativeVideoGridAnchorRetention {
    static func targetOffsetY(
        itemOriginY: CGFloat,
        offsetFromViewportTop: CGFloat,
        minimumOffsetY: CGFloat = 0,
        maximumOffsetY: CGFloat
    ) -> CGFloat {
        min(
            max(minimumOffsetY, maximumOffsetY),
            max(minimumOffsetY, itemOriginY - offsetFromViewportTop)
        )
    }
}

struct NativeVideoScrollOffsetRetention {
    private(set) var offsetY: CGFloat
    private var persistedOffsetY: CGFloat

    init(initialOffsetY: CGFloat) {
        offsetY = max(0, initialOffsetY)
        persistedOffsetY = offsetY
    }

    mutating func record(_ offsetY: CGFloat) {
        self.offsetY = max(0, offsetY)
    }

    mutating func takePendingPersistence() -> CGFloat? {
        guard abs(offsetY - persistedOffsetY) > 0.5 else { return nil }
        persistedOffsetY = offsetY
        return offsetY
    }

    mutating func markPersisted(_ offsetY: CGFloat) {
        record(offsetY)
        persistedOffsetY = self.offsetY
    }
}

struct NativeVideoScrollBindingBridge {
    private(set) var synchronizedOffsetY: CGFloat

    init(initialOffsetY: CGFloat) {
        synchronizedOffsetY = max(0, initialOffsetY)
    }

    mutating func takeExternalRequest(_ offsetY: CGFloat) -> CGFloat? {
        let requestedOffsetY = max(0, offsetY)
        guard abs(requestedOffsetY - synchronizedOffsetY) > 0.5 else {
            return nil
        }
        synchronizedOffsetY = requestedOffsetY
        return requestedOffsetY
    }

    mutating func markSynchronized(_ offsetY: CGFloat) {
        synchronizedOffsetY = max(0, offsetY)
    }
}

struct NativeVideoGridOperationEpoch {
    private(set) var value: UInt64 = 0

    mutating func advance() -> UInt64 {
        value &+= 1
        return value
    }

    func accepts(_ candidate: UInt64) -> Bool {
        candidate == value
    }
}

/// 网格几何来自 BiliUI，与加载骨架共用；近尾部判断只属于原生网格。
typealias NativeVideoGridGeometry = VideoCardGridGeometry

extension VideoCardGridGeometry {
    static func nearEndTriggerIndex(
        itemCount: Int,
        width: CGFloat,
        prefetchRows: Int = 2
    ) -> Int? {
        guard itemCount > 0 else { return nil }
        let count = columnCount(for: width)
        return max(0, itemCount - count * max(1, prefetchRows))
    }

    static func isNearEnd(
        itemCount: Int,
        width: CGFloat,
        visibleMaximumY: CGFloat,
        prefetchRows: Int = 2
    ) -> Bool {
        guard
            isRenderableViewport(width: width),
            visibleMaximumY.isFinite,
            let triggerIndex = nearEndTriggerIndex(
                itemCount: itemCount,
                width: width,
                prefetchRows: prefetchRows
            )
        else { return false }
        let columns = columnCount(for: width)
        let triggerRow = triggerIndex / columns
        let triggerOriginY =
            topContentPadding
            + CGFloat(triggerRow) * (itemSize(for: width).height + verticalSpacing)
        return visibleMaximumY > triggerOriginY
    }
}

struct NativeVideoGridView: NSViewRepresentable {
    let items: [NativeVideoCardPresentation]
    @Binding var scrollOffsetY: CGFloat
    let accessibilityLabel: String
    let tailState: NativeVideoGridTailState
    @Binding var scrollReset: NativeVideoGridScrollResetState
    let imagePipeline: NativeVideoImagePipeline
    let onNearEnd: () -> Void
    let onSelect: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            items: items,
            initialScrollOffsetY: scrollOffsetY,
            accessibilityLabel: accessibilityLabel,
            tailState: tailState,
            scrollResetRequestID: scrollReset.requestID,
            acknowledgedScrollResetRequestID: scrollReset.acknowledgedRequestID,
            imagePipeline: imagePipeline,
            onScroll: { scrollOffsetY = $0 },
            onAcknowledgeScrollReset: {
                scrollReset.acknowledgedRequestID = $0
            },
            onNearEnd: onNearEnd,
            onSelect: onSelect
        )
    }

    func makeNSView(context: Context) -> NSScrollView {
        context.coordinator.makeScrollView()
    }

    func updateNSView(_ view: NSScrollView, context: Context) {
        context.coordinator.update(
            items: items,
            accessibilityLabel: accessibilityLabel,
            tailState: tailState,
            scrollResetRequestID: scrollReset.requestID,
            requestedScrollOffsetY: scrollOffsetY,
            onScroll: { scrollOffsetY = $0 },
            onAcknowledgeScrollReset: {
                scrollReset.acknowledgedRequestID = $0
            },
            onNearEnd: onNearEnd,
            onSelect: onSelect
        )
    }

    static func dismantleNSView(
        _ view: NSScrollView,
        coordinator: Coordinator
    ) {
        coordinator.reset()
    }

    @MainActor
    final class Coordinator: NSObject, NSCollectionViewDelegateFlowLayout {
        private let scrollView = NativeVideoGridScrollView()
        private let collectionView = NativeVideoCollectionView()
        private let layout = NSCollectionViewFlowLayout()
        private let imagePipeline: NativeVideoImagePipeline
        private var dataSource: NSCollectionViewDiffableDataSource<Int, String>?
        private var contents: NativeVideoCardContents
        private var accessibilityLabel: String
        private var tailState: NativeVideoGridTailState
        private var scrollResetGate: NativeVideoGridScrollResetGate
        private var nearEndPagination = NearEndPagination<String>()
        private var onScroll: (CGFloat) -> Void
        private var onAcknowledgeScrollReset: (UInt64) -> Void
        private var onNearEnd: () -> Void
        private var onSelect: (String) -> Void
        private var observers = NativeVideoNotificationObservers()
        private var pendingRestoreOffsetY: CGFloat?
        private var pendingScrollResetAcknowledgementID: UInt64?
        private var retainedScrollOffset: NativeVideoScrollOffsetRetention
        private var scrollBindingBridge: NativeVideoScrollBindingBridge
        private let hover = NativeVideoHoverTracker()
        private var lastViewportSize: NSSize?
        private var documentLayoutNeedsInvalidation = true
        private var updateEpoch = NativeVideoGridOperationEpoch()
        private var pendingViewportAnchor: NativeVideoGridViewportAnchor?
        private var pendingAnchorScrollGeneration: UInt64?
        private var scrollGeneration: UInt64 = 0
        private var isApplyingRestoration = false
        private var isLiveScrolling = false
        private var isResizingDocument = false
        private var isReset = false

        init(
            items: [NativeVideoCardPresentation],
            initialScrollOffsetY: CGFloat,
            accessibilityLabel: String,
            tailState: NativeVideoGridTailState,
            scrollResetRequestID: UInt64,
            acknowledgedScrollResetRequestID: UInt64,
            imagePipeline: NativeVideoImagePipeline,
            onScroll: @escaping (CGFloat) -> Void,
            onAcknowledgeScrollReset: @escaping (UInt64) -> Void,
            onNearEnd: @escaping () -> Void,
            onSelect: @escaping (String) -> Void
        ) {
            contents = NativeVideoCardContents(items)
            self.accessibilityLabel = accessibilityLabel
            self.tailState = tailState
            scrollResetGate = NativeVideoGridScrollResetGate(
                initialRequestID: acknowledgedScrollResetRequestID
            )
            self.imagePipeline = imagePipeline
            self.onScroll = onScroll
            self.onAcknowledgeScrollReset = onAcknowledgeScrollReset
            self.onNearEnd = onNearEnd
            self.onSelect = onSelect
            retainedScrollOffset = NativeVideoScrollOffsetRetention(
                initialOffsetY: initialScrollOffsetY
            )
            scrollBindingBridge = NativeVideoScrollBindingBridge(
                initialOffsetY: initialScrollOffsetY
            )
            pendingRestoreOffsetY = retainedScrollOffset.offsetY
            if scrollResetGate.consume(scrollResetRequestID) {
                pendingRestoreOffsetY = 0
                pendingScrollResetAcknowledgementID = scrollResetRequestID
            }
        }

        func makeScrollView() -> NSScrollView {
            let padding = NativeVideoGridGeometry.contentPadding
            layout.minimumInteritemSpacing = NativeVideoGridGeometry.horizontalSpacing
            layout.minimumLineSpacing = NativeVideoGridGeometry.verticalSpacing
            layout.sectionInset = NSEdgeInsets(
                top: NativeVideoGridGeometry.topContentPadding,
                left: padding,
                bottom: padding,
                right: padding
            )
            collectionView.collectionViewLayout = layout
            collectionView.delegate = self
            collectionView.isSelectable = true
            collectionView.allowsMultipleSelection = false
            collectionView.backgroundColors = [.clear]
            collectionView.onActivateSelection = { [weak self] id in
                self?.onSelect(id)
            }
            collectionView.register(
                NativeVideoCollectionItem.self,
                forItemWithIdentifier: .nativeVideoCard
            )

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

            scrollView.documentView = collectionView
            scrollView.hasVerticalScroller = true
            scrollView.autohidesScrollers = true
            scrollView.drawsBackground = false
            scrollView.contentView.postsBoundsChangedNotifications = true
            scrollView.onViewportLayout = { [weak self] in
                self?.resizeDocument()
                self?.restorePendingOffsetIfPossible()
                self?.evaluateNearEnd()
            }
            scrollView.onContentInsetsChange = { [weak self] oldInsets, newInsets in
                self?.contentInsetsDidChange(from: oldInsets, to: newInsets)
            }
            collectionView.setAccessibilityLabel(accessibilityLabel)

            observers.observeScrolling(of: scrollView) { [weak self] in self?.didScroll() }
            observers.observe(
                NSScrollView.didEndLiveScrollNotification,
                object: scrollView
            ) { [weak self] in
                self?.isLiveScrolling = false
                self?.persistScrollOffset()
            }
            observers.observe(
                NSScrollView.willStartLiveScrollNotification,
                object: scrollView
            ) { [weak self] in
                self?.isLiveScrolling = true
                self?.nearEndPagination.releaseBackpressure()
            }
            observers.observeAccessibilityDisplayOptions { [weak collectionView] in
                collectionView?.refreshVisibleCardAppearance()
            }

            applySnapshot(animatingDifferences: false)
            DispatchQueue.main.async { [weak self] in
                self?.resizeDocument()
                self?.restorePendingOffsetIfPossible()
                self?.evaluateNearEnd()
            }
            return scrollView
        }

        func update(
            items: [NativeVideoCardPresentation],
            accessibilityLabel: String,
            tailState: NativeVideoGridTailState,
            scrollResetRequestID: UInt64,
            requestedScrollOffsetY: CGFloat,
            onScroll: @escaping (CGFloat) -> Void,
            onAcknowledgeScrollReset: @escaping (UInt64) -> Void,
            onNearEnd: @escaping () -> Void,
            onSelect: @escaping (String) -> Void
        ) {
            guard !isReset else { return }
            self.onScroll = onScroll
            self.onAcknowledgeScrollReset = onAcknowledgeScrollReset
            self.onNearEnd = onNearEnd
            self.onSelect = onSelect
            self.tailState = tailState
            let requestedExternalOffset = scrollBindingBridge.takeExternalRequest(
                requestedScrollOffsetY
            )
            if scrollResetGate.consume(scrollResetRequestID) {
                pendingRestoreOffsetY = 0
                pendingScrollResetAcknowledgementID = scrollResetRequestID
                pendingViewportAnchor = nil
                pendingAnchorScrollGeneration = nil
            } else if pendingScrollResetAcknowledgementID == nil,
                let requestedExternalOffset
            {
                pendingRestoreOffsetY = requestedExternalOffset
                pendingViewportAnchor = nil
                pendingAnchorScrollGeneration = nil
            }
            if self.accessibilityLabel != accessibilityLabel {
                self.accessibilityLabel = accessibilityLabel
                collectionView.setAccessibilityLabel(accessibilityLabel)
            }

            let updatedContents = NativeVideoCardContents(items)
            let updatePlan = NativeVideoGridUpdatePlan(
                previousIDs: contents.orderedIDs,
                previousContents: contents.byID,
                updatedIDs: updatedContents.orderedIDs,
                updatedContents: updatedContents.byID
            )
            if updatePlan.restoresViewportAnchor,
                pendingRestoreOffsetY == nil,
                pendingViewportAnchor == nil
            {
                pendingViewportAnchor = captureViewportAnchor()
                pendingAnchorScrollGeneration = scrollGeneration
            }
            contents = updatedContents

            if updatePlan.identityChanged, !updatePlan.isStrictTailAppend {
                // 内容整体替换后，旧手势留下的背压不再适用。
                nearEndPagination.releaseBackpressure()
            }
            if updatePlan.identityChanged {
                let operationGeneration = updateEpoch.advance()
                let capturedScrollGeneration = scrollGeneration
                documentLayoutNeedsInvalidation = true
                applySnapshot(
                    animatingDifferences: updatePlan.animatesDifferences
                ) { [weak self] in
                    guard
                        let self,
                        !self.isReset,
                        self.updateEpoch.accepts(operationGeneration)
                    else { return }
                    self.reconfigureVisibleItems()
                    let anchor = self.pendingViewportAnchor
                    let anchorScrollGeneration = self.pendingAnchorScrollGeneration
                    self.pendingViewportAnchor = nil
                    self.pendingAnchorScrollGeneration = nil
                    if self.pendingRestoreOffsetY != nil {
                        self.resizeDocument(restoringViewport: false)
                        self.restorePendingOffsetIfPossible()
                    } else if anchor != nil,
                        !self.isLiveScrolling,
                        self.scrollGeneration
                            == (anchorScrollGeneration ?? capturedScrollGeneration)
                    {
                        self.resizeDocument(anchor: anchor)
                        self.restorePendingOffsetIfPossible()
                    } else {
                        self.resizeDocument(restoringViewport: false)
                    }
                    self.evaluateNearEnd()
                }
            } else if !updatePlan.changedExistingIDs.isEmpty {
                reconfigureVisibleItems(updatePlan.changedExistingIDs)
            }

            if !updatePlan.identityChanged {
                restorePendingOffsetIfPossible()
                evaluateNearEnd()
            }
        }

        func reset() {
            guard !isReset else { return }
            recordCurrentScrollOffset(requireAttachedWindow: false)
            persistScrollOffset()
            isReset = true
            _ = updateEpoch.advance()
            hover.forgetHoveredItem()
            for item in collectionView.visibleVideoCards { item.invalidate() }
            collectionView.onActivateSelection = nil
            scrollView.onViewportLayout = nil
            scrollView.onContentInsetsChange = nil
            collectionView.delegate = nil
            collectionView.dataSource = nil
            dataSource = nil
            observers.removeAll()
            onScroll = { _ in }
            onAcknowledgeScrollReset = { _ in }
            onNearEnd = {}
            onSelect = { _ in }
            lastViewportSize = nil
            contents = NativeVideoCardContents()
            nearEndPagination.reset()
            pendingViewportAnchor = nil
            pendingAnchorScrollGeneration = nil
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

        private func reconfigureVisibleItems(_ ids: Set<String>? = nil) {
            for (item, presentation) in contents.visibleCards(in: collectionView, ids: ids) {
                configure(item, with: presentation)
            }
        }

        private func configure(
            _ item: NativeVideoCollectionItem,
            with presentation: NativeVideoCardPresentation
        ) {
            item.configure(
                presentation: presentation,
                imagePipeline: imagePipeline,
                hoverChanged: { [weak self] item, isHovered in
                    self?.item(item, didChangeHover: isHovered)
                },
                activation: { [weak self, weak collectionView] selectedID in
                    if let indexPath = self?.contents.indexPath(of: selectedID) {
                        collectionView?.selectionIndexPaths = [indexPath]
                    }
                    self?.onSelect(selectedID)
                }
            )
        }

        /// `restoringViewport` 为 false 时无条件重排 document，且不恢复语义 anchor。
        private func resizeDocument(
            restoringViewport: Bool = true,
            anchor suppliedAnchor: NativeVideoGridViewportAnchor? = nil
        ) {
            guard !isReset, !isResizingDocument else { return }
            let viewportSize = scrollView.contentSize
            guard NativeVideoGridGeometry.isRenderableViewport(width: viewportSize.width)
            else {
                lastViewportSize = nil
                documentLayoutNeedsInvalidation = true
                return
            }
            isResizingDocument = true
            defer { isResizingDocument = false }
            let anchor = restoringViewport ? suppliedAnchor ?? captureViewportAnchor() : nil
            let width = viewportSize.width
            let widthChanged =
                lastViewportSize.map {
                    abs($0.width - viewportSize.width) > 0.5
                } ?? true
            let heightChanged =
                lastViewportSize.map {
                    abs($0.height - viewportSize.height) > 0.5
                } ?? true
            let shouldInvalidateLayout =
                !restoringViewport || documentLayoutNeedsInvalidation || widthChanged
            guard shouldInvalidateLayout || heightChanged else { return }

            lastViewportSize = viewportSize
            documentLayoutNeedsInvalidation = false
            let contentHeight = NativeVideoGridGeometry.contentHeight(
                for: width,
                itemCount: contents.orderedIDs.count
            )
            collectionView.setFrameSize(
                NSSize(width: width, height: max(viewportSize.height, contentHeight))
            )
            if shouldInvalidateLayout { layout.invalidateLayout() }
            collectionView.layoutSubtreeIfNeeded()
            restore(anchor)
        }

        private var currentScrollOffsetY: CGFloat {
            NativeVideoScrollCoordinateSpace.logicalOffset(
                physicalOffset: scrollView.contentView.bounds.origin.y,
                leadingInset: scrollView.contentInsets.top
            )
        }

        private var minimumPhysicalScrollOffsetY: CGFloat {
            -max(0, scrollView.contentInsets.top)
        }

        private var maximumLogicalScrollOffsetY: CGFloat {
            NativeVideoScrollCoordinateSpace.maximumLogicalOffset(
                documentLength: collectionView.frame.height,
                viewportLength: scrollView.contentSize.height,
                leadingInset: scrollView.contentInsets.top,
                trailingInset: scrollView.contentInsets.bottom
            )
        }

        private var maximumPhysicalScrollOffsetY: CGFloat {
            NativeVideoScrollCoordinateSpace.physicalOffset(
                logicalOffset: maximumLogicalScrollOffsetY,
                leadingInset: scrollView.contentInsets.top
            )
        }

        private func didScroll() {
            guard
                !isReset,
                NativeVideoGridGeometry.isRenderableViewport(
                    width: scrollView.contentSize.width
                )
            else { return }
            hover.updateForCurrentPointerLocation(in: collectionView)
            recordCurrentScrollOffset(requireAttachedWindow: true)
            evaluateNearEnd()
        }

        @discardableResult
        private func recordCurrentScrollOffset(requireAttachedWindow: Bool) -> Bool {
            guard
                !isApplyingRestoration,
                pendingRestoreOffsetY == nil,
                !requireAttachedWindow || scrollView.window != nil,
                NativeVideoGridGeometry.isRenderableViewport(
                    width: scrollView.contentSize.width
                )
            else { return false }
            retainedScrollOffset.record(currentScrollOffsetY)
            scrollGeneration &+= 1
            return true
        }

        private func persistScrollOffset() {
            guard !isReset else { return }
            guard let offsetY = retainedScrollOffset.takePendingPersistence() else {
                return
            }
            synchronizeBinding(to: offsetY)
        }

        private func contentInsetsDidChange(
            from oldInsets: NSEdgeInsets,
            to newInsets: NSEdgeInsets
        ) {
            guard !isReset else { return }
            if pendingRestoreOffsetY != nil {
                restorePendingOffsetIfPossible()
                return
            }
            let logicalOffset = NativeVideoScrollCoordinateSpace.logicalOffset(
                physicalOffset: scrollView.contentView.bounds.origin.y,
                leadingInset: oldInsets.top
            )
            applyLogicalScrollOffset(logicalOffset, synchronizingBinding: false)
            retainedScrollOffset.markPersisted(logicalOffset)
        }

        private func captureViewportAnchor() -> NativeVideoGridViewportAnchor? {
            guard
                !contents.orderedIDs.isEmpty,
                lastViewportSize != nil,
                NativeVideoGridGeometry.isRenderableViewport(
                    width: collectionView.bounds.width
                )
            else { return nil }
            let visibleTop = collectionView.visibleRect.minY
            let candidates = collectionView.indexPathsForVisibleItems().compactMap {
                indexPath -> (IndexPath, NSCollectionViewLayoutAttributes)? in
                guard let attributes = layout.layoutAttributesForItem(at: indexPath) else {
                    return nil
                }
                return (indexPath, attributes)
            }
            guard let first = candidates.min(by: { $0.1.frame.minY < $1.1.frame.minY }),
                contents.orderedIDs.indices.contains(first.0.item)
            else { return nil }
            return NativeVideoGridViewportAnchor(
                id: contents.orderedIDs[first.0.item],
                offsetFromViewportTop: first.1.frame.minY - visibleTop
            )
        }

        private func restore(_ anchor: NativeVideoGridViewportAnchor?) {
            guard
                let anchor,
                let index = contents.orderedIDs.firstIndex(of: anchor.id),
                let attributes = layout.layoutAttributesForItem(
                    at: IndexPath(item: index, section: 0)
                )
            else { return }
            let target = NativeVideoGridAnchorRetention.targetOffsetY(
                itemOriginY: attributes.frame.minY,
                offsetFromViewportTop: anchor.offsetFromViewportTop,
                minimumOffsetY: minimumPhysicalScrollOffsetY,
                maximumOffsetY: maximumPhysicalScrollOffsetY
            )
            applyPhysicalScrollOffset(target)
        }

        private func restorePendingOffsetIfPossible() {
            guard
                !isReset,
                lastViewportSize != nil,
                NativeVideoGridGeometry.isRenderableViewport(
                    width: scrollView.contentSize.width
                ),
                let pendingRestoreOffsetY
            else { return }
            let target = min(pendingRestoreOffsetY, maximumLogicalScrollOffsetY)
            applyLogicalScrollOffset(target, synchronizingBinding: false)
            self.pendingRestoreOffsetY = nil
            retainedScrollOffset.markPersisted(target)
            synchronizeBinding(to: target)
            if let acknowledgementID = pendingScrollResetAcknowledgementID {
                pendingScrollResetAcknowledgementID = nil
                onAcknowledgeScrollReset(acknowledgementID)
            }
        }

        private func applyLogicalScrollOffset(
            _ target: CGFloat,
            synchronizingBinding: Bool
        ) {
            let logicalTarget = min(max(0, target), maximumLogicalScrollOffsetY)
            let physicalTarget = NativeVideoScrollCoordinateSpace.physicalOffset(
                logicalOffset: logicalTarget,
                leadingInset: scrollView.contentInsets.top
            )
            applyPhysicalScrollOffset(physicalTarget)
            retainedScrollOffset.markPersisted(logicalTarget)
            if synchronizingBinding { synchronizeBinding(to: logicalTarget) }
        }

        private func synchronizeBinding(to offsetY: CGFloat) {
            scrollBindingBridge.markSynchronized(offsetY)
            onScroll(offsetY)
        }

        private func applyPhysicalScrollOffset(_ target: CGFloat) {
            isApplyingRestoration = true
            scrollView.scrollVertically(toPhysicalOffset: target)
            isApplyingRestoration = false
        }

        private func evaluateNearEnd() {
            guard
                !isReset,
                lastViewportSize != nil,
                NativeVideoGridGeometry.isRenderableViewport(
                    width: collectionView.bounds.width
                )
            else { return }
            let isInside =
                tailState.canLoadMore && tailState.tailIdentity != nil
                && NativeVideoGridGeometry.isNearEnd(
                    itemCount: contents.orderedIDs.count,
                    width: collectionView.bounds.width,
                    visibleMaximumY: collectionView.visibleRect.maxY
                )
            if nearEndPagination.shouldLoadMore(
                isInsideThreshold: isInside,
                state: tailState,
                isLiveScrolling: isLiveScrolling
            ) {
                onNearEnd()
            }
        }

        private func item(
            _ item: NativeVideoCollectionItem,
            didChangeHover isHovered: Bool
        ) {
            guard !isReset else { return }
            hover.itemDidChangeHover(item, isHovered: isHovered)
        }

        func collectionView(
            _ collectionView: NSCollectionView,
            layout collectionViewLayout: NSCollectionViewLayout,
            sizeForItemAt indexPath: IndexPath
        ) -> NSSize {
            NativeVideoGridGeometry.itemSize(for: collectionView.bounds.width)
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
private final class NativeVideoGridScrollView: NSScrollView {
    var onViewportLayout: (() -> Void)?
    var onContentInsetsChange: ((NSEdgeInsets, NSEdgeInsets) -> Void)?
    private var viewportTracker = NativeScrollViewportTracker()

    override func layout() {
        super.layout()
        let change = viewportTracker.update(for: self)
        if let previousInsets = change.previousInsets {
            onContentInsetsChange?(previousInsets, contentInsets)
        }
        if change.sizeChanged { onViewportLayout?() }
    }
}

@MainActor
private final class NativeVideoCollectionView: NativeVideoCardCollectionView {
    override func mouseDown(with event: NSEvent) {
        setShowsKeyboardSelection(false)
        let point = convert(event.locationInWindow, from: nil)
        let clickedIndexPath = indexPathForItem(at: point)
        super.mouseDown(with: event)
        guard
            let clickedIndexPath,
            let id = item(at: clickedIndexPath)?.representedObject as? String
        else { return }
        onActivateSelection?(id)
    }

    override func keyDown(with event: NSEvent) {
        if NativeVideoCollectionKeys.isActivation(event),
            let indexPath = selectionIndexPaths.first,
            let id = item(at: indexPath)?.representedObject as? String
        {
            onActivateSelection?(id)
            return
        }
        if let delta = NativeVideoCollectionKeys.selectionDelta(
            for: event,
            rowLength: NativeVideoGridGeometry.columnCount(for: bounds.width)
        ), numberOfItems(inSection: 0) > 0 {
            let visibleStart = indexPathsForVisibleItems().map(\.item).min() ?? 0
            let current = selectionIndexPaths.first?.item ?? visibleStart
            selectWithKeyboard(itemAt: current + delta, scrollPosition: .nearestVerticalEdge)
            return
        }
        super.keyDown(with: event)
    }
}
