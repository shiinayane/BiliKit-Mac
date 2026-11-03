import AppKit
import Testing

@testable import BiliVideoCollectionUI

/// 集合项的尺寸只由布局给出：集合视图排可见项时不向条目视图要自报尺寸（那会为整棵视图临时建 Auto Layout 引擎）。
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct NativeLayoutSizedCollectionItemTests {
    @Test
    func collectionViewNeverAsksTheItemViewToMeasureItself() {
        // 对照组证明这个场景里 AppKit 确实会向条目视图要尺寸，否则 0 次说明不了什么。
        #expect(Self.fittingRequests(itemClass: PlainProbeItem.self) > 0)
        #expect(Self.fittingRequests(itemClass: LayoutSizedProbeItem.self) == 0)
    }

    /// 把 20 个探针条目放进带固定尺寸自定义布局的真实集合视图，排版并滚动，返回条目视图被要求自报尺寸的总次数。
    private static func fittingRequests(itemClass: NSCollectionViewItem.Type) -> Int {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 300),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 300))
        let collectionView = NSCollectionView(frame: NSRect(x: 0, y: 0, width: 300, height: 1_000))
        let dataSource = ProbeDataSource()
        collectionView.collectionViewLayout = FixedRowLayout()
        collectionView.register(itemClass, forItemWithIdentifier: ProbeDataSource.identifier)
        collectionView.dataSource = dataSource
        scrollView.documentView = collectionView
        window.contentView = scrollView
        defer { window.contentView = nil }

        collectionView.reloadData()
        collectionView.layoutSubtreeIfNeeded()
        for offset in stride(from: 0, through: 600, by: 100) {
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: offset))
            collectionView.layoutSubtreeIfNeeded()
        }
        return dataSource.items.reduce(0) { total, item in
            total + ((item.view as? FittingProbeView)?.fittingRequests ?? 0)
        }
    }
}

/// 记下集合视图向它要自报尺寸的次数。
///
/// `preferredLayoutAttributesFitting(_:)` 在 NSView 上是 Objective-C 分类方法，没有暴露给 Swift，只能按选择子实现。
private final class FittingProbeView: NSView {
    private(set) var fittingRequests = 0

    @objc(preferredLayoutAttributesFittingAttributes:)
    func recordFitting(
        _ layoutAttributes: NSCollectionViewLayoutAttributes
    ) -> NSCollectionViewLayoutAttributes {
        fittingRequests += 1
        return layoutAttributes
    }
}

private final class PlainProbeItem: NSCollectionViewItem {
    override func loadView() { view = FittingProbeView() }
}

private final class LayoutSizedProbeItem: NativeLayoutSizedCollectionItem {
    override func loadView() { view = FittingProbeView() }
}

private final class ProbeDataSource: NSObject, NSCollectionViewDataSource {
    static let identifier = NSUserInterfaceItemIdentifier("probe")
    private(set) var items: [NSCollectionViewItem] = []

    func collectionView(
        _ collectionView: NSCollectionView,
        numberOfItemsInSection section: Int
    ) -> Int {
        20
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        itemForRepresentedObjectAt indexPath: IndexPath
    ) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: Self.identifier, for: indexPath)
        items.append(item)
        return item
    }
}

/// 每行 300×50 的固定尺寸自定义布局，与仓库里自己给尺寸的布局一样不采纳自报尺寸。
private final class FixedRowLayout: NSCollectionViewLayout {
    private var attributes: [NSCollectionViewLayoutAttributes] = []

    override func prepare() {
        attributes = (0..<20).map { index in
            let item = NSCollectionViewLayoutAttributes(
                forItemWith: IndexPath(item: index, section: 0)
            )
            item.frame = NSRect(x: 0, y: CGFloat(index) * 50, width: 300, height: 50)
            return item
        }
    }

    override var collectionViewContentSize: NSSize { NSSize(width: 300, height: 1_000) }

    override func layoutAttributesForElements(in rect: NSRect) -> [NSCollectionViewLayoutAttributes]
    {
        attributes.filter { $0.frame.intersects(rect) }
    }

    override func layoutAttributesForItem(
        at indexPath: IndexPath
    ) -> NSCollectionViewLayoutAttributes? {
        attributes[indexPath.item]
    }
}
