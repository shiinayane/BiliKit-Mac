import AppKit
import BiliApplication
import BiliVideoCollectionUI

/// 侧栏的单列布局：按条目顺序纵向排列，行高由控制器经 `heightProvider` 提供（带缓存的精确测量）。
///
/// 能增量就增量：宽度不变时只重测被失效的行，或只排新追加的行（含插在稳定页脚之前的评论）；宽度变化时先按
/// 宽度比例估算全部行高、立即可用，再由控制器精测：可见的行当场精测（`refinePendingItems(intersecting:)`），
/// 其余等宽度稳定后分批精测（`refineNextBatch`）；其余变化整体重排。拥有已排好的属性与待精测集合，不拥有条目
/// 数据与测量（交给控制器）。
///
/// 不用 flow／compositional layout：它们在追加或改宽度时按自己的规则重算各行，做不到“只重测失效的行”与“先估算、
/// 再分批精测并在批间恢复语义锚点”，长评论列表改宽度时会一次重测全部行。
@MainActor
final class NativePlaybackSidebarLayout: NSCollectionViewLayout {
    static let contentInset: CGFloat = 16
    static let itemSpacing: CGFloat = 16
    /// resize 后每批精测的行数；批间让出主线程并恢复语义 anchor。
    static let refinementBatchSize = 32
    /// 宽度停止变化这么久之后，才分批精测视野外的行。
    ///
    /// 拖分隔条或缩放窗口时宽度每帧都在变，每次变化都让已精测的行高作废；不等它稳定就开始分批精测，每帧都会白测
    /// 一整批（1.6.1 的 Time Profiler 里拖动期间主线程八成以上被占满，约三成是这些作废的精测）。调短会在拖动的停顿
    /// 间隙里白测，调长则松手后视野外的行更晚才是准确高度（视野内的行不受影响，改宽度当场精测）。
    static let refinementSettleDelay: Duration = .milliseconds(200)

    /// 一个条目在布局里的位置与身份；身份用来跨更新找到同一行（失效、优先精测）。
    struct Entry: Equatable {
        let indexPath: IndexPath
        let itemID: NativePlaybackSidebarItemID
    }

    var heightProvider: ((Entry, CGFloat) -> CGFloat)?
    private var entries: [Entry] = []
    private var preparedEntries: [Entry] = []
    private var preparedItemWidth: CGFloat?
    private var invalidatedIndexes = IndexSet()
    private(set) var pendingRefinementIndexes = IndexSet()
    private var attributes: [NSCollectionViewLayoutAttributes] = []
    private var attributesByIndexPath: [IndexPath: NSCollectionViewLayoutAttributes] = [:]
    private var contentSize = NSSize.zero

    func update(
        entries: [Entry],
        invalidating itemIDs: Set<NativePlaybackSidebarItemID> = []
    ) {
        self.entries = entries
        let preparedIndexes = Dictionary(
            uniqueKeysWithValues: preparedEntries.enumerated().map {
                ($0.element.itemID, $0.offset)
            }
        )
        for itemID in itemIDs {
            if let preparedIndex = preparedIndexes[itemID] {
                invalidatedIndexes.insert(preparedIndex)
            }
        }
        invalidateLayout()
    }

    override func prepare() {
        super.prepare()
        guard let collectionView else { return }
        let viewportWidth = max(1, collectionView.bounds.width)
        let itemWidth = max(1, viewportWidth - Self.contentInset * 2)
        let widthIsUnchanged =
            preparedItemWidth.map { abs($0 - itemWidth) <= 0.5 } ?? false

        if !widthIsUnchanged,
            preparedEntries == entries,
            attributes.count == entries.count,
            let previousWidth = preparedItemWidth
        {
            rebuildEstimated(
                viewportWidth: viewportWidth,
                itemWidth: itemWidth,
                previousItemWidth: previousWidth
            )
            return
        }

        if widthIsUnchanged,
            preparedEntries == entries,
            !invalidatedIndexes.isEmpty
        {
            updateInvalidatedItems(itemWidth: itemWidth)
            return
        }

        let stableTailIndex = preparedEntries.indices.last
        let invalidatesOnlyStableTail =
            invalidatedIndexes.isEmpty
            || stableTailIndex.map {
                invalidatedIndexes == IndexSet(integer: $0)
            } == true

        if widthIsUnchanged,
            invalidatesOnlyStableTail,
            preparedEntries.count >= 1,
            preparedEntries.count < entries.count,
            Array(entries.prefix(preparedEntries.count - 1))
                == Array(preparedEntries.dropLast()),
            entries.last?.itemID == preparedEntries.last?.itemID
        {
            appendItemsBeforeStableTail(
                from: preparedEntries.count - 1,
                itemWidth: itemWidth,
                viewportWidth: viewportWidth
            )
            preparedEntries = entries
            rebuildIndexPathLookup()
            return
        }

        if widthIsUnchanged,
            invalidatedIndexes.isEmpty,
            preparedEntries.count < entries.count,
            Array(entries.prefix(preparedEntries.count)) == preparedEntries
        {
            appendItems(
                from: preparedEntries.count,
                itemWidth: itemWidth,
                viewportWidth: viewportWidth
            )
            preparedEntries = entries
            rebuildIndexPathLookup()
            return
        }

        if widthIsUnchanged,
            invalidatedIndexes.isEmpty,
            preparedEntries == entries
        {
            return
        }

        rebuild(
            viewportWidth: viewportWidth,
            itemWidth: itemWidth
        )
    }

    @discardableResult
    func refineNextBatch(
        maximumCount: Int,
        prioritizing itemID: NativePlaybackSidebarItemID?
    ) -> Bool {
        guard maximumCount > 0, let itemWidth = preparedItemWidth else {
            return false
        }
        var indexes: [Int] = []
        indexes.reserveCapacity(maximumCount)
        if let itemID,
            let priorityIndex = preparedEntries.firstIndex(where: {
                $0.itemID == itemID
            }),
            pendingRefinementIndexes.contains(priorityIndex)
        {
            let priorityRange =
                priorityIndex..<min(attributes.count, priorityIndex + maximumCount)
            indexes.append(
                contentsOf: pendingRefinementIndexes.intersection(
                    IndexSet(integersIn: priorityRange)
                )
            )
        }
        var candidate = pendingRefinementIndexes.first
        while let index = candidate, indexes.count < maximumCount {
            if !indexes.contains(index) { indexes.append(index) }
            candidate = pendingRefinementIndexes.integerGreaterThan(index)
        }
        return refine(indexes, itemWidth: itemWidth)
    }

    /// 精测所有与 `rect` 相交的待精测行；没有这样的行时返回 false。
    ///
    /// 精测后下方的行会移位，原本在 `rect` 外的估算行可能移进来；调用方恢复锚点后再调一次，直到返回 false。
    @discardableResult
    func refinePendingItems(intersecting rect: NSRect) -> Bool {
        guard let itemWidth = preparedItemWidth else { return false }
        let indexes = pendingRefinementIndexes.filter {
            attributes.indices.contains($0) && attributes[$0].frame.intersects(rect)
        }
        return refine(indexes, itemWidth: itemWidth)
    }

    private func refine(_ indexes: [Int], itemWidth: CGFloat) -> Bool {
        let indexes = indexes.sorted()
        guard let firstIndex = indexes.first else { return false }
        for index in indexes where attributes.indices.contains(index) {
            attributes[index].frame.size.height = measuredHeight(
                at: index,
                itemWidth: itemWidth
            )
            pendingRefinementIndexes.remove(index)
        }
        repositionSuffix(from: firstIndex)
        rebuildIndexPathLookup()
        invalidateLayout()
        return true
    }

    override var collectionViewContentSize: NSSize { contentSize }

    override func layoutAttributesForElements(
        in rect: NSRect
    ) -> [NSCollectionViewLayoutAttributes] {
        attributes.filter { $0.frame.intersects(rect) }
    }

    override func layoutAttributesForItem(
        at indexPath: IndexPath
    ) -> NSCollectionViewLayoutAttributes? {
        attributesByIndexPath[indexPath]
    }

    override func shouldInvalidateLayout(
        forBoundsChange newBounds: NSRect
    ) -> Bool {
        guard let preparedItemWidth else { return true }
        let itemWidth = max(1, newBounds.width - Self.contentInset * 2)
        return NativeViewportSize.differs(itemWidth, preparedItemWidth)
    }

    private func rebuild(viewportWidth: CGFloat, itemWidth: CGFloat) {
        var y = Self.contentInset
        attributes = entries.indices.map { index in
            let entry = entries[index]
            let itemAttributes = NSCollectionViewLayoutAttributes(
                forItemWith: entry.indexPath
            )
            let height = measuredHeight(at: index, itemWidth: itemWidth)
            itemAttributes.frame = NSRect(
                x: Self.contentInset,
                y: y,
                width: itemWidth,
                height: height
            )
            y += height + Self.itemSpacing
            return itemAttributes
        }
        finishContentSize(y: y, viewportWidth: viewportWidth)
        preparedEntries = entries
        preparedItemWidth = itemWidth
        invalidatedIndexes.removeAll()
        pendingRefinementIndexes.removeAll()
        rebuildIndexPathLookup()
    }

    private func rebuildEstimated(
        viewportWidth: CGFloat,
        itemWidth: CGFloat,
        previousItemWidth: CGFloat
    ) {
        let ratio = previousItemWidth / itemWidth
        var y = Self.contentInset
        for index in attributes.indices {
            let previousHeight = attributes[index].frame.height
            let estimatedHeight = max(1, ceil(previousHeight * ratio))
            attributes[index].frame = NSRect(
                x: Self.contentInset,
                y: y,
                width: itemWidth,
                height: estimatedHeight
            )
            y += estimatedHeight + Self.itemSpacing
        }
        finishContentSize(y: y, viewportWidth: viewportWidth)
        preparedItemWidth = itemWidth
        invalidatedIndexes.removeAll()
        pendingRefinementIndexes = IndexSet(integersIn: entries.indices)
        rebuildIndexPathLookup()
    }

    private func appendItems(
        from startIndex: Int,
        itemWidth: CGFloat,
        viewportWidth: CGFloat
    ) {
        var y =
            attributes.last.map { $0.frame.maxY + Self.itemSpacing }
            ?? Self.contentInset
        for index in startIndex..<entries.count {
            let entry = entries[index]
            let itemAttributes = NSCollectionViewLayoutAttributes(
                forItemWith: entry.indexPath
            )
            let height = measuredHeight(at: index, itemWidth: itemWidth)
            itemAttributes.frame = NSRect(
                x: Self.contentInset,
                y: y,
                width: itemWidth,
                height: height
            )
            attributes.append(itemAttributes)
            y += height + Self.itemSpacing
        }
        finishContentSize(y: y, viewportWidth: viewportWidth)
    }

    private func appendItemsBeforeStableTail(
        from insertionIndex: Int,
        itemWidth: CGFloat,
        viewportWidth: CGFloat
    ) {
        guard attributes.indices.contains(insertionIndex) else {
            rebuild(viewportWidth: viewportWidth, itemWidth: itemWidth)
            return
        }
        attributes.removeSubrange(insertionIndex...)
        pendingRefinementIndexes.remove(insertionIndex)
        invalidatedIndexes.removeAll()
        appendItems(
            from: insertionIndex,
            itemWidth: itemWidth,
            viewportWidth: viewportWidth
        )
    }

    private func updateInvalidatedItems(itemWidth: CGFloat) {
        guard let firstIndex = invalidatedIndexes.first else { return }
        for index in invalidatedIndexes where attributes.indices.contains(index) {
            attributes[index].frame.size.height = measuredHeight(
                at: index,
                itemWidth: itemWidth
            )
            pendingRefinementIndexes.remove(index)
        }
        repositionSuffix(from: firstIndex)
        invalidatedIndexes.removeAll()
        rebuildIndexPathLookup()
    }

    private func repositionSuffix(from startIndex: Int) {
        guard attributes.indices.contains(startIndex) else { return }
        var y =
            startIndex == 0
            ? Self.contentInset
            : attributes[startIndex - 1].frame.maxY + Self.itemSpacing
        for index in startIndex..<attributes.endIndex {
            attributes[index].frame.origin.y = y
            y += attributes[index].frame.height + Self.itemSpacing
        }
        finishContentSize(
            y: y,
            viewportWidth: collectionView?.bounds.width ?? contentSize.width
        )
    }

    private func measuredHeight(at index: Int, itemWidth: CGFloat) -> CGFloat {
        guard entries.indices.contains(index) else { return 1 }
        return max(1, ceil(heightProvider?(entries[index], itemWidth) ?? 1))
    }

    private func finishContentSize(y: CGFloat, viewportWidth: CGFloat) {
        var finalY = y
        if !attributes.isEmpty { finalY -= Self.itemSpacing }
        finalY += Self.contentInset
        contentSize = NSSize(
            width: viewportWidth,
            height: max(1, finalY)
        )
    }

    private func rebuildIndexPathLookup() {
        attributesByIndexPath = Dictionary(
            uniqueKeysWithValues: attributes.compactMap { attributes in
                attributes.indexPath.map { ($0, attributes) }
            }
        )
    }
}

/// 行高缓存的键：条目身份、宽度桶（半点精度）与内容 revision，任一变化都重新测量。
struct NativePlaybackSidebarHeightCacheKey: Hashable {
    let itemID: NativePlaybackSidebarItemID
    let widthBucket: Int
    let revision: Int
}

extension CostBoundedLRUCacheLimits {
    /// 侧栏行高缓存：每条行高的成本记 1，总成本上限即条目上限 2048（identity × 宽度桶 × 内容 revision）。
    ///
    /// 调小则改宽度、滚回或回到旧宽度时更常重新测量；调大只多占少量内存（每项一个 key 与一个 CGFloat）。
    static let sidebarRowHeights = CostBoundedLRUCacheLimits(
        maximumItemCost: 1,
        maximumTotalCost: 2_048
    )
}

/// 侧栏文字的测量与段落样式：测量与显示共用同一段落样式（按字符换行，限行时尾部截断），保证测出的高度与
/// 显示一致。
@MainActor
enum NativePlaybackSidebarTextLayout {
    private static let measurer = NativePlaybackSidebarTextMeasurer()

    static func height(
        _ text: String,
        width: CGFloat,
        font: NSFont,
        maximumLines: Int? = nil
    ) -> CGFloat {
        measurer.height(
            text,
            width: width,
            font: font,
            maximumLines: maximumLines
        )
    }

    static func height(
        _ attributedText: NSAttributedString,
        width: CGFloat
    ) -> CGFloat {
        measurer.height(attributedText, width: width)
    }

    static func singleLineWidth(_ text: String, font: NSFont) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }

    static var paragraphStyle: NSParagraphStyle {
        paragraphStyle(maximumLines: nil)
    }

    static func paragraphStyle(maximumLines: Int?) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = maximumLines == nil ? .byCharWrapping : .byTruncatingTail
        return style
    }
}

/// 复用同一套 TextKit 对象测量文字高度，不为每次测量新建；只在主线程使用。
@MainActor
private final class NativePlaybackSidebarTextMeasurer {
    private let storage = NSTextStorage()
    private let manager = NSLayoutManager()
    private let container = NSTextContainer(size: .zero)

    init() {
        storage.addLayoutManager(manager)
        manager.addTextContainer(container)
        container.lineFragmentPadding = 0
    }

    func height(
        _ text: String,
        width: CGFloat,
        font: NSFont,
        maximumLines: Int?
    ) -> CGFloat {
        guard !text.isEmpty else { return 0 }
        container.containerSize = NSSize(
            width: max(1, width),
            height: .greatestFiniteMagnitude
        )
        container.maximumNumberOfLines = maximumLines ?? 0
        container.lineBreakMode = maximumLines == nil ? .byCharWrapping : .byTruncatingTail
        storage.setAttributedString(
            NSAttributedString(
                string: text,
                attributes: [
                    .font: font,
                    .paragraphStyle: NativePlaybackSidebarTextLayout.paragraphStyle(
                        maximumLines: maximumLines
                    )
                ]
            )
        )
        manager.ensureLayout(for: container)
        return ceil(manager.usedRect(for: container).height)
    }

    func height(
        _ attributedText: NSAttributedString,
        width: CGFloat
    ) -> CGFloat {
        guard attributedText.length > 0 else { return 0 }
        container.containerSize = NSSize(
            width: max(1, width),
            height: .greatestFiniteMagnitude
        )
        container.maximumNumberOfLines = 0
        container.lineBreakMode = .byCharWrapping
        storage.setAttributedString(attributedText)
        manager.ensureLayout(for: container)
        return ceil(manager.usedRect(for: container).height)
    }
}
