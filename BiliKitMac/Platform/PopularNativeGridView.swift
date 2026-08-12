import AppKit
import BiliBrowseFeature
import BiliModels
import CoreGraphics
import Foundation
import ImageIO
import QuartzCore
import SwiftUI

struct PopularNativeGridView: NSViewRepresentable {
    let videos: [PopularVideo]
    @Binding var scrollOffsetY: CGFloat
    let onSelect: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            videos: videos,
            initialScrollOffsetY: scrollOffsetY,
            onScroll: { scrollOffsetY = $0 },
            onSelect: onSelect
        )
    }

    func makeNSView(context: Context) -> NSScrollView {
        context.coordinator.makeScrollView()
    }

    func updateNSView(_ view: NSScrollView, context: Context) {
        context.coordinator.update(
            videos: videos,
            onScroll: { scrollOffsetY = $0 },
            onSelect: onSelect
        )
    }

    static func dismantleNSView(
        _ view: NSScrollView,
        coordinator: Coordinator
    ) {
        coordinator.reset()
    }

    @MainActor
    final class Coordinator: NSObject, NSCollectionViewDelegateFlowLayout {
        private let scrollView = NSScrollView()
        private let collectionView = PopularNativeCollectionView()
        private let layout = NSCollectionViewFlowLayout()
        private let imagePipeline = PopularNativeImagePipeline()
        private var dataSource: NSCollectionViewDiffableDataSource<Int, String>?
        private var contentsByBVID: [String: PopularNativeCardContent]
        private var orderedBVIDs: [String]
        private var onScroll: (CGFloat) -> Void
        private var onSelect: (String) -> Void
        private var boundsObserver: NSObjectProtocol?
        private var frameObserver: NSObjectProtocol?
        private var accessibilityObserver: NSObjectProtocol?
        private var pendingRestoreOffsetY: CGFloat?
        private var scrollCaptureWorkItem: DispatchWorkItem?
        private var retainedScrollOffset: PopularNativeScrollOffsetRetention
        private weak var hoveredItem: PopularNativeCollectionItem?
        private var lastViewportSize: NSSize?
        private var documentLayoutNeedsInvalidation = true
        private var isApplyingRestoration = false
        private var isReset = false

        init(
            videos: [PopularVideo],
            initialScrollOffsetY: CGFloat,
            onScroll: @escaping (CGFloat) -> Void,
            onSelect: @escaping (String) -> Void
        ) {
            let contents = Self.makeContents(videos)
            contentsByBVID = Dictionary(
                uniqueKeysWithValues: contents.map { ($0.bvid, $0) }
            )
            orderedBVIDs = contents.map(\.bvid)
            self.onScroll = onScroll
            self.onSelect = onSelect
            retainedScrollOffset = PopularNativeScrollOffsetRetention(
                initialOffsetY: initialScrollOffsetY
            )
            pendingRestoreOffsetY = retainedScrollOffset.offsetY
        }

        func makeScrollView() -> NSScrollView {
            let padding = PopularNativeGridGeometry.contentPadding
            layout.minimumInteritemSpacing = PopularNativeGridGeometry.horizontalSpacing
            layout.minimumLineSpacing = PopularNativeGridGeometry.verticalSpacing
            layout.sectionInset = NSEdgeInsets(
                top: PopularNativeGridGeometry.topContentPadding,
                left: padding,
                bottom: padding,
                right: padding
            )

            collectionView.collectionViewLayout = layout
            collectionView.delegate = self
            collectionView.isSelectable = true
            collectionView.allowsMultipleSelection = false
            collectionView.backgroundColors = [.clear]
            collectionView.onActivateSelection = { [weak self] bvid in
                self?.onSelect(bvid)
            }
            collectionView.register(
                PopularNativeCollectionItem.self,
                forItemWithIdentifier: .popularNativeVideoCard
            )

            dataSource = NSCollectionViewDiffableDataSource<Int, String>(
                collectionView: collectionView
            ) { [weak self] collectionView, indexPath, bvid in
                guard
                    let self,
                    let content = self.contentsByBVID[bvid],
                    let item = collectionView.makeItem(
                        withIdentifier: .popularNativeVideoCard,
                        for: indexPath
                    ) as? PopularNativeCollectionItem
                else {
                    return nil
                }
                item.configure(
                    content: content,
                    imagePipeline: self.imagePipeline,
                    hoverChanged: { [weak self] item, isHovered in
                        self?.item(item, didChangeHover: isHovered)
                    },
                    activation: { [weak self, weak collectionView] selectedBVID in
                        if let index = self?.orderedBVIDs.firstIndex(of: selectedBVID) {
                            collectionView?.selectionIndexPaths = [
                                IndexPath(item: index, section: 0)
                            ]
                        }
                        self?.onSelect(selectedBVID)
                    }
                )
                item.setKeyboardFocusVisible(
                    (collectionView as? PopularNativeCollectionView)?
                        .showsKeyboardSelection == true
                        && collectionView.selectionIndexPaths.contains(indexPath)
                )
                return item
            }

            scrollView.documentView = collectionView
            scrollView.hasVerticalScroller = true
            scrollView.autohidesScrollers = true
            scrollView.drawsBackground = false
            scrollView.contentView.postsBoundsChangedNotifications = true
            scrollView.contentView.postsFrameChangedNotifications = true
            collectionView.setAccessibilityLabel("热门视频")

            boundsObserver = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: scrollView.contentView,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.didScroll() }
            }
            frameObserver = NotificationCenter.default.addObserver(
                forName: NSView.frameDidChangeNotification,
                object: scrollView.contentView,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.resizeDocument() }
            }
            accessibilityObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.refreshVisibleInteractionAppearance()
                }
            }

            applySnapshot(animatingDifferences: false)
            DispatchQueue.main.async { [weak self] in
                self?.resizeDocument()
                self?.restorePendingOffsetIfPossible()
            }
            return scrollView
        }

        func update(
            videos: [PopularVideo],
            onScroll: @escaping (CGFloat) -> Void,
            onSelect: @escaping (String) -> Void
        ) {
            guard !isReset else { return }
            self.onScroll = onScroll
            self.onSelect = onSelect

            let updatedContents = Self.makeContents(videos)
            let updatedByBVID = Dictionary(
                uniqueKeysWithValues: updatedContents.map { ($0.bvid, $0) }
            )
            let updatedBVIDs = updatedContents.map(\.bvid)
            let updatePlan = PopularNativeGridUpdatePlan(
                previousBVIDs: orderedBVIDs,
                previousContents: contentsByBVID,
                updatedBVIDs: updatedBVIDs,
                updatedContents: updatedByBVID
            )
            contentsByBVID = updatedByBVID
            orderedBVIDs = updatedBVIDs

            if updatePlan.identityChanged {
                applySnapshot(
                    animatingDifferences: true,
                    reloading: updatePlan.snapshotReloadBVIDs
                ) { [weak self] in
                    guard let self, !self.isReset else { return }
                    self.documentLayoutNeedsInvalidation = true
                    self.resizeDocument()
                    self.restorePendingOffsetIfPossible()
                }
            } else if !updatePlan.changedBVIDs.isEmpty {
                let paths: Set<IndexPath> = Set(
                    updatePlan.changedBVIDs.compactMap { bvid in
                        guard let index = orderedBVIDs.firstIndex(of: bvid) else { return nil }
                        return IndexPath(item: index, section: 0)
                    }
                )
                collectionView.reloadItems(at: paths)
            }

            if !updatePlan.identityChanged {
                DispatchQueue.main.async { [weak self] in
                    self?.resizeDocument()
                    self?.restorePendingOffsetIfPossible()
                }
            }
        }

        func reset() {
            guard !isReset else { return }
            isReset = true
            scrollCaptureWorkItem?.cancel()
            scrollCaptureWorkItem = nil
            onScroll(retainedScrollOffset.offsetY)
            hoveredItem = nil
            for case let item as PopularNativeCollectionItem in collectionView.visibleItems() {
                item.invalidate()
            }
            collectionView.onActivateSelection = nil
            collectionView.delegate = nil
            collectionView.dataSource = nil
            dataSource = nil
            if let boundsObserver { NotificationCenter.default.removeObserver(boundsObserver) }
            if let frameObserver { NotificationCenter.default.removeObserver(frameObserver) }
            if let accessibilityObserver {
                NSWorkspace.shared.notificationCenter.removeObserver(accessibilityObserver)
            }
            boundsObserver = nil
            frameObserver = nil
            accessibilityObserver = nil
            lastViewportSize = nil
            contentsByBVID.removeAll()
            orderedBVIDs.removeAll()
            imagePipeline.cancelAllRequests()
            Task { await imagePipeline.shutdown() }
        }

        private static func makeContents(
            _ videos: [PopularVideo]
        ) -> [PopularNativeCardContent] {
            var seenBVIDs: Set<String> = []
            return videos.compactMap { video in
                guard seenBVIDs.insert(video.bvid).inserted else { return nil }
                return PopularNativeCardContent(video: video)
            }
        }

        private func applySnapshot(
            animatingDifferences: Bool,
            reloading bvids: [String] = [],
            completion: (() -> Void)? = nil
        ) {
            documentLayoutNeedsInvalidation = true
            var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
            snapshot.appendSections([0])
            snapshot.appendItems(orderedBVIDs, toSection: 0)
            if !bvids.isEmpty {
                snapshot.reloadItems(bvids)
            }
            dataSource?.apply(
                snapshot,
                animatingDifferences: animatingDifferences,
                completion: completion
            )
        }

        private func resizeDocument() {
            guard !isReset else { return }
            let viewportSize = scrollView.contentSize
            let width = max(1, viewportSize.width)
            let widthChanged =
                lastViewportSize.map {
                    abs($0.width - viewportSize.width) > 0.5
                } ?? true
            let heightChanged =
                lastViewportSize.map {
                    abs($0.height - viewportSize.height) > 0.5
                } ?? true
            let shouldInvalidateLayout =
                documentLayoutNeedsInvalidation || widthChanged
            guard shouldInvalidateLayout || heightChanged else { return }

            lastViewportSize = viewportSize
            if shouldInvalidateLayout {
                documentLayoutNeedsInvalidation = false
            }
            let contentHeight = PopularNativeGridGeometry.contentHeight(
                for: width,
                itemCount: orderedBVIDs.count
            )
            collectionView.setFrameSize(
                NSSize(
                    width: width,
                    height: max(viewportSize.height, contentHeight)
                )
            )
            if shouldInvalidateLayout {
                layout.invalidateLayout()
            }
        }

        private var currentScrollOffsetY: CGFloat {
            max(0, scrollView.contentView.bounds.origin.y)
        }

        private func didScroll() {
            guard !isReset else { return }
            updateHoverForCurrentPointerLocation()
            if !isApplyingRestoration,
                pendingRestoreOffsetY == nil,
                scrollView.window != nil
            {
                let observedOffsetY = currentScrollOffsetY
                retainedScrollOffset.record(observedOffsetY)
                pendingRestoreOffsetY = nil
                scrollCaptureWorkItem?.cancel()
                let workItem = DispatchWorkItem { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self, !self.isReset else { return }
                        self.onScroll(observedOffsetY)
                    }
                }
                scrollCaptureWorkItem = workItem
                DispatchQueue.main.asyncAfter(
                    deadline: .now() + 0.15,
                    execute: workItem
                )
            }
        }

        private func updateHoverForCurrentPointerLocation() {
            let candidate: PopularNativeCollectionItem?
            if let windowPoint = collectionView.window?.mouseLocationOutsideOfEventStream {
                let collectionPoint = collectionView.convert(windowPoint, from: nil)
                if collectionView.visibleRect.contains(collectionPoint),
                    let indexPath = collectionView.indexPathForItem(at: collectionPoint)
                {
                    candidate =
                        collectionView.item(at: indexPath)
                        as? PopularNativeCollectionItem
                } else {
                    candidate = nil
                }
            } else {
                candidate = nil
            }
            setHoveredItem(candidate)
        }

        private func setHoveredItem(_ item: PopularNativeCollectionItem?) {
            guard hoveredItem !== item else { return }
            let previous = hoveredItem
            hoveredItem = item
            previous?.setHovered(false)
            item?.setHovered(true)
        }

        private func item(
            _ item: PopularNativeCollectionItem,
            didChangeHover isHovered: Bool
        ) {
            guard !isReset else { return }
            if isHovered {
                guard hoveredItem !== item else { return }
                let previous = hoveredItem
                hoveredItem = item
                previous?.setHovered(false)
            } else if hoveredItem === item {
                hoveredItem = nil
            }
        }

        private func refreshVisibleInteractionAppearance() {
            for case let item as PopularNativeCollectionItem in collectionView.visibleItems() {
                item.refreshEnvironmentAppearance()
            }
        }

        private func restorePendingOffsetIfPossible() {
            guard !isReset, let pendingRestoreOffsetY else { return }
            let maximumOffset = max(
                0,
                collectionView.frame.height - scrollView.contentSize.height
            )
            let target = min(pendingRestoreOffsetY, maximumOffset)
            isApplyingRestoration = true
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: target))
            scrollView.reflectScrolledClipView(scrollView.contentView)
            isApplyingRestoration = false
            self.pendingRestoreOffsetY = nil
            retainedScrollOffset.record(target)
            onScroll(target)
        }

        func collectionView(
            _ collectionView: NSCollectionView,
            layout collectionViewLayout: NSCollectionViewLayout,
            sizeForItemAt indexPath: IndexPath
        ) -> NSSize {
            PopularNativeGridGeometry.itemSize(for: collectionView.bounds.width)
        }

        func collectionView(
            _ collectionView: NSCollectionView,
            didEndDisplaying item: NSCollectionViewItem,
            forRepresentedObjectAt indexPath: IndexPath
        ) {
            guard let item = item as? PopularNativeCollectionItem else { return }
            item.invalidateImageRequests()
            item.clearHover()
        }
    }
}

struct PopularNativeGridUpdatePlan {
    let identityChanged: Bool
    let changedBVIDs: Set<String>
    let snapshotReloadBVIDs: [String]

    init<Content: Equatable>(
        previousBVIDs: [String],
        previousContents: [String: Content],
        updatedBVIDs: [String],
        updatedContents: [String: Content]
    ) {
        identityChanged = updatedBVIDs != previousBVIDs
        let changedBVIDs = Set(
            updatedBVIDs.filter {
                previousContents[$0] != updatedContents[$0]
            }
        )
        self.changedBVIDs = changedBVIDs
        let previousIdentities = Set(previousBVIDs)
        snapshotReloadBVIDs = updatedBVIDs.filter {
            previousIdentities.contains($0) && changedBVIDs.contains($0)
        }
    }
}

struct PopularNativeScrollOffsetRetention {
    private(set) var offsetY: CGFloat

    init(initialOffsetY: CGFloat) {
        offsetY = max(0, initialOffsetY)
    }

    mutating func record(_ offsetY: CGFloat) {
        self.offsetY = max(0, offsetY)
    }
}

enum PopularNativeGridGeometry {
    static let horizontalSpacing: CGFloat = 20
    static let verticalSpacing: CGFloat = 28
    static let contentPadding: CGFloat = 24
    static let topContentPadding: CGFloat = 0

    static func columnCount(for width: CGFloat) -> Int {
        let usableWidth = max(0, width - contentPadding * 2)
        let naturalCount = Int(
            (usableWidth + horizontalSpacing) / (240 + horizontalSpacing)
        )
        return min(5, max(2, naturalCount))
    }

    static func itemSize(for width: CGFloat) -> NSSize {
        let usableWidth = max(1, width - contentPadding * 2)
        let count = columnCount(for: width)
        let spacing = CGFloat(count - 1) * horizontalSpacing
        let cardWidth = floor((usableWidth - spacing) / CGFloat(count))
        return NSSize(width: cardWidth, height: floor(cardWidth * 9 / 16) + 84)
    }

    static func contentHeight(for width: CGFloat, itemCount: Int) -> CGFloat {
        guard itemCount > 0 else { return 0 }
        let columns = columnCount(for: width)
        let rows = (itemCount + columns - 1) / columns
        let itemHeight = itemSize(for: width).height
        return topContentPadding
            + CGFloat(rows) * itemHeight
            + CGFloat(rows - 1) * verticalSpacing
            + contentPadding
    }
}

@MainActor
struct PopularNativeCardContent: Equatable {
    let bvid: String
    let title: String
    let coverURL: URL?
    let avatarURL: URL?
    let viewCount: String
    let danmakuCount: String
    let duration: String
    let owner: String
    let accessibilityLabel: String

    init(video: PopularVideo) {
        let presentation = PopularVideoCardPresentation(video: video)
        bvid = presentation.bvid
        title = presentation.title
        coverURL = presentation.coverURL
        avatarURL = presentation.avatarURL
        viewCount = presentation.viewCountText
        danmakuCount = presentation.danmakuCountText
        duration = presentation.durationText
        owner = presentation.footerText
        accessibilityLabel = [
            presentation.title,
            presentation.ownerName,
            "播放 \(presentation.viewCountText)",
            "弹幕 \(presentation.danmakuCountText)",
            "时长 \(duration)",
        ].joined(separator: "，")
    }
}

struct PopularNativeReuseIdentity: Equatable {
    let bvid: String
    let generation: UInt64

    func accepts(_ result: PopularNativeReuseIdentity) -> Bool {
        self == result
    }
}

struct PopularNativeImageApplicationGate {
    static func accepts(
        currentIdentity: PopularNativeReuseIdentity?,
        resultIdentity: PopularNativeReuseIdentity,
        isCancelled: Bool
    ) -> Bool {
        !isCancelled && currentIdentity?.accepts(resultIdentity) == true
    }
}

extension NSUserInterfaceItemIdentifier {
    fileprivate static let popularNativeVideoCard = Self(
        "popular.native-video-card"
    )
}

@MainActor
private final class PopularNativeCollectionView: NSCollectionView {
    var onActivateSelection: ((String) -> Void)?
    private(set) var showsKeyboardSelection = false

    override func mouseDown(with event: NSEvent) {
        showsKeyboardSelection = false
        updateVisibleKeyboardSelection()
        let point = convert(event.locationInWindow, from: nil)
        let clickedIndexPath = indexPathForItem(at: point)
        super.mouseDown(with: event)
        guard
            let clickedIndexPath,
            let bvid = item(at: clickedIndexPath)?.representedObject as? String
        else { return }
        onActivateSelection?(bvid)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.charactersIgnoringModifiers == " ",
            let indexPath = selectionIndexPaths.first,
            let bvid = item(at: indexPath)?.representedObject as? String
        {
            onActivateSelection?(bvid)
            return
        }
        let columnCount = PopularNativeGridGeometry.columnCount(for: bounds.width)
        let delta: Int? =
            switch event.keyCode {
            case 123: -1
            case 124: 1
            case 125: columnCount
            case 126: -columnCount
            default: nil
            }
        if let delta, moveSelection(by: delta) {
            return
        }
        super.keyDown(with: event)
    }

    private func moveSelection(by delta: Int) -> Bool {
        let itemCount = numberOfItems(inSection: 0)
        guard itemCount > 0 else { return false }
        let visibleStart = indexPathsForVisibleItems().map(\.item).min() ?? 0
        let current = selectionIndexPaths.first?.item ?? visibleStart
        let target = min(itemCount - 1, max(0, current + delta))
        let targetPath = IndexPath(item: target, section: 0)
        showsKeyboardSelection = true
        selectionIndexPaths = [targetPath]
        updateVisibleKeyboardSelection()
        scrollToItems(
            at: [targetPath],
            scrollPosition: .nearestHorizontalEdge
        )
        DispatchQueue.main.async { [weak self] in
            self?.updateVisibleKeyboardSelection()
        }
        return true
    }

    private func updateVisibleKeyboardSelection() {
        for case let item as PopularNativeCollectionItem in visibleItems() {
            item.setKeyboardFocusVisible(
                showsKeyboardSelection && item.isSelected
            )
        }
    }
}

@MainActor
private final class PopularNativeCollectionItem: NSCollectionViewItem {
    private let card = PopularNativeCardView()
    private var coverTask: Task<Void, Never>?
    private var avatarTask: Task<Void, Never>?
    private var reuseIdentity: PopularNativeReuseIdentity?
    private var generation: UInt64 = 0
    private var activation: ((String) -> Void)?
    private var hoverChanged: ((PopularNativeCollectionItem, Bool) -> Void)?

    override var isSelected: Bool {
        didSet { card.setSelected(isSelected) }
    }

    override var highlightState: NSCollectionViewItem.HighlightState {
        didSet { card.setPressed(highlightState == .forSelection) }
    }

    override func loadView() {
        view = card
    }

    func configure(
        content: PopularNativeCardContent,
        imagePipeline: PopularNativeImagePipeline,
        hoverChanged: @escaping (PopularNativeCollectionItem, Bool) -> Void,
        activation: @escaping (String) -> Void
    ) {
        invalidateImageRequests()
        generation &+= 1
        let identity = PopularNativeReuseIdentity(
            bvid: content.bvid,
            generation: generation
        )
        reuseIdentity = identity
        self.activation = activation
        self.hoverChanged = hoverChanged
        representedObject = content.bvid
        card.configure(
            content: content,
            hoverDidChange: { [weak self] isHovered in
                guard let self else { return }
                self.hoverChanged?(self, isHovered)
            },
            activation: { [weak self] in
                guard let bvid = self?.reuseIdentity?.bvid else { return }
                self?.activation?(bvid)
            }
        )
        coverTask = loadImage(
            at: content.coverURL,
            identity: identity,
            pipeline: imagePipeline
        ) { [weak card] image, shouldAnimate in
            card?.setCover(image, animated: shouldAnimate)
        }
        avatarTask = loadImage(
            at: content.avatarURL,
            identity: identity,
            pipeline: imagePipeline
        ) { [weak card] image, shouldAnimate in
            card?.setAvatar(image, animated: shouldAnimate)
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        invalidate()
    }

    func invalidateImageRequests() {
        coverTask?.cancel()
        avatarTask?.cancel()
        coverTask = nil
        avatarTask = nil
    }

    func invalidate() {
        invalidateImageRequests()
        generation &+= 1
        reuseIdentity = nil
        activation = nil
        representedObject = nil
        card.reset()
        hoverChanged = nil
    }

    func setHovered(_ isHovered: Bool) {
        card.setHovered(isHovered)
    }

    func clearHover() {
        card.setHovered(false)
    }

    func setKeyboardFocusVisible(_ isVisible: Bool) {
        card.setKeyboardFocusVisible(isVisible)
    }

    func refreshEnvironmentAppearance() {
        card.refreshEnvironmentAppearance()
    }

    private func loadImage(
        at url: URL?,
        identity: PopularNativeReuseIdentity,
        pipeline: PopularNativeImagePipeline,
        apply: @escaping @MainActor (CGImage?, Bool) -> Void
    ) -> Task<Void, Never>? {
        guard let url else {
            apply(nil, false)
            return nil
        }
        return Task { [weak self] in
            let result = await pipeline.image(for: url)
            guard
                PopularNativeImageApplicationGate.accepts(
                    currentIdentity: self?.reuseIdentity,
                    resultIdentity: identity,
                    isCancelled: Task.isCancelled
                )
            else { return }
            apply(result?.image, result?.origin.shouldAnimate ?? false)
        }
    }
}

enum PopularNativeImageLoadOrigin: Equatable {
    case memoryCache
    case network

    var shouldAnimate: Bool {
        self == .network
    }
}

struct PopularNativeImageLoadResult {
    let image: CGImage
    let origin: PopularNativeImageLoadOrigin
}

actor PopularNativeImagePipeline {
    static let cacheCountLimit = 120
    static let cacheCostLimit = 64 * 1_024 * 1_024

    nonisolated private let session: URLSession
    private var cache = PopularNativeImageCache(
        countLimit: cacheCountLimit,
        costLimit: cacheCostLimit
    )
    private var isShutdown = false

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration)
    }

    nonisolated func cancelAllRequests() {
        session.invalidateAndCancel()
    }

    func image(for url: URL) async -> PopularNativeImageLoadResult? {
        guard !isShutdown, url.scheme?.lowercased() == "https" else { return nil }
        if let image = cache.image(for: url) {
            return PopularNativeImageLoadResult(
                image: image,
                origin: .memoryCache
            )
        }
        do {
            var request = URLRequest(url: url)
            request.httpShouldHandleCookies = false
            let (data, response) = try await session.data(for: request)
            guard
                !Task.isCancelled,
                !isShutdown,
                let http = response as? HTTPURLResponse,
                (200..<300).contains(http.statusCode),
                let source = CGImageSourceCreateWithData(data as CFData, nil),
                let image = CGImageSourceCreateThumbnailAtIndex(
                    source,
                    0,
                    [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceThumbnailMaxPixelSize: 640,
                        kCGImageSourceShouldCacheImmediately: true,
                    ] as CFDictionary
                )
            else { return nil }
            cache.insert(image, for: url)
            return PopularNativeImageLoadResult(
                image: image,
                origin: .network
            )
        } catch {
            return nil
        }
    }

    func shutdown() {
        guard !isShutdown else { return }
        isShutdown = true
        cache.removeAll()
        session.invalidateAndCancel()
    }
}

struct PopularNativeImageCache {
    private struct Entry {
        let image: CGImage
        let cost: Int
        var recency: UInt64
    }

    let countLimit: Int
    let costLimit: Int
    private(set) var totalCost = 0
    private(set) var count = 0
    private var clock: UInt64 = 0
    private var entries: [URL: Entry] = [:]

    init(countLimit: Int, costLimit: Int) {
        self.countLimit = countLimit
        self.costLimit = costLimit
    }

    mutating func image(for url: URL) -> CGImage? {
        guard var entry = entries[url] else { return nil }
        clock &+= 1
        entry.recency = clock
        entries[url] = entry
        return entry.image
    }

    mutating func insert(_ image: CGImage, for url: URL) {
        let cost = image.bytesPerRow * image.height
        guard cost <= costLimit, countLimit > 0, costLimit > 0 else { return }
        if let old = entries.removeValue(forKey: url) {
            totalCost -= old.cost
        }
        clock &+= 1
        entries[url] = Entry(image: image, cost: cost, recency: clock)
        totalCost += cost
        trimToLimits()
        count = entries.count
    }

    mutating func removeAll() {
        entries.removeAll(keepingCapacity: false)
        totalCost = 0
        count = 0
    }

    private mutating func trimToLimits() {
        while entries.count > countLimit || totalCost > costLimit {
            guard let oldest = entries.min(by: { $0.value.recency < $1.value.recency }) else {
                break
            }
            totalCost -= oldest.value.cost
            entries.removeValue(forKey: oldest.key)
        }
    }
}

@MainActor
private final class PopularNativeCardView: NSView {
    private let coverContainer = PopularNativeFlippedView()
    private let cover = PopularNativeLayerImageView(
        placeholderSystemSymbolName: "photo",
        placeholderTintColor: .tertiaryLabelColor,
        placeholderFrameSize: NSSize(width: 32, height: 32)
    )
    private let coverOverlay = PopularNativeCoverOverlayView()
    private let avatar = PopularNativeLayerImageView(
        placeholderSystemSymbolName: "person.crop.circle.fill",
        placeholderTintColor: .quaternaryLabelColor
    )
    private let title = PopularNativeTextField(wrappingLabelWithString: "")
    private let owner = PopularNativeTextField(labelWithString: "")
    private var activation: (() -> Void)?
    private var hoverDidChange: ((Bool) -> Void)?
    private var trackingArea: NSTrackingArea?
    private var isHovered = false
    private var selected = false
    private var showsKeyboardFocus = false
    private var isPressed = false

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 12

        coverContainer.wantsLayer = true
        coverContainer.layer?.cornerRadius = 10
        coverContainer.layer?.masksToBounds = true
        coverContainer.layer?.backgroundColor =
            NSColor.secondaryLabelColor
            .withAlphaComponent(0.12).cgColor
        title.font = .systemFont(
            ofSize: NSFont.preferredFont(forTextStyle: .title3).pointSize,
            weight: .medium
        )
        title.maximumNumberOfLines = 2
        title.lineBreakMode = .byWordWrapping
        title.cell?.wraps = true
        title.cell?.truncatesLastVisibleLine = true
        owner.font = .preferredFont(forTextStyle: .body)
        owner.textColor = .secondaryLabelColor
        owner.lineBreakMode = .byTruncatingTail

        addSubview(coverContainer)
        for subview in [
            cover,
            coverOverlay,
        ] {
            subview.setAccessibilityElement(false)
            coverContainer.addSubview(subview)
        }
        for subview in [avatar, title, owner] {
            subview.setAccessibilityElement(false)
            addSubview(subview)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(
        content: PopularNativeCardContent,
        hoverDidChange: @escaping (Bool) -> Void,
        activation: @escaping () -> Void
    ) {
        self.activation = activation
        self.hoverDidChange = hoverDidChange
        title.stringValue = content.title
        coverOverlay.configure(
            viewCount: content.viewCount,
            danmakuCount: content.danmakuCount,
            duration: content.duration
        )
        owner.stringValue = content.owner
        setCover(nil, animated: false)
        setAvatar(nil, animated: false)
        setAccessibilityLabel(content.accessibilityLabel)
        setAccessibilityValue(selected ? "已选择" : nil)
        needsLayout = true
    }

    func setCover(_ image: CGImage?, animated: Bool = true) {
        cover.setImage(image, animated: animated)
    }

    func setAvatar(_ image: CGImage?, animated: Bool = true) {
        avatar.setImage(image, animated: animated)
    }

    func setSelected(_ selected: Bool) {
        self.selected = selected
        setAccessibilityValue(selected ? "已选择" : nil)
        updateInteractionAppearance()
    }

    func setKeyboardFocusVisible(_ isVisible: Bool) {
        guard showsKeyboardFocus != isVisible else { return }
        showsKeyboardFocus = isVisible
        updateInteractionAppearance()
    }

    func setPressed(_ isPressed: Bool) {
        self.isPressed = isPressed
        updateInteractionAppearance()
    }

    func setHovered(_ isHovered: Bool) {
        guard self.isHovered != isHovered else { return }
        self.isHovered = isHovered
        updateInteractionAppearance()
        hoverDidChange?(isHovered)
    }

    func reset() {
        layer?.removeAllAnimations()
        let wasHovered = isHovered
        activation = nil
        title.stringValue = ""
        coverOverlay.reset()
        owner.stringValue = ""
        setCover(nil, animated: false)
        setAvatar(nil, animated: false)
        isHovered = false
        selected = false
        showsKeyboardFocus = false
        isPressed = false
        updateInteractionAppearance(animated: false)
        setAccessibilityLabel(nil)
        setAccessibilityValue(nil)
        if wasHovered {
            hoverDidChange?(false)
        }
        hoverDidChange = nil
    }

    func refreshEnvironmentAppearance() {
        updateInteractionAppearance(animated: false)
    }

    override func layout() {
        super.layout()
        let coverHeight = floor(bounds.width * 9 / 16)
        coverContainer.frame = NSRect(x: 0, y: 0, width: bounds.width, height: coverHeight)
        cover.frame = coverContainer.bounds
        let overlayHeight = min(
            PopularNativeCoverOverlayView.preferredHeight,
            coverHeight
        )
        coverOverlay.frame = NSRect(
            x: 0,
            y: coverHeight - overlayHeight,
            width: bounds.width,
            height: overlayHeight
        )
        let textX: CGFloat = 44
        avatar.frame = NSRect(x: 0, y: coverHeight + 10, width: 34, height: 34)
        avatar.layer?.cornerRadius = 17
        title.frame = NSRect(
            x: textX,
            y: coverHeight + 10,
            width: max(1, bounds.width - textX),
            height: 47
        )
        owner.frame = NSRect(
            x: textX,
            y: coverHeight + 63,
            width: max(1, bounds.width - textX),
            height: 21
        )
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let updated = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow],
            owner: self
        )
        addTrackingArea(updated)
        trackingArea = updated
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func mouseEntered(with event: NSEvent) {
        setHovered(true)
    }

    override func mouseExited(with event: NSEvent) {
        setHovered(false)
    }

    override func accessibilityPerformPress() -> Bool {
        activation?()
        return true
    }

    private func updateInteractionAppearance(animated: Bool = true) {
        guard let layer else { return }
        let keyboardSelected = selected && showsKeyboardFocus
        let surfaceOpacity: CGFloat = isPressed ? 0.14 : (isHovered ? 0.08 : 0)
        let showsStroke = isHovered || keyboardSelected
        let targetBackground = NSColor.labelColor
            .withAlphaComponent(surfaceOpacity).cgColor
        let targetBorder =
            keyboardSelected
            ? NSColor.controlAccentColor.cgColor
            : NSColor.secondaryLabelColor.cgColor
        let targetBorderWidth: CGFloat =
            showsStroke
            ? (NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? 2 : 1)
            : 0
        let reducesMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let targetTransform =
            isPressed && !reducesMotion
            ? CATransform3DMakeScale(0.985, 0.985, 1)
            : CATransform3DIdentity
        let targetOpacity: Float = isPressed ? 0.82 : 1
        let duration = animated && !reducesMotion ? 0.12 : 0

        let presentation = layer.presentation()
        let fromBackground = presentation?.backgroundColor ?? layer.backgroundColor
        let fromBorder = presentation?.borderColor ?? layer.borderColor
        let fromBorderWidth = presentation?.borderWidth ?? layer.borderWidth
        let fromTransform = presentation?.transform ?? layer.transform
        let fromOpacity = presentation?.opacity ?? layer.opacity

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.backgroundColor = targetBackground
        layer.borderColor = showsStroke ? targetBorder : NSColor.clear.cgColor
        layer.borderWidth = targetBorderWidth
        layer.transform = targetTransform
        layer.opacity = targetOpacity
        CATransaction.commit()

        guard duration > 0 else {
            layer.removeAllAnimations()
            return
        }
        addAnimation(
            to: layer,
            keyPath: "backgroundColor",
            from: fromBackground,
            to: targetBackground,
            duration: duration
        )
        addAnimation(
            to: layer,
            keyPath: "borderColor",
            from: fromBorder,
            to: showsStroke ? targetBorder : NSColor.clear.cgColor,
            duration: duration
        )
        addAnimation(
            to: layer,
            keyPath: "borderWidth",
            from: fromBorderWidth,
            to: targetBorderWidth,
            duration: duration
        )
        addAnimation(
            to: layer,
            keyPath: "transform",
            from: fromTransform,
            to: targetTransform,
            duration: duration
        )
        addAnimation(
            to: layer,
            keyPath: "opacity",
            from: fromOpacity,
            to: targetOpacity,
            duration: duration
        )
    }

    private func addAnimation(
        to layer: CALayer,
        keyPath: String,
        from: Any?,
        to: Any,
        duration: CFTimeInterval
    ) {
        let animation = CABasicAnimation(keyPath: keyPath)
        animation.fromValue = from
        animation.toValue = to
        animation.duration = duration
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(animation, forKey: "popular-card.\(keyPath)")
    }
}

@MainActor
private final class PopularNativeTextField: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

@MainActor
private final class PopularNativeCoverOverlayView: NSView {
    static let preferredHeight: CGFloat = 35

    private static let metricBottomOffset: CGFloat = 22
    private static let leadingInset: CGFloat = 9
    private static let iconSize: CGFloat = 12
    private static let iconTextSpacing: CGFloat = 4
    private static let metricSpacing: CGFloat = 10
    private static let trailingInset: CGFloat = 9

    private let gradient = NSGradient(
        starting: .clear,
        ending: NSColor.black.withAlphaComponent(0.78)
    )
    private let playIcon = PopularNativeCoverOverlayView.makeSymbol(named: "play.fill")
    private let danmakuIcon = PopularNativeCoverOverlayView.makeSymbol(
        named: "text.bubble.fill"
    )
    private let viewCountCell = PopularNativeCoverOverlayView.makeLabelCell(
        font: .systemFont(ofSize: 12, weight: .medium)
    )
    private let danmakuCountCell = PopularNativeCoverOverlayView.makeLabelCell(
        font: .systemFont(ofSize: 12, weight: .medium)
    )
    private let durationCell = PopularNativeCoverOverlayView.makeLabelCell(
        font: .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
    )

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(
        viewCount: String,
        danmakuCount: String,
        duration: String
    ) {
        viewCountCell.stringValue = viewCount
        danmakuCountCell.stringValue = danmakuCount
        durationCell.stringValue = duration
        needsDisplay = true
    }

    func reset() {
        viewCountCell.stringValue = ""
        danmakuCountCell.stringValue = ""
        durationCell.stringValue = ""
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        gradient?.draw(
            from: NSPoint(x: bounds.midX, y: bounds.minY),
            to: NSPoint(x: bounds.midX, y: bounds.maxY),
            options: []
        )

        let metricY = bounds.height - Self.metricBottomOffset
        let playFrame = NSRect(
            x: Self.leadingInset,
            y: metricY + 2,
            width: Self.iconSize,
            height: Self.iconSize
        )
        draw(playIcon, in: playFrame)

        let viewCountFrame = draw(
            viewCountCell,
            at: NSPoint(x: playFrame.maxX + Self.iconTextSpacing, y: metricY)
        )
        let danmakuFrame = NSRect(
            x: viewCountFrame.maxX + Self.metricSpacing,
            y: metricY + 2,
            width: Self.iconSize,
            height: Self.iconSize
        )
        draw(danmakuIcon, in: danmakuFrame)
        _ = draw(
            danmakuCountCell,
            at: NSPoint(x: danmakuFrame.maxX + Self.iconTextSpacing, y: metricY)
        )

        let durationSize = integralSize(durationCell.cellSize)
        durationCell.draw(
            withFrame: NSRect(
                x: bounds.width - durationSize.width - Self.trailingInset,
                y: metricY,
                width: durationSize.width,
                height: durationSize.height
            ),
            in: self
        )
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    private func draw(_ image: NSImage?, in frame: NSRect) {
        image?.draw(
            in: frame,
            from: .zero,
            operation: .sourceOver,
            fraction: 1,
            respectFlipped: true,
            hints: nil
        )
    }

    @discardableResult
    private func draw(_ cell: NSTextFieldCell, at origin: NSPoint) -> NSRect {
        let size = integralSize(cell.cellSize)
        let frame = NSRect(origin: origin, size: size)
        cell.draw(withFrame: frame, in: self)
        return frame
    }

    private func integralSize(_ size: NSSize) -> NSSize {
        NSSize(width: ceil(size.width), height: ceil(size.height))
    }

    private static func makeLabelCell(font: NSFont) -> NSTextFieldCell {
        let cell = NSTextFieldCell(textCell: "")
        cell.font = font
        cell.textColor = .white
        cell.lineBreakMode = .byTruncatingTail
        cell.isBezeled = false
        cell.isBordered = false
        cell.drawsBackground = false
        cell.isEditable = false
        cell.isSelectable = false
        cell.usesSingleLineMode = true
        return cell
    }

    private static func makeSymbol(named name: String) -> NSImage? {
        let pointConfiguration = NSImage.SymbolConfiguration(
            pointSize: 11,
            weight: .medium
        )
        let colorConfiguration = NSImage.SymbolConfiguration(
            paletteColors: [.white]
        )
        return NSImage(
            systemSymbolName: name,
            accessibilityDescription: nil
        )?.withSymbolConfiguration(
            pointConfiguration.applying(colorConfiguration)
        )
    }
}

@MainActor
private final class PopularNativeFlippedView: NSView {
    override var isFlipped: Bool { true }
}

@MainActor
private final class PopularNativeLayerImageView: NSView {
    private let placeholderSystemSymbolName: String
    private let placeholderTintColor: NSColor
    private let placeholderFrameSize: NSSize?
    private let placeholderLayer = CALayer()

    init(
        placeholderSystemSymbolName: String,
        placeholderTintColor: NSColor,
        placeholderFrameSize: NSSize? = nil
    ) {
        self.placeholderSystemSymbolName = placeholderSystemSymbolName
        self.placeholderTintColor = placeholderTintColor
        self.placeholderFrameSize = placeholderFrameSize
        super.init(frame: .zero)
        wantsLayer = true
        layer?.contentsGravity = .resizeAspectFill
        layer?.masksToBounds = true
        placeholderLayer.contentsGravity = .center
        placeholderLayer.actions = [
            "contents": NSNull(),
            "hidden": NSNull(),
            "position": NSNull(),
            "bounds": NSNull(),
        ]
        layer?.addSublayer(placeholderLayer)
        refreshPlaceholderImage()
        setImage(nil, animated: false)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        let size = placeholderFrameSize ?? bounds.size
        placeholderLayer.frame = NSRect(
            x: floor((bounds.width - size.width) / 2),
            y: floor((bounds.height - size.height) / 2),
            width: size.width,
            height: size.height
        )
        placeholderLayer.contentsScale = window?.backingScaleFactor ?? 2
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshPlaceholderImage()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        needsLayout = true
    }

    func setImage(_ image: CGImage?, animated: Bool) {
        guard let layer else { return }
        layer.removeAnimation(forKey: "popular-image.fade")
        layer.contents = image
        placeholderLayer.isHidden = image != nil
        guard
            image != nil,
            animated,
            !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        else { return }
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = 0
        animation.toValue = 1
        animation.duration = 0.15
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(animation, forKey: "popular-image.fade")
    }

    private func refreshPlaceholderImage() {
        let colorConfiguration = NSImage.SymbolConfiguration(
            paletteColors: [placeholderTintColor]
        )
        placeholderLayer.contents = NSImage(
            systemSymbolName: placeholderSystemSymbolName,
            accessibilityDescription: nil
        )?.withSymbolConfiguration(colorConfiguration)
    }
}
