import AppKit
import BiliModels
import BiliUI
import BiliVideoCollectionUI

/// 原生列表需要的全部展示值；加载、失败等状态由 SwiftUI 覆盖层负责，这里只画头部（如有）与已加载的行。
struct VideoRowListContent: Equatable {
    /// UP 主空间的头部（返回、名字、排序）；相关推荐竖列没有头部。
    let header: UploaderSpaceHeaderContent?
    let rows: [VideoRowPresentation]
    /// 强调为“正在播放”的行；相关推荐里不会出现当前视频，为 nil。
    let currentBVID: String?
    /// 变化时滚回顶部：空间是 UP 主、排序与页码，相关推荐是它所属的视频；同一页内换视频不改变它。
    let scrollIdentity: AnyHashable
    let reservesPagerSpace: Bool
}

/// 列表的用户动作：头部的返回与切换排序（只有空间用到）、选择视频，以及行的卡片菜单；由各自的 SwiftUI 宿主接到
/// ViewModel 与 App 回调。
struct VideoRowListActions {
    let close: () -> Void
    let selectOrder: (UploaderVideoOrder) -> Void
    let selectVideo: (String) -> Void
    /// 按行取卡片菜单；每次右键、读屏询问或执行时调用，返回 nil 时不弹菜单。
    let cardMenu: (VideoRowPresentation) -> NativeVideoCardMenu?

    @MainActor static let none = VideoRowListActions(
        close: {},
        selectOrder: { _ in },
        selectVideo: { _ in },
        cardMenu: { _ in nil }
    )
}

/// 列表条目身份：头部固定一个，视频行按 BVID 区分。
enum VideoRowListItemID: Hashable, Sendable {
    case header
    case video(String)
}

/// 竖向视频行列表（UP 主空间投稿、播放页相关推荐竖列）的 `NSCollectionView` 协调器：可选的头部与视频行在同一个
/// 集合视图里，拥有 diffable 数据源、悬停与滚动观察；行高固定，不需要测量缓存。
///
/// 行的卡片菜单经集合视图的 `cardMenu` 按 BVID 转给 `actions.cardMenu`，右键、Control-点按与读屏操作都由共用的
/// `NativeVideoCardCollectionView` 处理。
///
/// 数据、排序与分页归各自的 ViewModel；加载、空、失败与登录提示由 SwiftUI 宿主的覆盖层负责。取图经注入的 port。
/// `tearDown` 由 `VideoRowListRepresentable` 在视图拆除时调用一次：移除观察、清掉悬停、清空菜单并取消可见项的图片
/// 请求，之后的 `update` 直接返回。用 AppKit 的理由见 ARCHITECTURE「原生 AppKit 集合视图」。
@MainActor
final class VideoRowListController: NSObject, NSCollectionViewDelegateFlowLayout {
    private enum Section: Int, Hashable, Sendable {
        case header
        case videos
    }

    let scrollView: NativeScrollToTopScrollView
    private let collectionView = VideoRowCollectionView()
    private let layout = NSCollectionViewFlowLayout()
    private let imagePipeline: any VideoDetailImageLoading
    private let hover = NativeVideoHoverTracker()
    private var dataSource: NSCollectionViewDiffableDataSource<Section, VideoRowListItemID>?
    private var content: VideoRowListContent?
    private var rowsByBVID: [String: VideoRowPresentation] = [:]
    private var actions = VideoRowListActions.none
    private var observers = NativeVideoNotificationObservers()
    private var isTornDown = false

    /// 列表本身的读屏名称（“UP 主投稿”“相关推荐”）与回顶按钮的读屏名称由宿主给出；取图经 `imagePipeline`。
    init(
        imagePipeline: any VideoDetailImageLoading,
        accessibilityLabel: String,
        topButtonLabel: String
    ) {
        self.imagePipeline = imagePipeline
        scrollView = NativeScrollToTopScrollView(topButtonLabel: topButtonLabel)
        super.init()
        configureCollectionView(accessibilityLabel: accessibilityLabel)
    }

    func update(content next: VideoRowListContent, actions: VideoRowListActions) {
        guard !isTornDown else { return }
        self.actions = actions
        let previous = content
        content = next
        rowsByBVID = Dictionary(
            next.rows.map { ($0.bvid, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        if previous == nil || previous?.rows.map(\.bvid) != next.rows.map(\.bvid)
            || (previous?.header == nil) != (next.header == nil)
        {
            applySnapshot(rows: next.rows, includesHeader: next.header != nil)
        }
        if previous?.reservesPagerSpace != next.reservesPagerSpace
            || (previous?.header == nil) != (next.header == nil)
        {
            layout.invalidateLayout()
        }
        reconfigureVisibleItems()
        if previous?.scrollIdentity != next.scrollIdentity {
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

    private func configureCollectionView(accessibilityLabel: String) {
        layout.minimumLineSpacing = VideoRowGeometry.rowSpacing
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
            VideoRowItem.self,
            forItemWithIdentifier: VideoRowItem.reuseIdentifier
        )
        collectionView.setAccessibilityLabel(accessibilityLabel)
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

    private func applySnapshot(rows: [VideoRowPresentation], includesHeader: Bool) {
        var snapshot = NSDiffableDataSourceSnapshot<Section, VideoRowListItemID>()
        snapshot.appendSections([.header, .videos])
        if includesHeader {
            snapshot.appendItems([.header], toSection: .header)
        }
        snapshot.appendItems(rows.map { .video($0.bvid) }, toSection: .videos)
        dataSource?.apply(snapshot, animatingDifferences: false)
    }

    private func makeItem(
        _ collectionView: NSCollectionView,
        at indexPath: IndexPath,
        id: VideoRowListItemID
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
                withIdentifier: VideoRowItem.reuseIdentifier,
                for: indexPath
            )
            if let row = item as? VideoRowItem { configure(row, bvid: bvid) }
            return item
        }
    }

    private func configure(_ item: UploaderSpaceHeaderItem) {
        guard let header = content?.header else { return }
        item.configure(
            content: header,
            imagePipeline: imagePipeline,
            onClose: { [weak self] in self?.actions.close() },
            onSelectOrder: { [weak self] in self?.actions.selectOrder($0) }
        )
    }

    private func configure(_ item: VideoRowItem, bvid: String) {
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
                if let row = item as? VideoRowItem { configure(row, bvid: bvid) }
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
            collectionView.bounds.width - VideoRowGeometry.listHorizontalInset * 2
        )
        let isHeader = indexPath.section == Section.header.rawValue
        return NSSize(
            width: width,
            height: isHeader ? UploaderSpaceGeometry.headerHeight : VideoRowGeometry.rowHeight
        )
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        layout collectionViewLayout: NSCollectionViewLayout,
        insetForSectionAt section: Int
    ) -> NSEdgeInsets {
        let horizontal = VideoRowGeometry.listHorizontalInset
        if section == Section.header.rawValue {
            // 没有头部时头部段是空的，只把列表顶边距留给它。
            guard content?.header != nil else {
                return NSEdgeInsets(
                    top: VideoRowGeometry.listTopInset,
                    left: 0,
                    bottom: 0,
                    right: 0
                )
            }
            return NSEdgeInsets(
                top: VideoRowGeometry.listTopInset,
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
            bottom: VideoRowGeometry.listBottomInset + pagerSpace,
            right: horizontal
        )
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        didEndDisplaying item: NSCollectionViewItem,
        forRepresentedObjectAt indexPath: IndexPath
    ) {
        if let row = item as? VideoRowItem {
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
private final class VideoRowCollectionView: NativeVideoCardCollectionView {
    override var acceptsFirstResponder: Bool { false }

    /// 宽度变化（播放页分栏随窗口变化、空间层进场时先以中间宽度布局）时重算行宽。
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
