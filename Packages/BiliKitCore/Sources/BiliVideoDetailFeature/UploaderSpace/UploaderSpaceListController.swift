import AppKit
import BiliModels
import BiliUI
import BiliVideoCollectionUI

/// 原生列表需要的全部展示值；加载、失败等状态由 SwiftUI 覆盖层负责，这里只画头部与已加载的行。
struct UploaderSpaceListContent: Equatable {
    /// 换 UP 主、排序或页码时滚回顶部；空间内换视频不改变它。
    struct PageIdentity: Equatable {
        let ownerID: Int64
        let order: UploaderVideoOrder
        let page: Int
    }

    let header: UploaderSpaceHeaderContent
    let rows: [UploaderVideoRowPresentation]
    let currentBVID: String?
    let pageIdentity: PageIdentity
    let reservesPagerSpace: Bool
}

/// 空间列表的用户动作：切换排序、选择投稿，以及投稿行的卡片菜单；由 `UploaderSpaceSidebarView` 接到
/// ViewModel 与 App 回调。
struct UploaderSpaceListActions {
    let selectOrder: (UploaderVideoOrder) -> Void
    let selectVideo: (String) -> Void
    /// 按投稿行取卡片菜单；每次右键、读屏询问或执行时调用，返回 nil 时不弹菜单。
    let cardMenu: (UploaderVideoRowPresentation) -> NativeVideoCardMenu?

    @MainActor static let none = UploaderSpaceListActions(
        selectOrder: { _ in },
        selectVideo: { _ in },
        cardMenu: { _ in nil }
    )
}

/// 列表条目身份：头部固定一个，投稿行按 BVID 区分。
enum UploaderSpaceListItemID: Hashable, Sendable {
    case header
    case video(String)
}

/// UP 主空间列表的 `NSCollectionView` 协调器：头部与投稿行在同一个集合视图里，拥有 diffable 数据源、悬停与
/// 滚动观察；行高固定，不需要测量缓存。
///
/// 投稿行的卡片菜单经集合视图的 `cardMenu` 按 BVID 转给 `actions.cardMenu`，右键、Control-点按与读屏操作都由共用的
/// `NativeVideoCardCollectionView` 处理。
///
/// 投稿数据、排序与分页归 `UploaderSpaceViewModel`；加载、空、失败与登录提示由 SwiftUI 覆盖层负责。取图经注入的
/// port。`tearDown` 由 `UploaderSpaceSidebarView` 在视图拆除时调用一次：移除观察、清掉悬停并取消可见项的图片
/// 请求，之后的 `update` 直接返回。用 AppKit 的理由见 ARCHITECTURE「原生 AppKit 集合视图」。
@MainActor
final class UploaderSpaceListController: NSObject, NSCollectionViewDelegateFlowLayout {
    private enum Section: Int, Hashable, Sendable {
        case header
        case videos
    }

    let scrollView = NativeScrollToTopScrollView(
        topButtonLabel: VideoDetailFeatureStrings.localized("返回空间顶部")
    )
    private let collectionView = UploaderSpaceCollectionView()
    private let layout = NSCollectionViewFlowLayout()
    private let imagePipeline: any VideoDetailImageLoading
    private let hover = NativeVideoHoverTracker()
    private var dataSource: NSCollectionViewDiffableDataSource<Section, UploaderSpaceListItemID>?
    private var content: UploaderSpaceListContent?
    private var rowsByBVID: [String: UploaderVideoRowPresentation] = [:]
    private var actions = UploaderSpaceListActions.none
    private var observers = NativeVideoNotificationObservers()
    private var isTornDown = false

    init(imagePipeline: any VideoDetailImageLoading) {
        self.imagePipeline = imagePipeline
        super.init()
        configureCollectionView()
    }

    func update(content next: UploaderSpaceListContent, actions: UploaderSpaceListActions) {
        guard !isTornDown else { return }
        self.actions = actions
        let previous = content
        content = next
        rowsByBVID = Dictionary(
            next.rows.map { ($0.bvid, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        if previous == nil || previous?.rows.map(\.bvid) != next.rows.map(\.bvid) {
            applySnapshot(rows: next.rows)
        }
        if previous?.reservesPagerSpace != next.reservesPagerSpace {
            layout.invalidateLayout()
        }
        reconfigureVisibleItems()
        if previous?.pageIdentity != next.pageIdentity {
            scrollToTop(animated: false)
        }
    }

    func tearDown() {
        guard !isTornDown else { return }
        isTornDown = true
        collectionView.cardMenu = nil
        observers.removeAll()
        hover.forgetHoveredItem()
        for item in collectionView.visibleItems() {
            (item as? any NativeHoverableCollectionItem)?.invalidateImageRequests()
            (item as? UploaderSpaceHeaderItem)?.invalidateImageRequests()
        }
    }

    private func configureCollectionView() {
        layout.minimumLineSpacing = UploaderSpaceGeometry.rowSpacing
        layout.minimumInteritemSpacing = 0
        collectionView.collectionViewLayout = layout
        collectionView.delegate = self
        collectionView.isSelectable = false
        collectionView.backgroundColors = [.clear]
        collectionView.autoresizingMask = [.width]
        collectionView.register(
            UploaderSpaceHeaderItem.self,
            forItemWithIdentifier: UploaderSpaceHeaderItem.reuseIdentifier
        )
        collectionView.register(
            UploaderSpaceVideoRowItem.self,
            forItemWithIdentifier: UploaderSpaceVideoRowItem.reuseIdentifier
        )
        collectionView.setAccessibilityLabel(VideoDetailFeatureStrings.localized("UP 主投稿"))
        // 每次取用时读当下的行与动作：菜单可能在行被替换、登录状态变化之后才弹出。
        collectionView.cardMenu = { [weak self] bvid in
            guard let self, !isTornDown, let row = rowsByBVID[bvid] else { return nil }
            return actions.cardMenu(row)
        }
        dataSource = NSCollectionViewDiffableDataSource(
            collectionView: collectionView
        ) { [weak self] collectionView, indexPath, id in
            self?.makeItem(collectionView, at: indexPath, id: id)
        }

        scrollView.documentView = collectionView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.horizontalScrollElasticity = .none
        scrollView.automaticallyAdjustsContentInsets = true
        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollView.topButton.target = self
        scrollView.topButton.action = #selector(scrollToTopFromButton)
        observers.observeScrolling(of: scrollView) { [weak self] in
            self?.viewportDidScroll()
        }
        observers.observeAccessibilityDisplayOptions { [weak self] in
            self?.reconfigureVisibleItems()
        }
    }

    private func applySnapshot(rows: [UploaderVideoRowPresentation]) {
        var snapshot = NSDiffableDataSourceSnapshot<Section, UploaderSpaceListItemID>()
        snapshot.appendSections([.header, .videos])
        snapshot.appendItems([.header], toSection: .header)
        snapshot.appendItems(rows.map { .video($0.bvid) }, toSection: .videos)
        dataSource?.apply(snapshot, animatingDifferences: false)
    }

    private func makeItem(
        _ collectionView: NSCollectionView,
        at indexPath: IndexPath,
        id: UploaderSpaceListItemID
    ) -> NSCollectionViewItem? {
        switch id {
        case .header:
            let item = collectionView.makeItem(
                withIdentifier: UploaderSpaceHeaderItem.reuseIdentifier,
                for: indexPath
            )
            if let header = item as? UploaderSpaceHeaderItem { configure(header) }
            return item
        case .video(let bvid):
            let item = collectionView.makeItem(
                withIdentifier: UploaderSpaceVideoRowItem.reuseIdentifier,
                for: indexPath
            )
            if let row = item as? UploaderSpaceVideoRowItem { configure(row, bvid: bvid) }
            return item
        }
    }

    private func configure(_ item: UploaderSpaceHeaderItem) {
        guard let content else { return }
        item.configure(
            content: content.header,
            imagePipeline: imagePipeline,
            onSelectOrder: { [weak self] in self?.actions.selectOrder($0) }
        )
    }

    private func configure(_ item: UploaderSpaceVideoRowItem, bvid: String) {
        guard let row = rowsByBVID[bvid] else { return }
        item.configure(
            row: row,
            isCurrent: bvid == content?.currentBVID,
            imagePipeline: imagePipeline,
            onSelect: { [weak self] in self?.actions.selectVideo($0) },
            hoverChanged: { [weak self] item, isHovered in
                self?.hover.itemDidChangeHover(item, isHovered: isHovered)
            }
        )
    }

    /// 头部、“正在播放”等变化只重新配置可见项，不重建快照，封面也不会重新加载。
    private func reconfigureVisibleItems() {
        guard let dataSource else { return }
        for indexPath in collectionView.indexPathsForVisibleItems() {
            guard let id = dataSource.itemIdentifier(for: indexPath),
                let item = collectionView.item(at: indexPath)
            else { continue }
            switch id {
            case .header:
                (item as? UploaderSpaceHeaderItem).map(configure)
            case .video(let bvid):
                if let row = item as? UploaderSpaceVideoRowItem { configure(row, bvid: bvid) }
            }
        }
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        layout collectionViewLayout: NSCollectionViewLayout,
        sizeForItemAt indexPath: IndexPath
    ) -> NSSize {
        let width = max(
            0,
            collectionView.bounds.width - UploaderSpaceGeometry.listHorizontalInset * 2
        )
        let isHeader = indexPath.section == Section.header.rawValue
        return NSSize(
            width: width,
            height: isHeader ? UploaderSpaceGeometry.headerHeight : UploaderSpaceGeometry.rowHeight
        )
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        layout collectionViewLayout: NSCollectionViewLayout,
        insetForSectionAt section: Int
    ) -> NSEdgeInsets {
        let horizontal = UploaderSpaceGeometry.listHorizontalInset
        if section == Section.header.rawValue {
            return NSEdgeInsets(
                top: UploaderSpaceGeometry.listTopInset,
                left: horizontal,
                bottom: UploaderSpaceGeometry.headerBottomSpacing,
                right: horizontal
            )
        }
        let pagerSpace =
            content?.reservesPagerSpace == true ? PageNumberPagerGeometry.reservedHeight : 0
        return NSEdgeInsets(
            top: 0,
            left: horizontal,
            bottom: UploaderSpaceGeometry.listBottomInset + pagerSpace,
            right: horizontal
        )
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        didEndDisplaying item: NSCollectionViewItem,
        forRepresentedObjectAt indexPath: IndexPath
    ) {
        if let row = item as? UploaderSpaceVideoRowItem {
            hover.itemDidEndDisplaying(row)
        } else if let header = item as? UploaderSpaceHeaderItem {
            header.invalidateImageRequests()
        }
    }

    private func viewportDidScroll() {
        guard !isTornDown else { return }
        scrollView.updateTopButtonVisibility()
        // 滚动不会产生 mouseEntered/Exited，按指针当前位置重选悬停行。
        hover.updateForCurrentPointerLocation(in: collectionView)
    }

    @objc private func scrollToTopFromButton() {
        scrollToTop(animated: true)
    }

    private func scrollToTop(animated: Bool) {
        scrollView.scrollVertically(
            toPhysicalOffset: NativeVideoScrollCoordinateSpace.physicalOffset(
                logicalOffset: 0,
                leadingInset: scrollView.contentInsets.top
            ),
            animated: animated
        )
    }
}

/// 列表不接管键盘：方向键、空格等留给播放器快捷键。
///
/// 继承共用的卡片集合视图只为卡片菜单（右键、读屏操作）；键盘选择框不会出现，因为它从不成为第一响应者。
@MainActor
private final class UploaderSpaceCollectionView: NativeVideoCardCollectionView {
    override var acceptsFirstResponder: Bool { false }

    /// 宽度变化（拖动侧栏、空间层进场时先以中间宽度布局）时重算行宽。
    ///
    /// 布局的 bounds 回调不覆盖文档视图的尺寸变化；不在这里重算的话，没有投稿行时头部会一直停在
    /// 旧宽度，排序挤出屏幕、名字宽度为零。
    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = newSize.width != frame.width
        super.setFrameSize(newSize)
        if widthChanged {
            collectionViewLayout?.invalidateLayout()
        }
    }
}
