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

    /// 锚点卡片前面露出的上一张卡片宽度比例：露出一部分让人知道左边还有，又把位置留给后面几集。
    static let anchorLeadingPeekFraction: CGFloat = 0.3

    /// 让第 `index` 张卡片靠前缘、前面露出上一张一部分的逻辑偏移。
    static func anchorOffset(for index: Int) -> CGFloat {
        guard index > 0 else { return 0 }
        return offset(for: index) - Shelf.cardWidth * anchorLeadingPeekFraction
    }

    static func nearestIndex(offset: CGFloat, itemCount: Int) -> Int {
        guard itemCount > 0 else { return 0 }
        return min(itemCount - 1, max(0, Int(round(max(0, offset) / stride))))
    }
}

/// 让横排滚到某处的一次性请求（再点一次当前分页）；`serial` 变化才执行，同一请求重复传入不再动。
struct NativeVideoShelfScrollCommand: Equatable {
    enum Target: Equatable {
        /// 锚点卡片；没有锚点时回到起点。
        case anchor
        case leading
    }

    let serial: Int
    let target: Target
}

/// 把横排挂进 SwiftUI：coordinator 拥有集合视图与滚动视图，`dismantleNSView` 时 `reset()`。
///
/// `contentIdentity` 变化时即使卡片 ID 相同也整体替换内容：旧卡片的在途封面请求作废，横排回到起点。
struct NativeVideoShelfView: NSViewRepresentable {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled

    let contentIdentity: String
    let items: [NativeVideoCardPresentation]
    /// 横排在读屏里的名字：这一排是哪个分页。
    let accessibilityLabel: String
    let imagePipeline: any NativeVideoImageLoading
    let onSelect: (String) -> Void
    /// 卡片菜单，与网格同一份描述（`NativeVideoCardMenu`）；横排被遮挡（交互关闭）时不弹。
    let cardMenu: (NativeVideoCardPresentation) -> NativeVideoCardMenu?
    /// 需要停靠的卡片（合集里正在播放的一集）。
    ///
    /// 换内容时直接定位；同一内容里锚点变化时，只在新锚点不完整可见、
    /// 且用户没动过横排时平滑跟过去：点了眼前的下一张、或连播到旁边那张时横排不动。
    var anchorID: String? = nil
    var scrollCommand: NativeVideoShelfScrollCommand? = nil
    /// 新建时淡入（切分页换上这一排）；只在建立时读一次，之后改它不起作用。
    var fadesInOnCreation = false

    func makeCoordinator() -> Coordinator {
        Coordinator(
            contentIdentity: contentIdentity,
            items: items,
            anchorID: anchorID,
            scrollCommand: scrollCommand,
            fadesInOnCreation: fadesInOnCreation,
            accessibilityLabel: accessibilityLabel,
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
            anchorID: anchorID,
            scrollCommand: scrollCommand,
            accessibilityLabel: accessibilityLabel,
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
        private var contents: NativeCardContents<NativeVideoCardPresentation>
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
        private var anchorID: String?
        /// 上次停靠后用户是否自己滚动或翻页过；动过就不再把横排拉回正在播放的一集，换内容时清零。
        private var userMovedSinceAnchor = false
        /// 视口还没有宽度时推迟的停靠，等第一次视口布局再做。
        private var pendingAnchorScroll = false
        /// 已执行过的滚动请求；建立时传入的请求视为已执行，不在打开横排时滚动。
        private var handledScrollCommandSerial: Int?
        /// 还没淡入：建立时透明，等定位完成（含推迟到第一次视口布局的停靠）再淡入，淡入过程中卡片不会再移动。
        private var needsReveal = false
        private var accessibilityLabel: String
        /// 切分页时新一排的淡入时长：短到不拖慢切换，够盖住封面逐张出现。
        ///
        /// 淡入只改 AppKit 视图自己的透明度，
        /// 不用 SwiftUI 过渡：后者会给横排套一层不传递安全区的容器，前缘边距归零、整排跳动。
        private static let revealDuration: TimeInterval = 0.15

        init(
            contentIdentity: String,
            items: [NativeVideoCardPresentation],
            anchorID: String?,
            scrollCommand: NativeVideoShelfScrollCommand?,
            fadesInOnCreation: Bool,
            accessibilityLabel: String,
            imagePipeline: any NativeVideoImageLoading,
            reduceMotion: Bool,
            isInteractionEnabled: Bool,
            onSelect: @escaping (String) -> Void,
            cardMenu: @escaping (NativeVideoCardPresentation) -> NativeVideoCardMenu?
        ) {
            self.contentIdentity = contentIdentity
            contents = NativeCardContents(items)
            self.anchorID = anchorID
            handledScrollCommandSerial = scrollCommand?.serial
            // 减弱动态效果时直接出现，与翻页动画的处理一致。
            needsReveal = fadesInOnCreation && !reduceMotion
            self.accessibilityLabel = accessibilityLabel
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
            collectionView.onKeyboardMove = { [weak self] in self?.userMovedSinceAnchor = true }
            collectionView.onFocusChange = { [weak scrollView] in
                scrollView?.updateFocusWithinSoon()
            }
            collectionView.register(
                NativeVideoCollectionItem.self,
                forItemWithIdentifier: .nativeVideoCard
            )
            collectionView.setAccessibilityLabel(accessibilityLabel)

            dataSource = NativeCardDataSource<NativeVideoCollectionItem>.make(
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
            if needsReveal { scrollView.alphaValue = 0 }
            applyInteractionState(isInteractionEnabled, reconfiguresCards: false)
            scrollView.onViewportLayout = { [weak self] in
                self?.viewportDidLayout()
            }
            scrollView.onPageBackward = { [weak self] in self?.page(by: -1) }
            scrollView.onPageForward = { [weak self] in self?.page(by: 1) }
            scrollView.onUserScroll = { [weak self] in self?.userMovedSinceAnchor = true }
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
                self.scrollToAnchorOrLeading(animated: false)
                self.revealIfReady()
                self.updateHoverForCurrentPointerLocation()
            }
            return scrollView
        }

        func update(
            contentIdentity: String,
            items: [NativeVideoCardPresentation],
            anchorID: String?,
            scrollCommand: NativeVideoShelfScrollCommand?,
            accessibilityLabel: String,
            reduceMotion: Bool,
            isInteractionEnabled: Bool,
            onSelect: @escaping (String) -> Void,
            cardMenu: @escaping (NativeVideoCardPresentation) -> NativeVideoCardMenu?
        ) {
            guard !isReset else { return }
            if self.accessibilityLabel != accessibilityLabel {
                self.accessibilityLabel = accessibilityLabel
                collectionView.setAccessibilityLabel(accessibilityLabel)
            }
            self.reduceMotion = reduceMotion
            self.onSelect = onSelect
            self.cardMenu = cardMenu
            applyInteractionState(isInteractionEnabled, reconfiguresCards: true)
            let updatedContents = NativeCardContents(items)
            let plan = NativeVideoGridUpdatePlan(
                previousIDs: contents.orderedIDs,
                previousContents: contents.byID,
                updatedIDs: updatedContents.orderedIDs,
                updatedContents: updatedContents.byID
            )
            let resetsToLeading = self.contentIdentity != contentIdentity
            self.contentIdentity = contentIdentity
            contents = updatedContents
            let previousAnchorID = self.anchorID
            let anchorChanged = previousAnchorID != anchorID
            // 用户动过横排、但上一集的卡片仍在视野里，算没有离开，照常跟到新的一集。
            if resetsToLeading || (anchorChanged && isCardVisible(previousAnchorID)) {
                userMovedSinceAnchor = false
            }
            self.anchorID = anchorID
            // 同一内容里锚点暂时消失（换集途中认不出当前一集）时不动，避免先跳回第 1 集再滑回来；新锚点已经
            // 整张在视野里时也不动，点眼前的卡片不该让整排滑走。
            let followsAnchor =
                !resetsToLeading && anchorChanged && anchorID != nil && !userMovedSinceAnchor
                && !isCardFullyVisible(anchorID)

            // 换了父视频（内容身份变化）时即使 ID 序列相同也按替换处理：作废在途交互与图片请求、回到起点并重配
            // 可见卡片。
            if resetsToLeading || plan.identityChanged {
                operationGeneration &+= 1
                let generation = operationGeneration
                if resetsToLeading {
                    invalidateInteractionAndImageRequestsForContentReplacement()
                } else if !plan.changedExistingIDs.isEmpty {
                    // 同一内容里换位置的卡片（「刚才看过」里正在播放的那张移到最前）先换上新的文字再移动，
                    // 不然移动动画里带着旧的「正在播放」，结束后才换过来。可见卡片按 ID 对应，与位置无关。
                    reconfigureVisibleCards(ids: plan.changedExistingIDs)
                }
                applySnapshot(animatingDifferences: !resetsToLeading) { [weak self] in
                    guard
                        let self,
                        !self.isReset,
                        self.operationGeneration == generation
                    else { return }
                    self.resizeDocument(invalidateLayout: true)
                    if resetsToLeading {
                        self.scrollToAnchorOrLeading(animated: false)
                    } else if followsAnchor {
                        self.scrollToAnchorOrLeading(animated: !self.reduceMotion)
                    }
                    // 这次快照作废了建立时那次快照的完成回调（代次已变），淡入改在这里接上。
                    self.revealIfReady()
                    self.reconfigureVisibleCards()
                    self.updateHoverForCurrentPointerLocation()
                }
            } else {
                if !plan.changedExistingIDs.isEmpty {
                    reconfigureVisibleCards(ids: plan.changedExistingIDs)
                }
                if followsAnchor { scrollToAnchorOrLeading(animated: !reduceMotion) }
            }
            if let scrollCommand, scrollCommand.serial != handledScrollCommandSerial {
                handledScrollCommandSerial = scrollCommand.serial
                perform(scrollCommand.target)
            }
        }

        /// 用户明确要求的滚动，用翻页同一份动画：回到当前一集之后重新跟随它；回到开头算用户自己挪开，连播不再拉回去。
        private func perform(_ target: NativeVideoShelfScrollCommand.Target) {
            switch target {
            case .anchor:
                userMovedSinceAnchor = false
                scrollToAnchorOrLeading(animated: !reduceMotion)
            case .leading:
                userMovedSinceAnchor = true
                applyLogicalScrollOffset(0, animated: !reduceMotion)
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
            collectionView.onKeyboardMove = nil
            collectionView.onFocusChange = nil
            collectionView.delegate = nil
            collectionView.dataSource = nil
            dataSource = nil
            scrollView.reset()
            contents = NativeCardContents()
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
            let visibleCards = contents.visibleCards(
                of: NativeVideoCollectionItem.self,
                in: collectionView,
                ids: ids
            )
            for (item, presentation) in visibleCards {
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
            if pendingAnchorScroll {
                scrollToAnchorOrLeading(animated: false)
                revealIfReady()
                updateHoverForCurrentPointerLocation()
                return
            }
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
            userMovedSinceAnchor = true
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

        /// 卡片是否整张或部分落在当前视口里；ID 为 nil 或不在内容里时为 false。
        private func isCardVisible(_ id: String?) -> Bool {
            guard let span = visibleSpan(of: id) else { return false }
            return span.end > span.visibleStart && span.start < span.visibleEnd
        }

        /// 卡片是否整张落在当前视口里；ID 为 nil 或不在内容里时为 false。
        private func isCardFullyVisible(_ id: String?) -> Bool {
            guard let span = visibleSpan(of: id) else { return false }
            return span.start >= span.visibleStart && span.end <= span.visibleEnd
        }

        /// 卡片在逻辑坐标里的起止，和视口的起止（视口扣掉两侧内容边距，与翻页的“完整卡片”同一口径）。
        private func visibleSpan(
            of id: String?
        ) -> (start: CGFloat, end: CGFloat, visibleStart: CGFloat, visibleEnd: CGFloat)? {
            guard let id, let index = contents.orderedIDs.firstIndex(of: id) else { return nil }
            let start = NativeVideoShelfGeometry.offset(for: index)
            let visibleStart = currentLogicalOffsetX
            let visibleWidth =
                scrollView.contentSize.width - VideoCardShelfGeometry.contentInset * 2
            return (
                start,
                start + VideoCardShelfGeometry.cardWidth,
                visibleStart,
                visibleStart + visibleWidth
            )
        }

        private func revealIfReady() {
            guard needsReveal, !pendingAnchorScroll, !isReset else { return }
            needsReveal = false
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Self.revealDuration
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                scrollView.animator().alphaValue = 1
            }
        }

        /// 停到锚点卡片；没有锚点或锚点不在内容里时回到起点。
        ///
        /// 视口还没有宽度（尚未布局）时推迟到第一次视口布局；窄于一张卡片的视口照常停靠，偏移按可滚范围收住。
        private func scrollToAnchorOrLeading(animated: Bool) {
            guard let anchorID, let index = contents.orderedIDs.firstIndex(of: anchorID) else {
                pendingAnchorScroll = false
                scrollToLeading()
                return
            }
            guard scrollView.contentSize.width > 0 else {
                pendingAnchorScroll = true
                return
            }
            pendingAnchorScroll = false
            applyLogicalScrollOffset(
                NativeVideoShelfGeometry.anchorOffset(for: index),
                animated: animated
            )
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
            collectionView.cardDidEndDisplaying(item, hover: hover)
        }
    }
}
