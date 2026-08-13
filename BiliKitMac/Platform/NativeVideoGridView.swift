import AppKit
import SwiftUI

struct NativeVideoGridTailState: Equatable {
    let canLoadMore: Bool
    let tailIdentity: String?
    let isLoading: Bool

    static let end = Self(
        canLoadMore: false,
        tailIdentity: nil,
        isLoading: false
    )
}

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

struct NativeVideoGridNearEndGate {
    private(set) var tailIdentity: String?
    private(set) var wasInsideThreshold = false
    private(set) var triggeredTailIdentity: String?

    mutating func update(
        isInsideThreshold: Bool,
        state: NativeVideoGridTailState
    ) -> Bool {
        if state.tailIdentity != tailIdentity {
            tailIdentity = state.tailIdentity
            wasInsideThreshold = false
            triggeredTailIdentity = nil
        }
        guard state.canLoadMore, state.tailIdentity != nil else {
            wasInsideThreshold = false
            return false
        }
        defer { wasInsideThreshold = isInsideThreshold }
        guard isInsideThreshold,
            !wasInsideThreshold,
            !state.isLoading,
            triggeredTailIdentity != state.tailIdentity
        else {
            return false
        }
        triggeredTailIdentity = state.tailIdentity
        return true
    }

    mutating func reset() {
        tailIdentity = nil
        wasInsideThreshold = false
        triggeredTailIdentity = nil
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
        maximumOffsetY: CGFloat
    ) -> CGFloat {
        min(
            max(0, maximumOffsetY),
            max(0, itemOriginY - offsetFromViewportTop)
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

enum NativeVideoGridGeometry {
    static let horizontalSpacing: CGFloat = 20
    static let verticalSpacing: CGFloat = 28
    static let contentPadding: CGFloat = 24
    static let topContentPadding: CGFloat = 0
    static let minimumRenderableWidth = contentPadding * 2 + horizontalSpacing + 2

    static func isRenderableViewport(width: CGFloat) -> Bool {
        width.isFinite && width >= minimumRenderableWidth
    }

    static func columnCount(for width: CGFloat) -> Int {
        let usableWidth = max(0, width - contentPadding * 2)
        let naturalCount = Int(
            (usableWidth + horizontalSpacing) / (240 + horizontalSpacing)
        )
        return min(5, max(2, naturalCount))
    }

    static func itemSize(for width: CGFloat) -> NSSize {
        let usableWidth = max(1, width - contentPadding * 2)
        let count = columnCount(for: width)
        let spacing = CGFloat(count - 1) * horizontalSpacing
        let cardWidth = max(
            1,
            floor((usableWidth - spacing) / CGFloat(count))
        )
        return NSSize(width: cardWidth, height: floor(cardWidth * 9 / 16) + 84)
    }

    static func contentHeight(for width: CGFloat, itemCount: Int) -> CGFloat {
        guard itemCount > 0 else { return 0 }
        let columns = columnCount(for: width)
        let rows = (itemCount + columns - 1) / columns
        return topContentPadding
            + CGFloat(rows) * itemSize(for: width).height
            + CGFloat(rows - 1) * verticalSpacing
            + contentPadding
    }

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
    let imagePipeline: NativeVideoImagePipeline
    let onNearEnd: () -> Void
    let onSelect: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            items: items,
            initialScrollOffsetY: scrollOffsetY,
            accessibilityLabel: accessibilityLabel,
            tailState: tailState,
            imagePipeline: imagePipeline,
            onScroll: { scrollOffsetY = $0 },
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
            onScroll: { scrollOffsetY = $0 },
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
        private var contentsByID: [String: NativeVideoCardPresentation]
        private var orderedIDs: [String]
        private var accessibilityLabel: String
        private var tailState: NativeVideoGridTailState
        private var nearEndGate = NativeVideoGridNearEndGate()
        private var onScroll: (CGFloat) -> Void
        private var onNearEnd: () -> Void
        private var onSelect: (String) -> Void
        private var boundsObserver: NSObjectProtocol?
        private var liveScrollStartObserver: NSObjectProtocol?
        private var liveScrollEndObserver: NSObjectProtocol?
        private var accessibilityObserver: NSObjectProtocol?
        private var pendingRestoreOffsetY: CGFloat?
        private var retainedScrollOffset: NativeVideoScrollOffsetRetention
        private weak var hoveredItem: NativeVideoCollectionItem?
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
            imagePipeline: NativeVideoImagePipeline,
            onScroll: @escaping (CGFloat) -> Void,
            onNearEnd: @escaping () -> Void,
            onSelect: @escaping (String) -> Void
        ) {
            let uniqueItems = Self.uniqueItems(items)
            contentsByID = Dictionary(
                uniqueKeysWithValues: uniqueItems.map { ($0.id, $0) }
            )
            orderedIDs = uniqueItems.map(\.id)
            self.accessibilityLabel = accessibilityLabel
            self.tailState = tailState
            self.imagePipeline = imagePipeline
            self.onScroll = onScroll
            self.onNearEnd = onNearEnd
            self.onSelect = onSelect
            retainedScrollOffset = NativeVideoScrollOffsetRetention(
                initialOffsetY: initialScrollOffsetY
            )
            pendingRestoreOffsetY = retainedScrollOffset.offsetY
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

            dataSource = NSCollectionViewDiffableDataSource<Int, String>(
                collectionView: collectionView
            ) { [weak self] collectionView, indexPath, id in
                guard
                    let self,
                    let presentation = self.contentsByID[id],
                    let item = collectionView.makeItem(
                        withIdentifier: .nativeVideoCard,
                        for: indexPath
                    ) as? NativeVideoCollectionItem
                else { return nil }
                self.configure(item, with: presentation)
                item.setKeyboardFocusVisible(
                    (collectionView as? NativeVideoCollectionView)?
                        .showsKeyboardSelection == true
                        && collectionView.selectionIndexPaths.contains(indexPath)
                )
                return item
            }

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
            collectionView.setAccessibilityLabel(accessibilityLabel)

            boundsObserver = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: scrollView.contentView,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.didScroll() }
            }
            liveScrollEndObserver = NotificationCenter.default.addObserver(
                forName: NSScrollView.didEndLiveScrollNotification,
                object: scrollView,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.isLiveScrolling = false
                    self?.persistScrollOffset()
                }
            }
            liveScrollStartObserver = NotificationCenter.default.addObserver(
                forName: NSScrollView.willStartLiveScrollNotification,
                object: scrollView,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.isLiveScrolling = true }
            }
            accessibilityObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.refreshVisibleInteractionAppearance()
                }
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
            onScroll: @escaping (CGFloat) -> Void,
            onNearEnd: @escaping () -> Void,
            onSelect: @escaping (String) -> Void
        ) {
            guard !isReset else { return }
            self.onScroll = onScroll
            self.onNearEnd = onNearEnd
            self.onSelect = onSelect
            self.tailState = tailState
            if self.accessibilityLabel != accessibilityLabel {
                self.accessibilityLabel = accessibilityLabel
                collectionView.setAccessibilityLabel(accessibilityLabel)
            }

            let uniqueItems = Self.uniqueItems(items)
            let updatedByID = Dictionary(
                uniqueKeysWithValues: uniqueItems.map { ($0.id, $0) }
            )
            let updatedIDs = uniqueItems.map(\.id)
            let updatePlan = NativeVideoGridUpdatePlan(
                previousIDs: orderedIDs,
                previousContents: contentsByID,
                updatedIDs: updatedIDs,
                updatedContents: updatedByID
            )
            if updatePlan.restoresViewportAnchor, pendingViewportAnchor == nil {
                pendingViewportAnchor = captureViewportAnchor()
                pendingAnchorScrollGeneration = scrollGeneration
            }
            contentsByID = updatedByID
            orderedIDs = updatedIDs

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
                    self.reconfigureAllVisibleItems()
                    let anchor = self.pendingViewportAnchor
                    let anchorScrollGeneration = self.pendingAnchorScrollGeneration
                    self.pendingViewportAnchor = nil
                    self.pendingAnchorScrollGeneration = nil
                    if anchor != nil,
                        !self.isLiveScrolling,
                        self.scrollGeneration
                            == (anchorScrollGeneration ?? capturedScrollGeneration)
                    {
                        self.resizeDocument(restoring: anchor)
                        self.restorePendingOffsetIfPossible()
                    } else {
                        self.resizeDocumentWithoutRestoringViewport()
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
            hoveredItem = nil
            for case let item as NativeVideoCollectionItem in collectionView.visibleItems() {
                item.invalidate()
            }
            collectionView.onActivateSelection = nil
            scrollView.onViewportLayout = nil
            collectionView.delegate = nil
            collectionView.dataSource = nil
            dataSource = nil
            if let boundsObserver { NotificationCenter.default.removeObserver(boundsObserver) }
            if let liveScrollEndObserver {
                NotificationCenter.default.removeObserver(liveScrollEndObserver)
            }
            if let liveScrollStartObserver {
                NotificationCenter.default.removeObserver(liveScrollStartObserver)
            }
            if let accessibilityObserver {
                NSWorkspace.shared.notificationCenter.removeObserver(accessibilityObserver)
            }
            boundsObserver = nil
            liveScrollStartObserver = nil
            liveScrollEndObserver = nil
            accessibilityObserver = nil
            onScroll = { _ in }
            onNearEnd = {}
            onSelect = { _ in }
            lastViewportSize = nil
            contentsByID.removeAll()
            orderedIDs.removeAll()
            nearEndGate.reset()
            pendingViewportAnchor = nil
            pendingAnchorScrollGeneration = nil
        }

        private static func uniqueItems(
            _ items: [NativeVideoCardPresentation]
        ) -> [NativeVideoCardPresentation] {
            var seen: Set<String> = []
            return items.filter { !$0.id.isEmpty && seen.insert($0.id).inserted }
        }

        private func applySnapshot(
            animatingDifferences: Bool,
            completion: (() -> Void)? = nil
        ) {
            var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
            snapshot.appendSections([0])
            snapshot.appendItems(orderedIDs, toSection: 0)
            dataSource?.apply(
                snapshot,
                animatingDifferences: animatingDifferences,
                completion: completion
            )
        }

        private func reconfigureVisibleItems(_ ids: Set<String>) {
            guard !ids.isEmpty else { return }
            for case let item as NativeVideoCollectionItem in collectionView.visibleItems() {
                guard let id = item.representedVideoID,
                    ids.contains(id),
                    let presentation = contentsByID[id]
                else { continue }
                configure(item, with: presentation)
            }
        }

        private func reconfigureAllVisibleItems() {
            for case let item as NativeVideoCollectionItem in collectionView.visibleItems() {
                guard let id = item.representedVideoID,
                    let presentation = contentsByID[id]
                else { continue }
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
                    if let index = self?.orderedIDs.firstIndex(of: selectedID) {
                        collectionView?.selectionIndexPaths = [
                            IndexPath(item: index, section: 0)
                        ]
                    }
                    self?.onSelect(selectedID)
                }
            )
        }

        private func resizeDocument(
            restoring suppliedAnchor: NativeVideoGridViewportAnchor? = nil
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
            let anchor = suppliedAnchor ?? captureViewportAnchor()
            let width = viewportSize.width
            let widthChanged =
                lastViewportSize.map {
                    abs($0.width - viewportSize.width) > 0.5
                } ?? true
            let heightChanged =
                lastViewportSize.map {
                    abs($0.height - viewportSize.height) > 0.5
                } ?? true
            let shouldInvalidateLayout = documentLayoutNeedsInvalidation || widthChanged
            guard shouldInvalidateLayout || heightChanged else { return }

            lastViewportSize = viewportSize
            documentLayoutNeedsInvalidation = false
            let contentHeight = NativeVideoGridGeometry.contentHeight(
                for: width,
                itemCount: orderedIDs.count
            )
            collectionView.setFrameSize(
                NSSize(width: width, height: max(viewportSize.height, contentHeight))
            )
            if shouldInvalidateLayout { layout.invalidateLayout() }
            collectionView.layoutSubtreeIfNeeded()
            restore(anchor)
        }

        private func resizeDocumentWithoutRestoringViewport() {
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
            let width = viewportSize.width
            lastViewportSize = viewportSize
            documentLayoutNeedsInvalidation = false
            let contentHeight = NativeVideoGridGeometry.contentHeight(
                for: width,
                itemCount: orderedIDs.count
            )
            collectionView.setFrameSize(
                NSSize(width: width, height: max(viewportSize.height, contentHeight))
            )
            layout.invalidateLayout()
            collectionView.layoutSubtreeIfNeeded()
        }

        private var currentScrollOffsetY: CGFloat {
            max(0, scrollView.contentView.bounds.origin.y)
        }

        private func didScroll() {
            guard
                !isReset,
                NativeVideoGridGeometry.isRenderableViewport(
                    width: scrollView.contentSize.width
                )
            else { return }
            updateHoverForCurrentPointerLocation()
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
            onScroll(offsetY)
        }

        private func captureViewportAnchor() -> NativeVideoGridViewportAnchor? {
            guard
                !orderedIDs.isEmpty,
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
                orderedIDs.indices.contains(first.0.item)
            else { return nil }
            return NativeVideoGridViewportAnchor(
                id: orderedIDs[first.0.item],
                offsetFromViewportTop: first.1.frame.minY - visibleTop
            )
        }

        private func restore(_ anchor: NativeVideoGridViewportAnchor?) {
            guard
                let anchor,
                let index = orderedIDs.firstIndex(of: anchor.id),
                let attributes = layout.layoutAttributesForItem(
                    at: IndexPath(item: index, section: 0)
                )
            else { return }
            let maximumOffset = max(
                0,
                collectionView.frame.height - scrollView.contentSize.height
            )
            let target = NativeVideoGridAnchorRetention.targetOffsetY(
                itemOriginY: attributes.frame.minY,
                offsetFromViewportTop: anchor.offsetFromViewportTop,
                maximumOffsetY: maximumOffset
            )
            applyScrollOffset(target)
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
            let maximumOffset = max(
                0,
                collectionView.frame.height - scrollView.contentSize.height
            )
            let target = min(pendingRestoreOffsetY, maximumOffset)
            applyScrollOffset(target)
            self.pendingRestoreOffsetY = nil
            retainedScrollOffset.markPersisted(target)
            onScroll(target)
        }

        private func applyScrollOffset(_ target: CGFloat) {
            isApplyingRestoration = true
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: target))
            scrollView.reflectScrolledClipView(scrollView.contentView)
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
            guard tailState.canLoadMore, tailState.tailIdentity != nil else {
                _ = nearEndGate.update(
                    isInsideThreshold: false,
                    state: tailState
                )
                return
            }
            let isInside = NativeVideoGridGeometry.isNearEnd(
                itemCount: orderedIDs.count,
                width: collectionView.bounds.width,
                visibleMaximumY: collectionView.visibleRect.maxY
            )
            if nearEndGate.update(
                isInsideThreshold: isInside,
                state: tailState
            ) {
                onNearEnd()
            }
        }

        private func updateHoverForCurrentPointerLocation() {
            let candidate: NativeVideoCollectionItem?
            if let windowPoint = collectionView.window?.mouseLocationOutsideOfEventStream {
                let collectionPoint = collectionView.convert(windowPoint, from: nil)
                if collectionView.visibleRect.contains(collectionPoint),
                    let indexPath = collectionView.indexPathForItem(at: collectionPoint)
                {
                    candidate =
                        collectionView.item(at: indexPath)
                        as? NativeVideoCollectionItem
                } else {
                    candidate = nil
                }
            } else {
                candidate = nil
            }
            setHoveredItem(candidate)
        }

        private func setHoveredItem(_ item: NativeVideoCollectionItem?) {
            guard hoveredItem !== item else { return }
            let previous = hoveredItem
            hoveredItem = item
            previous?.setHovered(false)
            item?.setHovered(true)
        }

        private func item(
            _ item: NativeVideoCollectionItem,
            didChangeHover isHovered: Bool
        ) {
            guard !isReset else { return }
            if isHovered {
                guard hoveredItem !== item else { return }
                let previous = hoveredItem
                hoveredItem = item
                previous?.setHovered(false)
            } else if hoveredItem === item {
                hoveredItem = nil
            }
        }

        private func refreshVisibleInteractionAppearance() {
            for case let item as NativeVideoCollectionItem in collectionView.visibleItems() {
                item.refreshEnvironmentAppearance()
            }
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
            item.invalidateImageRequests()
            item.clearHover()
        }
    }
}

@MainActor
private final class NativeVideoGridScrollView: NSScrollView {
    var onViewportLayout: (() -> Void)?
    private var lastViewportSize: NSSize?

    override func layout() {
        super.layout()
        let viewportSize = contentSize
        guard
            lastViewportSize.map({
                abs($0.width - viewportSize.width) > 0.5
                    || abs($0.height - viewportSize.height) > 0.5
            }) ?? true
        else { return }
        lastViewportSize = viewportSize
        onViewportLayout?()
    }
}

@MainActor
private final class NativeVideoCollectionView: NSCollectionView {
    var onActivateSelection: ((String) -> Void)?
    private(set) var showsKeyboardSelection = false

    override func mouseDown(with event: NSEvent) {
        showsKeyboardSelection = false
        updateVisibleKeyboardSelection()
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
        if event.keyCode == 36 || event.charactersIgnoringModifiers == " ",
            let indexPath = selectionIndexPaths.first,
            let id = item(at: indexPath)?.representedObject as? String
        {
            onActivateSelection?(id)
            return
        }
        let columnCount = NativeVideoGridGeometry.columnCount(for: bounds.width)
        let delta: Int? =
            switch event.keyCode {
            case 123: -1
            case 124: 1
            case 125: columnCount
            case 126: -columnCount
            default: nil
            }
        if let delta, moveSelection(by: delta) { return }
        super.keyDown(with: event)
    }

    private func moveSelection(by delta: Int) -> Bool {
        let itemCount = numberOfItems(inSection: 0)
        guard itemCount > 0 else { return false }
        let visibleStart = indexPathsForVisibleItems().map(\.item).min() ?? 0
        let current = selectionIndexPaths.first?.item ?? visibleStart
        let target = min(itemCount - 1, max(0, current + delta))
        let targetPath = IndexPath(item: target, section: 0)
        showsKeyboardSelection = true
        selectionIndexPaths = [targetPath]
        updateVisibleKeyboardSelection()
        scrollToItems(at: [targetPath], scrollPosition: .nearestVerticalEdge)
        DispatchQueue.main.async { [weak self] in
            self?.updateVisibleKeyboardSelection()
        }
        return true
    }

    private func updateVisibleKeyboardSelection() {
        for case let item as NativeVideoCollectionItem in visibleItems() {
            item.setKeyboardFocusVisible(showsKeyboardSelection && item.isSelected)
        }
    }
}
