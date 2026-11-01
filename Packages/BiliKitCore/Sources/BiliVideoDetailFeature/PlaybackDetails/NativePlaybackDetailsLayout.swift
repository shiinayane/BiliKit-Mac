import AppKit
import BiliApplication

/// 详情区的单列布局：按条目顺序纵向排列，行高由控制器经 `heightProvider` 提供（带缓存的精确测量）。
///
/// 能增量就增量：宽度不变时只重测被失效的行，或只排新追加的行（含插在稳定页脚之前的评论）；宽度变化时先按
/// 宽度比例估算全部行高、立即可用，再由控制器分批精测（`refineNextBatch`）；其余变化整体重排。拥有已排好的
/// 属性与待精测集合，不拥有条目数据与测量（交给控制器）。
///
/// 不用 flow／compositional layout：它们在追加或改宽度时按自己的规则重算各行，做不到“只重测失效的行”与“先估算、
/// 再分批精测并在批间恢复语义锚点”，长评论列表改宽度时会一次重测全部行。
@MainActor
final class NativePlaybackDetailsLayout: NSCollectionViewLayout {
    static let contentInset: CGFloat = 16
    static let itemSpacing: CGFloat = 16
    /// resize 后每批精测的行数；批间让出主线程并恢复语义 anchor。
    static let refinementBatchSize = 32

    /// 一个条目在布局里的位置与身份；身份用来跨更新找到同一行（失效、优先精测）。
    struct Entry: Equatable {
        let indexPath: IndexPath
        let itemID: NativePlaybackDetailsItemID
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
        invalidating itemIDs: Set<NativePlaybackDetailsItemID> = []
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
        prioritizing itemID: NativePlaybackDetailsItemID?
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
        indexes.sort()
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
        return abs(itemWidth - preparedItemWidth) > 0.5
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
struct NativePlaybackDetailsHeightCacheKey: Hashable {
    let itemID: NativePlaybackDetailsItemID
    let widthBucket: Int
    let revision: Int
}

extension CostBoundedLRUCacheLimits {
    /// 详情区行高缓存：每条行高的成本记 1，总成本上限即条目上限 2048（identity × 宽度桶 × 内容 revision）。
    ///
    /// 调小则改宽度、滚回或回到旧宽度时更常重新测量；调大只多占少量内存（每项一个 key 与一个 CGFloat）。
    static let sidebarRowHeights = CostBoundedLRUCacheLimits(
        maximumItemCost: 1,
        maximumTotalCost: 2_048
    )
}

/// 详情区文字的测量与段落样式：测量与显示共用同一段落样式（按字符换行，限行时尾部截断），保证测出的高度与
/// 显示一致。
@MainActor
enum NativePlaybackDetailsTextLayout {
    private static let measurer = NativePlaybackDetailsTextMeasurer()

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
private final class NativePlaybackDetailsTextMeasurer {
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
                    .paragraphStyle: NativePlaybackDetailsTextLayout.paragraphStyle(
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
