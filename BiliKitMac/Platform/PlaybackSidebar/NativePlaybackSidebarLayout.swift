import AppKit

@MainActor
final class NativePlaybackSidebarLayout: NSCollectionViewLayout {
    static let contentInset: CGFloat = 16
    static let itemSpacing: CGFloat = 16

    struct Entry: Equatable {
        let indexPath: IndexPath
        let itemID: NativePlaybackSidebarItemID
    }

    private var entries: [Entry] = []
    private var heights: [NativePlaybackSidebarItemID: CGFloat] = [:]
    private var attributes: [NSCollectionViewLayoutAttributes] = []
    private var attributesByIndexPath: [IndexPath: NSCollectionViewLayoutAttributes] = [:]
    private var contentSize = NSSize.zero
    private var preparedWidth: CGFloat = 0
    private var needsRebuild = true

    func update(
        entries: [Entry],
        heights: [NativePlaybackSidebarItemID: CGFloat]
    ) {
        self.entries = entries
        self.heights = heights
        needsRebuild = true
        invalidateLayout()
    }

    override func prepare() {
        super.prepare()
        guard let collectionView else { return }
        let width = max(1, collectionView.bounds.width)
        guard needsRebuild || abs(width - preparedWidth) > 0.5 else { return }

        let itemWidth = max(1, width - Self.contentInset * 2)
        var y = Self.contentInset
        attributes = entries.map { entry in
            let itemAttributes = NSCollectionViewLayoutAttributes(
                forItemWith: entry.indexPath
            )
            let height = max(1, ceil(heights[entry.itemID] ?? 1))
            itemAttributes.frame = NSRect(
                x: Self.contentInset,
                y: y,
                width: itemWidth,
                height: height
            )
            y += height + Self.itemSpacing
            return itemAttributes
        }
        attributesByIndexPath = Dictionary(
            uniqueKeysWithValues: zip(entries, attributes).map {
                ($0.indexPath, $1)
            }
        )
        if !attributes.isEmpty {
            y -= Self.itemSpacing
        }
        y += Self.contentInset
        contentSize = NSSize(width: width, height: max(1, y))
        preparedWidth = width
        needsRebuild = false
    }

    override var collectionViewContentSize: NSSize {
        contentSize
    }

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
        abs(newBounds.width - preparedWidth) > 0.5
    }
}

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
                    ),
                ]
            )
        )
        manager.ensureLayout(for: container)
        return ceil(manager.usedRect(for: container).height)
    }
}
