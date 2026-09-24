import AppKit

/// 网格与 shelf 共用的卡片内容：去重、按 ID 查找与 diffable 快照。
struct NativeVideoCardContents {
    static let section = 0

    private(set) var byID: [String: NativeVideoCardPresentation]
    private(set) var orderedIDs: [String]

    init(_ items: [NativeVideoCardPresentation] = []) {
        var seen: Set<String> = []
        let uniqueItems = items.filter { !$0.id.isEmpty && seen.insert($0.id).inserted }
        byID = Dictionary(uniqueKeysWithValues: uniqueItems.map { ($0.id, $0) })
        orderedIDs = uniqueItems.map(\.id)
    }

    subscript(id: String) -> NativeVideoCardPresentation? { byID[id] }

    func indexPath(of id: String) -> IndexPath? {
        orderedIDs.firstIndex(of: id).map { IndexPath(item: $0, section: Self.section) }
    }

    func makeSnapshot() -> NSDiffableDataSourceSnapshot<Int, String> {
        var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
        snapshot.appendSections([Self.section])
        snapshot.appendItems(orderedIDs, toSection: Self.section)
        return snapshot
    }

    /// 可见卡片及其当前内容；`ids` 为空表示全部可见卡片。
    @MainActor
    func visibleCards(
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

@MainActor
enum NativeVideoCardDataSource {
    /// 调用方以 `[weak self]` 捕获 Coordinator，工厂本身不持有任何 owner。
    static func make(
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

/// 指针悬停的唯一 owner：同一时刻最多一张卡片处于悬停外观。
@MainActor
final class NativeVideoHoverTracker {
    private(set) weak var hoveredItem: NativeVideoCollectionItem?

    /// 由 Coordinator 主动决定悬停目标（滚动、布局、窗口变化后）。
    func setHoveredItem(_ item: NativeVideoCollectionItem?) {
        guard hoveredItem !== item else { return }
        let previous = hoveredItem
        hoveredItem = item
        previous?.setHovered(false)
        item?.setHovered(true)
    }

    /// 卡片自身的 tracking area 报告的悬停变化；卡片已自行更新外观，这里只撤销前一张。
    func itemDidChangeHover(_ item: NativeVideoCollectionItem, isHovered: Bool) {
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
    func forgetHoveredItem() {
        hoveredItem = nil
    }

    /// 以窗口当前指针位置重新选择悬停卡片；滚动不会产生 mouseEntered/Exited。
    func updateForCurrentPointerLocation(in collectionView: NSCollectionView) {
        setHoveredItem(Self.itemUnderPointer(in: collectionView))
    }

    /// 离屏卡片可能立即被复用给其他视频，必须同时丢弃引用、图片请求与悬停外观。
    func itemDidEndDisplaying(_ item: NativeVideoCollectionItem) {
        if hoveredItem === item { hoveredItem = nil }
        item.invalidateImageRequests()
        item.clearHover()
    }

    private static func itemUnderPointer(
        in collectionView: NSCollectionView
    ) -> NativeVideoCollectionItem? {
        guard let windowPoint = collectionView.window?.mouseLocationOutsideOfEventStream
        else { return nil }
        let collectionPoint = collectionView.convert(windowPoint, from: nil)
        guard
            collectionView.visibleRect.contains(collectionPoint),
            let indexPath = collectionView.indexPathForItem(at: collectionPoint)
        else { return nil }
        return collectionView.item(at: indexPath) as? NativeVideoCollectionItem
    }
}

/// 集合键盘导航使用的物理键码。
///
/// 保留 keyCode 判断而不改用 `specialKey`：后者会把小键盘 Enter 也当作激活键，改变现有行为。
enum NativeVideoCollectionKeys {
    static let returnKey: UInt16 = 36
    static let leftArrow: UInt16 = 123
    static let rightArrow: UInt16 = 124
    static let downArrow: UInt16 = 125
    static let upArrow: UInt16 = 126
    static let space = " "

    static func isActivation(_ event: NSEvent) -> Bool {
        event.keyCode == returnKey || event.charactersIgnoringModifiers == space
    }

    /// 方向键对应的选择位移；`rowLength` 为 nil 时不处理上下键。
    static func selectionDelta(for event: NSEvent, rowLength: Int? = nil) -> Int? {
        switch event.keyCode {
        case leftArrow: -1
        case rightArrow: 1
        case downArrow: rowLength
        case upArrow: rowLength.map { -$0 }
        default: nil
        }
    }
}

/// 网格与 shelf 的 Coordinator 共同持有的通知观察；reset 时一次性移除。
@MainActor
struct NativeVideoNotificationObservers {
    private var tokens: [(center: NotificationCenter, token: NSObjectProtocol)] = []

    mutating func observe(
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

    mutating func observeScrolling(
        of scrollView: NSScrollView,
        handler: @escaping @MainActor @Sendable () -> Void
    ) {
        observe(
            NSView.boundsDidChangeNotification,
            object: scrollView.contentView,
            handler: handler
        )
    }

    mutating func observeAccessibilityDisplayOptions(
        handler: @escaping @MainActor @Sendable () -> Void
    ) {
        observe(
            NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil,
            center: NSWorkspace.shared.notificationCenter,
            handler: handler
        )
    }

    mutating func removeAll() {
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
    func refreshVisibleCardAppearance() {
        for item in visibleVideoCards { item.refreshEnvironmentAppearance() }
    }
}
