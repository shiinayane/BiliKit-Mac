import AppKit
import BiliUI
import BiliVideoCollectionUI
import SwiftUI

/// 横排的分页与滚动换算；尺寸常量来自 `VideoCardShelfGeometry`。
enum NativeVideoShelfGeometry {
    private typealias Shelf = VideoCardShelfGeometry

    static var stride: CGFloat { Shelf.cardWidth + Shelf.spacing }

    /// 一次翻页跨过的卡片数。
    ///
    /// 两侧内容边距之间能完整放下的卡片（向下取整），至少 1 张。只算完整卡片，翻页后上一页最后露出的
    /// 半张成为新一页的首张；与 `placeholderCount` 语义不同。
    static func pageCapacity(viewportWidth: CGFloat) -> Int {
        let availableWidth = max(Shelf.cardWidth, viewportWidth - Shelf.contentInset * 2)
        return max(1, Int(floor((availableWidth + Shelf.spacing) / stride)))
    }

    /// 加载骨架铺满可见宽度所需的占位卡片数。
    ///
    /// 首卡起点在前缘内容边距处，按“到右缘为止排得下几张”向上取整，被右缘截断的半张也画，至少 1 张。
    /// 与 `pageCapacity` 不同，它不扣尾部边距、也不只算完整卡片；右缘只露出卡片间距时多画的一张在视野外，
    /// 由骨架裁掉。宽度不是有限值时按 1 张处理，下一次布局拿到真实宽度后再铺满。
    static func placeholderCount(viewportWidth: CGFloat) -> Int {
        guard viewportWidth.isFinite else { return 1 }
        let visibleWidth = viewportWidth - Shelf.contentInset + Shelf.spacing
        return max(1, Int(ceil(visibleWidth / stride)))
    }

    static func documentWidth(itemCount: Int) -> CGFloat {
        guard itemCount > 0 else { return 0 }
        return Shelf.contentInset * 2
            + CGFloat(itemCount) * Shelf.cardWidth
            + CGFloat(itemCount - 1) * Shelf.spacing
    }

    static func offset(for index: Int) -> CGFloat {
        CGFloat(max(0, index)) * stride
    }

    static func nearestIndex(offset: CGFloat, itemCount: Int) -> Int {
        guard itemCount > 0 else { return 0 }
        return min(itemCount - 1, max(0, Int(round(max(0, offset) / stride))))
    }
}

/// 把横排挂进 SwiftUI：coordinator 拥有集合视图与滚动视图，`dismantleNSView` 时 `reset()`。
///
/// `contentIdentity` 变化时即使卡片 ID 相同也整体替换内容：旧卡片的在途封面请求作废，横排回到起点。
struct NativeVideoShelfView: NSViewRepresentable {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled

    let contentIdentity: String
    let items: [NativeVideoCardPresentation]
    let imagePipeline: any NativeVideoImageLoading
    let onSelect: (String) -> Void
    /// 卡片菜单，与网格同一份描述（`NativeVideoCardMenu`）；横排被遮挡（交互关闭）时不弹。
    let cardMenu: (NativeVideoCardPresentation) -> NativeVideoCardMenu?

    func makeCoordinator() -> Coordinator {
        Coordinator(
            contentIdentity: contentIdentity,
            items: items,
            imagePipeline: imagePipeline,
            reduceMotion: reduceMotion,
            isInteractionEnabled: isEnabled,
            onSelect: onSelect,
            cardMenu: cardMenu
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
            onSelect: onSelect,
            cardMenu: cardMenu
        )
    }

    static func dismantleNSView(
        _ view: NativeVideoShelfScrollView,
        coordinator: Coordinator
    ) {
        coordinator.reset()
    }

    /// 横排的唯一 owner：滚动视图、集合视图、diffable 数据源、通知观察、悬停与已配置卡片。
    ///
    /// 不拥有取图实现（窗口图片管线经 port 注入）。`operationGeneration` 在每次应用快照与 `reset()` 时递增，
    /// 快照完成回调只在代次未变且未 reset 时调整文档尺寸、回到起点与重配卡片。
    @MainActor
    final class Coordinator: NSObject, NSCollectionViewDelegateFlowLayout {
        private let scrollView = NativeVideoShelfScrollView()
        private let collectionView = NativeVideoShelfCollectionView()
        private let layout = NSCollectionViewFlowLayout()
        private let imagePipeline: any NativeVideoImageLoading
        private let configuredItems = NSHashTable<NativeVideoCollectionItem>.weakObjects()
        private var dataSource: NSCollectionViewDiffableDataSource<Int, String>?
        private var contentIdentity: String
        private var contents: NativeVideoCardContents
        private var reduceMotion: Bool
        private var isInteractionEnabled: Bool
        private var onSelect: (String) -> Void
        private var cardMenu: (NativeVideoCardPresentation) -> NativeVideoCardMenu?
        private var observers = NativeVideoNotificationObservers()
        private var windowObservers = NativeVideoNotificationObservers()
        private let hover = NativeVideoHoverTracker()
        private var operationGeneration: UInt64 = 0
        private var isResizingDocument = false
        private var isReset = false

        init(
            contentIdentity: String,
            items: [NativeVideoCardPresentation],
            imagePipeline: any NativeVideoImageLoading,
            reduceMotion: Bool,
            isInteractionEnabled: Bool,
            onSelect: @escaping (String) -> Void,
            cardMenu: @escaping (NativeVideoCardPresentation) -> NativeVideoCardMenu?
        ) {
            self.contentIdentity = contentIdentity
            contents = NativeVideoCardContents(items)
            self.imagePipeline = imagePipeline
            self.reduceMotion = reduceMotion
            self.isInteractionEnabled = isInteractionEnabled
            self.onSelect = onSelect
            self.cardMenu = cardMenu
        }

        func makeScrollView() -> NativeVideoShelfScrollView {
            layout.scrollDirection = .horizontal
            layout.itemSize = NSSize(
                width: VideoCardShelfGeometry.cardWidth,
                height: VideoCardShelfGeometry.cardHeight
            )
            layout.minimumInteritemSpacing = VideoCardShelfGeometry.spacing
            layout.minimumLineSpacing = VideoCardShelfGeometry.spacing
            layout.sectionInset = NSEdgeInsets(
                top: 0,
                left: VideoCardShelfGeometry.contentInset,
                bottom: VideoCardShelfGeometry.bottomInset,
                right: VideoCardShelfGeometry.contentInset
            )

            collectionView.collectionViewLayout = layout
            collectionView.delegate = self
            collectionView.isSelectable = true
            collectionView.allowsMultipleSelection = false
            collectionView.backgroundColors = [.clear]
            collectionView.onActivateSelection = { [weak self] id in
                self?.selectAndActivate(id)
            }
            collectionView.cardMenu = { [weak self] id in
                guard
                    let self,
                    !self.isReset,
                    self.isInteractionEnabled,
                    let card = self.contents[id]
                else { return nil }
                return self.cardMenu(card)
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
            collectionView.setAccessibilityLabel(VideoDetailFeatureStrings.localized("横向相关推荐"))

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
            onSelect: @escaping (String) -> Void,
            cardMenu: @escaping (NativeVideoCardPresentation) -> NativeVideoCardMenu?
        ) {
            guard !isReset else { return }
            self.reduceMotion = reduceMotion
            self.onSelect = onSelect
            self.cardMenu = cardMenu
            applyInteractionState(isInteractionEnabled, reconfiguresCards: true)
            let updatedContents = NativeVideoCardContents(items)
            let plan = NativeVideoGridUpdatePlan(
                previousIDs: contents.orderedIDs,
                previousContents: contents.byID,
                updatedIDs: updatedContents.orderedIDs,
                updatedContents: updatedContents.byID
            )
            let resetsToLeading = self.contentIdentity != contentIdentity
            self.contentIdentity = contentIdentity
            contents = updatedContents

            // 换了父视频（内容身份变化）时即使 ID 序列相同也按替换处理：作废在途交互与图片请求、回到起点并重配
            // 可见卡片。
            if resetsToLeading || plan.identityChanged {
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
            collectionView.cardMenu = nil
            collectionView.itemIDAtIndex = nil
            collectionView.onFocusChange = nil
            collectionView.delegate = nil
            collectionView.dataSource = nil
            dataSource = nil
            scrollView.reset()
            contents = NativeVideoCardContents()
            onSelect = { _ in }
            cardMenu = { _ in nil }
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

        /// 横排激活的唯一入口：点击、回车／空格与读屏按下都经这里；与网格同一规则，不可用或已不在内容里的卡片不
        /// 回调 `onSelect`。
        private func selectAndActivate(_ id: String) {
            guard
                !isReset,
                isInteractionEnabled,
                contents.isActivatable(id)
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
                height: max(viewport.height, VideoCardShelfGeometry.viewportHeight)
            )
            let sizeChanged =
                NativeViewportSize.differs(collectionView.frame.width, targetSize.width)
                || NativeViewportSize.differs(collectionView.frame.height, targetSize.height)
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
                    VideoCardShelfGeometry.cardWidth,
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
