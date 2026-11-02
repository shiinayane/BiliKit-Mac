import AppKit

/// 网格与 shelf 共用的卡片内容：去重、按 ID 查找与 diffable 快照。
///
/// 空 ID 与重复 ID 被丢弃，保留第一次出现的那张；值类型，由网格与 shelf 的 Coordinator 各自持有。
package struct NativeVideoCardContents: Sendable {
    static let section = 0

    package private(set) var byID: [String: NativeVideoCardPresentation]
    package private(set) var orderedIDs: [String]

    package init(_ items: [NativeVideoCardPresentation] = []) {
        var seen: Set<String> = []
        let uniqueItems = items.filter { !$0.id.isEmpty && seen.insert($0.id).inserted }
        byID = Dictionary(uniqueKeysWithValues: uniqueItems.map { ($0.id, $0) })
        orderedIDs = uniqueItems.map(\.id)
    }

    package subscript(id: String) -> NativeVideoCardPresentation? { byID[id] }

    package func indexPath(of id: String) -> IndexPath? {
        orderedIDs.firstIndex(of: id).map { IndexPath(item: $0, section: Self.section) }
    }

    /// 该 ID 的卡片存在且可进入播放；不在内容里的 ID 按不可激活处理。
    ///
    /// 网格与横排（VideoDetail 的相关推荐）的激活
    /// 入口都经它拦截，所以是 `package`。
    package func isActivatable(_ id: String) -> Bool {
        byID[id]?.isActivatable ?? false
    }

    /// 只保留可进入播放的卡片位置：网格据此拒绝鼠标选中与按下高亮不可用卡片。
    func activatableIndexPaths(in indexPaths: Set<IndexPath>) -> Set<IndexPath> {
        indexPaths.filter {
            $0.section == Self.section && orderedIDs.indices.contains($0.item)
                && isActivatable(orderedIDs[$0.item])
        }
    }

    package func makeSnapshot() -> NSDiffableDataSourceSnapshot<Int, String> {
        var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
        snapshot.appendSections([Self.section])
        snapshot.appendItems(orderedIDs, toSection: Self.section)
        return snapshot
    }

    /// 可见卡片及其当前内容；`ids` 为空表示全部可见卡片。
    @MainActor
    package func visibleCards(
        in collectionView: NSCollectionView,
        ids: Set<String>? = nil
    ) -> [(NativeVideoCollectionItem, NativeVideoCardPresentation)] {
        collectionView.visibleVideoCards.compactMap { item in
            guard
                let id = item.representedVideoID,
                ids?.contains(id) ?? true,
                let presentation = byID[id]
            else { return nil }
            return (item, presentation)
        }
    }
}

/// 网格与 shelf 共用的 diffable 数据源：按 ID 取卡片内容、配置复用的卡片并同步键盘选择框。
@MainActor
package enum NativeVideoCardDataSource {
    /// 调用方以 `[weak self]` 捕获 Coordinator，工厂本身不持有任何 owner。
    package static func make(
        collectionView: NSCollectionView,
        presentation: @escaping @MainActor (String) -> NativeVideoCardPresentation?,
        configure:
            @escaping @MainActor (NativeVideoCollectionItem, NativeVideoCardPresentation)
            -> Void,
        showsKeyboardSelection: @escaping @MainActor () -> Bool
    ) -> NSCollectionViewDiffableDataSource<Int, String> {
        NSCollectionViewDiffableDataSource<Int, String>(
            collectionView: collectionView
        ) { collectionView, indexPath, id in
            guard
                let presentation = presentation(id),
                let item = collectionView.makeItem(
                    withIdentifier: .nativeVideoCard,
                    for: indexPath
                ) as? NativeVideoCollectionItem
            else { return nil }
            configure(item, presentation)
            item.setKeyboardFocusVisible(
                showsKeyboardSelection()
                    && collectionView.selectionIndexPaths.contains(indexPath)
            )
            return item
        }
    }
}

/// 可被 `NativeVideoHoverTracker` 管理悬停外观的集合项（网格卡片、UP 主空间投稿行）。
@MainActor
package protocol NativeHoverableCollectionItem: NSCollectionViewItem {
    func setHovered(_ hovered: Bool)
    func clearHover()
    func invalidateImageRequests()
}

/// 指针悬停的唯一 owner：同一时刻最多一个集合项处于悬停外观。
///
/// 由使用悬停的集合视图 owner 持有（网格与 shelf 的 Coordinator、UP 主空间列表）；只弱引用悬停项，
/// 不拥有集合项本身。
@MainActor
package final class NativeVideoHoverTracker {
    private(set) weak var hoveredItem: (any NativeHoverableCollectionItem)?

    package init() {}

    /// 由 Coordinator 主动决定悬停目标（滚动、布局、窗口变化后）。
    package func setHoveredItem(_ item: (any NativeHoverableCollectionItem)?) {
        guard hoveredItem !== item else { return }
        let previous = hoveredItem
        hoveredItem = item
        previous?.setHovered(false)
        item?.setHovered(true)
    }

    /// 卡片自身的 tracking area 报告的悬停变化；卡片已自行更新外观，这里只撤销前一张。
    package func itemDidChangeHover(_ item: any NativeHoverableCollectionItem, isHovered: Bool) {
        if isHovered {
            guard hoveredItem !== item else { return }
            let previous = hoveredItem
            hoveredItem = item
            previous?.setHovered(false)
        } else if hoveredItem === item {
            hoveredItem = nil
        }
    }

    /// teardown 时只丢弃引用；卡片随后整体 invalidate，不需要单独撤销外观。
    package func forgetHoveredItem() {
        hoveredItem = nil
    }

    /// 以窗口当前指针位置重新选择悬停卡片；滚动不会产生 mouseEntered/Exited。
    package func updateForCurrentPointerLocation(in collectionView: NSCollectionView) {
        setHoveredItem(Self.itemUnderPointer(in: collectionView))
    }

    /// 离屏卡片可能立即被复用给其他视频，必须同时丢弃引用、图片请求与悬停外观。
    package func itemDidEndDisplaying(_ item: any NativeHoverableCollectionItem) {
        if hoveredItem === item { hoveredItem = nil }
        item.invalidateImageRequests()
        item.clearHover()
    }

    private static func itemUnderPointer(
        in collectionView: NSCollectionView
    ) -> (any NativeHoverableCollectionItem)? {
        guard let windowPoint = collectionView.window?.mouseLocationOutsideOfEventStream
        else { return nil }
        let collectionPoint = collectionView.convert(windowPoint, from: nil)
        guard
            collectionView.visibleRect.contains(collectionPoint),
            let indexPath = collectionView.indexPathForItem(at: collectionPoint)
        else { return nil }
        return collectionView.item(at: indexPath) as? any NativeHoverableCollectionItem
    }
}

/// 集合键盘导航使用的物理键码。
///
/// 保留 keyCode 判断而不改用 `specialKey`：后者会把小键盘 Enter 也当作激活键，改变现有行为。
package enum NativeVideoCollectionKeys {
    static let returnKey: UInt16 = 36
    static let leftArrow: UInt16 = 123
    static let rightArrow: UInt16 = 124
    static let downArrow: UInt16 = 125
    static let upArrow: UInt16 = 126
    static let deleteKey: UInt16 = 51
    static let space = " "

    /// ⌘⌫：只按住 Command（不含 Shift、Option、Control）时的删除键。
    package static func isCommandDelete(_ event: NSEvent) -> Bool {
        event.keyCode == deleteKey
            && event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command
    }

    package static func isActivation(_ event: NSEvent) -> Bool {
        event.keyCode == returnKey || event.charactersIgnoringModifiers == space
    }

    /// 方向键对应的选择位移；`rowLength` 为 nil 时不处理上下键。
    package static func selectionDelta(for event: NSEvent, rowLength: Int? = nil) -> Int? {
        switch event.keyCode {
        case leftArrow: -1
        case rightArrow: 1
        case downArrow: rowLength
        case upArrow: rowLength.map { -$0 }
        default: nil
        }
    }
}

/// 能弹出卡片菜单的集合项：卡片菜单按它代表的视频 ID 取，菜单打开期间由它自己画上下文描边。
///
/// 网格与横排的视频卡片（`NativeVideoCollectionItem`）与 UP 主空间的投稿行都实现它；菜单的取用、弹出与读屏操作只在
/// `NativeVideoCardCollectionView` 写一份，各集合项只提供 ID 与描边。
@MainActor
package protocol NativeVideoMenuTargetItem: NSCollectionViewItem {
    /// 此刻代表的视频 ID；复用、拆除后为 nil。异步弹出菜单与读屏操作执行前按它核对集合项是否已换了视频。
    var representedVideoID: String? { get }
    func setContextMenuTarget(_ isTarget: Bool)
}

/// 网格、shelf 与 UP 主空间列表的集合视图基类：激活回调、键盘选择框状态与卡片菜单；`open` 供 BiliVideoDetailFeature 的
/// 横排（`NativeVideoShelfCollectionView`）与空间列表跨模块子类化。
///
/// 用 AppKit 的理由见 ARCHITECTURE「原生 AppKit 集合视图」。
@MainActor
open class NativeVideoCardCollectionView: NSCollectionView {
    package var onActivateSelection: ((String) -> Void)?
    /// 按卡片 ID 取菜单描述；nil 或返回 nil 时不弹菜单、卡片没有读屏自定义操作。
    ///
    /// 由网格与横排的 Coordinator 设置并在 reset 时清空，Coordinator 再转给 Feature 注入的 `cardMenu`。
    package var cardMenu: ((String) -> NativeVideoCardMenu?)?
    package private(set) var showsKeyboardSelection = false
    /// 菜单打开期间的目标卡片：`menu(for:)` 记下，`willOpenMenu` 画上下文描边，`didCloseMenu` 撤销并清空。
    ///
    /// 右键、Control-点按与读屏「显示菜单」都经 `rightMouseDown` 走到这里，描边只在这一对回调里写。
    private weak var contextMenuTarget: (any NativeVideoMenuTargetItem)?

    /// 右键、Control-点按与读屏「显示菜单」命中卡片时弹出该卡片的菜单；空白处与没有菜单的卡片不弹。
    ///
    /// 与访达、「音乐」一致，右键不改变选中，也不移动键盘选择框，只在菜单打开期间给目标卡片画上下文描边：
    /// 菜单只作用于被点的那张卡片，改选中会让键盘焦点跟着跳走。
    open override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        guard
            let indexPath = indexPathForItem(at: point),
            let item = item(at: indexPath) as? any NativeVideoMenuTargetItem,
            let menu = cardMenu(for: item)
        else { return nil }
        contextMenuTarget = item
        return menu.makeMenu()
    }

    /// 子类 `mouseDown`（或自己接管鼠标的集合项视图，例如空间投稿行）的第一步：Control-点按转进右键同一条菜单路径（`rightMouseDown` → `menu(for:)` →
    /// `willOpenMenu`／`didCloseMenu`），返回 true 时调用方不再按点击处理。
    ///
    /// 命中的是卡片视图：窗口先问它的 `menu(for:)`，它没有菜单，事件就作为普通按下沿响应链送到集合视图。右键沿响应链
    /// 走的是 `rightMouseDown`，会问到集合视图的菜单；Control-点按不转过去就既不弹菜单，还会被当作点击激活。
    package func routesControlClickToContextMenu(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.control) else { return false }
        rightMouseDown(with: event)
        return true
    }

    open override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        contextMenuTarget?.setContextMenuTarget(true)
    }

    open override func didCloseMenu(_ menu: NSMenu, with event: NSEvent?) {
        super.didCloseMenu(menu, with: event)
        contextMenuTarget?.setContextMenuTarget(false)
        contextMenuTarget = nil
    }

    package func setShowsKeyboardSelection(_ shows: Bool) {
        showsKeyboardSelection = shows
        updateVisibleKeyboardSelection(showsKeyboardSelection: shows)
    }

    /// 键盘导航：单选移动到 `index`（夹在有效范围内），显示选择框并滚动到可见。
    package func selectWithKeyboard(
        itemAt index: Int,
        scrollPosition: NSCollectionView.ScrollPosition
    ) {
        let itemCount = numberOfItems(inSection: 0)
        guard itemCount > 0 else { return }
        let targetPath = IndexPath(item: min(itemCount - 1, max(0, index)), section: 0)
        showsKeyboardSelection = true
        selectionIndexPaths = [targetPath]
        updateVisibleKeyboardSelection(showsKeyboardSelection: true)
        scrollToItems(at: [targetPath], scrollPosition: scrollPosition)
        // 滚动后新出现的卡片在下一轮 runloop 才可见，再同步一次选择框。
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.updateVisibleKeyboardSelection(
                showsKeyboardSelection: self.showsKeyboardSelection
            )
        }
    }
}

/// 一组主线程通知观察的 token 集合：登记滚动、实时滚动、辅助功能显示选项等通知，teardown 时一次性移除。
///
/// 持有者必须在 teardown 时调用 `removeAll()`：结构体没有 deinit，丢弃它不会移除观察。通知在主队列投递，
/// 回调在 MainActor 上执行。
@MainActor
public struct NativeVideoNotificationObservers {
    private var tokens: [(center: NotificationCenter, token: NSObjectProtocol)] = []

    public init() {}

    public mutating func observe(
        _ name: Notification.Name,
        object: AnyObject?,
        center: NotificationCenter = .default,
        handler: @escaping @MainActor @Sendable () -> Void
    ) {
        let token = center.addObserver(forName: name, object: object, queue: .main) { _ in
            MainActor.assumeIsolated { handler() }
        }
        tokens.append((center, token))
    }

    public mutating func observeScrolling(
        of scrollView: NSScrollView,
        handler: @escaping @MainActor @Sendable () -> Void
    ) {
        observe(
            NSView.boundsDidChangeNotification,
            object: scrollView.contentView,
            handler: handler
        )
    }

    public mutating func observeAccessibilityDisplayOptions(
        handler: @escaping @MainActor @Sendable () -> Void
    ) {
        observe(
            NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil,
            center: NSWorkspace.shared.notificationCenter,
            handler: handler
        )
    }

    public mutating func removeAll() {
        for (center, token) in tokens { center.removeObserver(token) }
        tokens.removeAll()
    }
}

extension NSCollectionView {
    var visibleVideoCards: [NativeVideoCollectionItem] {
        visibleItems().compactMap { $0 as? NativeVideoCollectionItem }
    }

    /// 键盘选择框只在键盘导航后显示，鼠标点击与失焦会隐藏。
    func updateVisibleKeyboardSelection(showsKeyboardSelection: Bool) {
        for item in visibleVideoCards {
            item.setKeyboardFocusVisible(showsKeyboardSelection && item.isSelected)
        }
    }

    /// 系统辅助功能显示选项（提高对比度、降低透明度）变化后刷新可见卡片。
    package func refreshVisibleCardAppearance() {
        for item in visibleVideoCards { item.refreshEnvironmentAppearance() }
    }
}
