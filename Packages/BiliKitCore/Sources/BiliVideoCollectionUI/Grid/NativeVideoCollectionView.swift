import AppKit
import BiliUI

/// 网格的集合视图：扩大预备区域，处理点击激活、按列数移动的键盘选择，以及选中卡片按 ⌘⌫ 执行的菜单项。
///
/// 只由 `NativeGridView` 创建，各种卡片共用；用 AppKit 的理由见 ARCHITECTURE「原生 AppKit 集合视图」。
@MainActor
final class NativeVideoCollectionView: NativeVideoCardCollectionView {
    /// 所在网格的几何；上下方向键按它的列数移动，与组合布局的每行张数同源。
    private let geometry: CardGridGeometry

    init(geometry: CardGridGeometry) {
        self.geometry = geometry
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 首行上方的附加视图（由 `NativeVideoGridDecorationHost` 设置）；读屏时排在卡片之前。
    var leadingAccessoryView: NSView?

    override func accessibilityChildren() -> [Any]? {
        let children = super.accessibilityChildren() ?? []
        guard let leadingAccessoryView else { return children }
        // 宿主视图本身是被读屏忽略的容器，交出它没被忽略的后代（名字、签名、关注按钮）。
        let accessoryChildren = NSAccessibility.unignoredChildren(from: [leadingAccessoryView])
        return accessoryChildren + children.filter { ($0 as? NSView) !== leadingAccessoryView }
    }

    /// AppKit 默认只准备视野内的卡片，封面要等卡片露出来才开始加载；这里上下各多准备一屏。
    ///
    /// 因此 `indexPathsForVisibleItems()` 也包含视野外已准备的卡片；需要视野首卡时用 `firstVisibleItem()`。
    override func prepareContent(in rect: NSRect) {
        guard !visibleRect.isEmpty else {
            super.prepareContent(in: rect)
            return
        }
        super.prepareContent(
            in: CardGridGeometry.preparedContentRect(visible: visibleRect, bounds: bounds)
        )
    }

    /// 视野首卡：与视野相交的最上一行里序号最小的卡片，网格的滚动锚点与键盘选择的起点都取它。
    ///
    /// 直接问排版视野里有哪些卡片，不看已准备的卡片：跳转后的视野可能还没有准备好的卡片。
    func firstVisibleItem() -> NSCollectionViewLayoutAttributes? {
        collectionViewLayout?.layoutAttributesForElements(in: visibleRect)
            .filter { $0.representedElementCategory == .item && $0.indexPath != nil }
            .min {
                ($0.frame.minY, $0.indexPath?.item ?? 0) < ($1.frame.minY, $1.indexPath?.item ?? 0)
            }
    }

    func refreshPreparedContentIfNeeded() {
        guard
            window != nil,
            CardGridGeometry.needsPreparedContentRefresh(
                prepared: preparedContentRect,
                visible: visibleRect,
                bounds: bounds
            )
        else { return }
        prepareContent(in: visibleRect)
    }

    override func mouseDown(with event: NSEvent) {
        guard !routesControlClickToContextMenu(event) else { return }
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
        // 焦点在首行上方的附加视图里（例如关注按钮）时，它没处理的按键会沿响应链冒到这里：不当成卡片的激活与选择移动，
        // 继续往上交。
        if let leadingAccessoryView,
            let responder = window?.firstResponder as? NSView,
            responder.isDescendant(of: leadingAccessoryView)
        {
            nextResponder?.keyDown(with: event)
            return
        }
        // ⌘⌫ 执行选中卡片菜单里带这个快捷键的项（稍后再看页的「从稍后再看移除」），与右键菜单、读屏操作同一份描述；
        // 每次按键重新取描述，项禁用或卡片没有这一项时交给系统（发出提示音）。
        if NativeVideoCollectionKeys.isCommandDelete(event),
            let indexPath = selectionIndexPaths.first,
            let id = item(at: indexPath)?.representedObject as? String,
            let item = cardMenu?(id)?.enabledItem(for: .commandDelete)
        {
            item.action()
            return
        }
        if NativeVideoCollectionKeys.isActivation(event),
            let indexPath = selectionIndexPaths.first,
            let id = item(at: indexPath)?.representedObject as? String
        {
            onActivateSelection?(id)
            return
        }
        if let delta = NativeVideoCollectionKeys.selectionDelta(
            for: event,
            rowLength: geometry.columnCount(for: bounds.width)
        ), numberOfItems(inSection: 0) > 0 {
            let visibleStart = firstVisibleItem()?.indexPath?.item ?? 0
            let current = selectionIndexPaths.first?.item ?? visibleStart
            selectWithKeyboard(itemAt: current + delta, scrollPosition: .nearestVerticalEdge)
            return
        }
        super.keyDown(with: event)
    }
}
