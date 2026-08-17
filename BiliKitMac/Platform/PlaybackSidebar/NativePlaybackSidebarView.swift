import AppKit
import BiliApplication
import BiliBrowseFeature
import BiliModels
import SwiftUI

struct NativePlaybackSidebarView: View {
    let model: GuestVideoViewModel
    let onRetry: () -> Void
    let onSelectPlayback: (String, Int64?) -> Void

    var body: some View {
        NativePlaybackSidebarRepresentable(
            presentation: presentation,
            actions: NativePlaybackSidebarActions(
                retry: retry,
                selectEpisode: selectEpisode,
                selectPage: selectPage,
                retryPages: retryPages
            )
        )
        .navigationTitle("观看辅助")
    }

    private var presentation: NativePlaybackSidebarPresentation {
        let content = model.presentedContext.map { context in
            NativePlaybackSidebarContent(
                bvid: context.detail.bvid,
                uploader: VideoUploaderHeaderContent(
                    owner: context.detail.owner,
                    signatureState: model.uploaderSignatureState
                ),
                summary: context.detail.summary,
                selection: selectionProjection(context)
            )
        }
        return NativePlaybackSidebarPresentation(
            content: content,
            overlay: NativePlaybackSidebarOverlay.resolve(
                state: model.state,
                hasPresentedContent: content != nil
            )
        )
    }

    private func selectionProjection(
        _ context: GuestVideoContext
    ) -> PlaybackSelectionProjection {
        let episodes = context.detail.collection?.sections.flatMap(\.episodes) ?? []
        let pagesByEpisode = Dictionary(
            uniqueKeysWithValues: episodes.compactMap { episode in
                model.collectionEpisodePages(for: episode.id).map {
                    (episode.id, $0)
                }
            }
        )
        return PlaybackSelectionProjection(
            context: context,
            selectedEpisodeID: model.selectedCollectionEpisode,
            requestedBVID: model.requestedSelectionBVID,
            requestedCID: model.requestedPreferredCID,
            presentedIdentity: model.presentedPlaybackIdentity,
            pageStates: model.collectionEpisodePageStates,
            pagesByEpisode: pagesByEpisode
        )
    }

    private func retry() {
        if case .failedPage = model.state {
            model.retry()
        } else {
            onRetry()
        }
    }

    private func selectEpisode(_ identity: VideoCollectionEpisodeIdentity) {
        guard
            let episode = model.presentedContext?.detail.collection?.sections
                .flatMap(\.episodes)
                .first(where: { $0.id == identity })
        else { return }
        model.selectCollectionEpisode(episode) { bvid, preferredCID in
            onSelectPlayback(bvid, preferredCID)
        }
    }

    private func selectPage(_ bvid: String, _ cid: Int64) {
        onSelectPlayback(bvid, cid)
    }

    private func retryPages() {
        guard let identity = model.selectedCollectionEpisode,
            let episode = model.presentedContext?.detail.collection?.sections
                .flatMap(\.episodes)
                .first(where: { $0.id == identity })
        else { return }
        model.retryCollectionEpisodePages(episode)
    }
}

struct NativePlaybackSidebarActions {
    let retry: () -> Void
    let selectEpisode: (VideoCollectionEpisodeIdentity) -> Void
    let selectPage: (String, Int64) -> Void
    let retryPages: () -> Void
}

private struct NativePlaybackSidebarRepresentable: NSViewRepresentable {
    let presentation: NativePlaybackSidebarPresentation
    let actions: NativePlaybackSidebarActions

    func makeCoordinator() -> NativePlaybackSidebarController {
        NativePlaybackSidebarController()
    }

    func makeNSView(context: Context) -> NativePlaybackSidebarRootView {
        context.coordinator.update(presentation: presentation, actions: actions)
        return context.coordinator.rootView
    }

    func updateNSView(
        _ view: NativePlaybackSidebarRootView,
        context: Context
    ) {
        context.coordinator.update(presentation: presentation, actions: actions)
    }

    static func dismantleNSView(
        _ view: NativePlaybackSidebarRootView,
        coordinator: NativePlaybackSidebarController
    ) {
        coordinator.tearDown()
    }
}

@MainActor
final class NativePlaybackSidebarRootView: NSView {
    let scrollView = NSScrollView()
    let overlayView = NativePlaybackSidebarOverlayView()
    var viewportSizeDidChange: ((CGSize) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.usesPredominantAxisScrolling = true
        scrollView.verticalScrollElasticity = .automatic
        scrollView.horizontalScrollElasticity = .none
        scrollView.automaticallyAdjustsContentInsets = false
        addSubview(scrollView)
        addSubview(overlayView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func layout() {
        super.layout()
        scrollView.frame = bounds
        overlayView.frame = bounds
        viewportSizeDidChange?(scrollView.contentSize)
    }
}

@MainActor
final class NativePlaybackSidebarController: NSObject, NSCollectionViewDelegate {
    let rootView = NativePlaybackSidebarRootView()
    private let collectionView = NSCollectionView()
    private let layout = NativePlaybackSidebarLayout()
    private let imageOwner = NativeVideoImagePipelineOwner()
    private var dataSource:
        NSCollectionViewDiffableDataSource<
            NativePlaybackSidebarSectionID,
            NativePlaybackSidebarItemID
        >?
    private var presentation = NativePlaybackSidebarPresentation(
        content: nil,
        overlay: .unavailable(title: "没有播放上下文", message: "返回来源页并重新选择视频。")
    )
    private var actions = NativePlaybackSidebarActions(
        retry: {},
        selectEpisode: { _ in },
        selectPage: { _, _ in },
        retryPages: {}
    )
    private var itemIDs: [NativePlaybackSidebarItemID] = []
    private var summaryExpanded = false
    private var signatureExpanded = false
    private var browsedSectionID: VideoCollectionSectionIdentity?
    private var lastSelectedEpisodeID: VideoCollectionEpisodeIdentity?
    private var measuredViewportWidth: CGFloat = 0
    private var snapshotGeneration: UInt64 = 0
    private var isTornDown = false

    override init() {
        super.init()
        configureCollectionView()
        rootView.viewportSizeDidChange = { [weak self] size in
            self?.viewportSizeDidChange(size)
        }
    }

    func update(
        presentation: NativePlaybackSidebarPresentation,
        actions: NativePlaybackSidebarActions
    ) {
        guard !isTornDown else { return }
        self.actions = actions
        let previousPresentation = self.presentation
        let previousBVID = previousPresentation.content?.bvid
        let nextBVID = presentation.content?.bvid
        let changesIdentity =
            previousBVID != nil && nextBVID != nil
            && previousBVID != nextBVID
        if changesIdentity {
            summaryExpanded = false
            signatureExpanded = false
            browsedSectionID = nil
            lastSelectedEpisodeID = nil
        } else if previousPresentation.content?.uploader.signature
            != presentation.content?.uploader.signature
        {
            signatureExpanded = false
        }
        reconcileBrowsedSection(with: presentation.content?.selection)
        let changedItemIDs = presentation.changedItemIDs(
            comparedTo: previousPresentation
        )
        self.presentation = presentation
        updateOverlay()
        applySnapshot(
            resetToTop: changesIdentity,
            changedItemIDs: changedItemIDs
        )
    }

    func tearDown() {
        guard !isTornDown else { return }
        isTornDown = true
        snapshotGeneration &+= 1
        releaseCollectionFirstResponder()
        rootView.viewportSizeDidChange = nil
        for item in collectionView.visibleItems() {
            (item as? NativePlaybackSidebarUploaderItem)?.releaseOffscreenResources()
        }
        dataSource = nil
        itemIDs.removeAll()
        collectionView.delegate = nil
        rootView.scrollView.documentView = nil
        imageOwner.shutdown()
    }

    private func configureCollectionView() {
        collectionView.collectionViewLayout = layout
        collectionView.delegate = self
        collectionView.isSelectable = false
        collectionView.backgroundColors = [.clear]
        collectionView.register(
            NativePlaybackSidebarUploaderItem.self,
            forItemWithIdentifier: NativePlaybackSidebarUploaderItem.reuseIdentifier
        )
        collectionView.register(
            NativePlaybackSidebarSummaryItem.self,
            forItemWithIdentifier: NativePlaybackSidebarSummaryItem.reuseIdentifier
        )
        collectionView.register(
            NativePlaybackSidebarSelectionItem.self,
            forItemWithIdentifier: NativePlaybackSidebarSelectionItem.reuseIdentifier
        )
        collectionView.register(
            NativePlaybackSidebarUnavailableItem.self,
            forItemWithIdentifier: NativePlaybackSidebarUnavailableItem.reuseIdentifier
        )
        dataSource = NSCollectionViewDiffableDataSource(
            collectionView: collectionView
        ) { [weak self] collectionView, indexPath, itemID in
            self?.makeItem(
                collectionView: collectionView,
                indexPath: indexPath,
                itemID: itemID
            )
        }
        rootView.scrollView.documentView = collectionView
    }

    private func makeItem(
        collectionView: NSCollectionView,
        indexPath: IndexPath,
        itemID: NativePlaybackSidebarItemID
    ) -> NSCollectionViewItem? {
        guard let content = presentation.content else { return nil }
        switch itemID {
        case .uploader:
            guard
                let item = collectionView.makeItem(
                    withIdentifier: NativePlaybackSidebarUploaderItem.reuseIdentifier,
                    for: indexPath
                ) as? NativePlaybackSidebarUploaderItem
            else { return nil }
            item.configure(
                content: content.uploader,
                signatureExpanded: signatureExpanded,
                imagePipeline: imageOwner.pipeline,
                onToggleSignature: { [weak self] in self?.toggleSignature() }
            )
            return item
        case .summary:
            guard
                let item = collectionView.makeItem(
                    withIdentifier: NativePlaybackSidebarSummaryItem.reuseIdentifier,
                    for: indexPath
                ) as? NativePlaybackSidebarSummaryItem
            else { return nil }
            item.configure(
                summary: content.summary,
                expanded: summaryExpanded,
                onToggle: { [weak self] in self?.toggleSummary() }
            )
            return item
        case .selection:
            guard
                let item = collectionView.makeItem(
                    withIdentifier: NativePlaybackSidebarSelectionItem.reuseIdentifier,
                    for: indexPath
                ) as? NativePlaybackSidebarSelectionItem
            else { return nil }
            item.configure(
                projection: content.selection,
                browsedSectionID: browsedSectionID,
                onSelectSection: { [weak self] in self?.browseSection($0) },
                onSelectEpisode: { [weak self] in self?.actions.selectEpisode($0) },
                onSelectPage: { [weak self] cid in
                    guard self?.presentation.content?.bvid == content.bvid else { return }
                    self?.actions.selectPage(content.bvid, cid)
                },
                onRetryPages: { [weak self] in self?.actions.retryPages() }
            )
            return item
        case .commentsUnavailable:
            return collectionView.makeItem(
                withIdentifier: NativePlaybackSidebarUnavailableItem.reuseIdentifier,
                for: indexPath
            )
        }
    }

    private func reconcileBrowsedSection(
        with selection: PlaybackSelectionProjection?
    ) {
        guard let selection else {
            browsedSectionID = nil
            lastSelectedEpisodeID = nil
            return
        }
        let selectedEpisodeChanged =
            selection.selectedEpisodeID != lastSelectedEpisodeID
        let requestedSectionIsAvailable =
            browsedSectionID.map { requestedID in
                selection.episodeSections.contains(where: { $0.id == requestedID })
            } ?? false
        if selectedEpisodeChanged || !requestedSectionIsAvailable {
            browsedSectionID =
                selection.selectedEpisodeSectionID
                ?? selection.episodeSections.first?.id
        }
        lastSelectedEpisodeID = selection.selectedEpisodeID
    }

    private func applySnapshot(
        resetToTop: Bool,
        changedItemIDs: Set<NativePlaybackSidebarItemID>
    ) {
        guard let dataSource else { return }
        let anchor = resetToTop ? nil : captureAnchor()
        itemIDs = presentation.itemIDs
        var snapshot = NSDiffableDataSourceSnapshot<
            NativePlaybackSidebarSectionID,
            NativePlaybackSidebarItemID
        >()
        for section in presentation.sections {
            snapshot.appendSections([section.id])
            snapshot.appendItems(section.items, toSection: section.id)
        }
        if !changedItemIDs.isEmpty {
            let existing = Set(dataSource.snapshot().itemIdentifiers)
            let reloadable = itemIDs.filter {
                existing.contains($0) && changedItemIDs.contains($0)
            }
            if !reloadable.isEmpty {
                snapshot.reloadItems(reloadable)
            }
        }
        snapshotGeneration &+= 1
        let generation = snapshotGeneration
        dataSource.apply(snapshot, animatingDifferences: false) { [weak self] in
            guard let self, !self.isTornDown,
                self.snapshotGeneration == generation
            else { return }
            self.updateLayoutHeights()
            self.collectionView.layoutSubtreeIfNeeded()
            self.synchronizeDocumentFrame()
            if resetToTop {
                self.scrollToTop()
            } else if let anchor {
                self.restore(anchor)
            }
        }
    }

    private func updateLayoutHeights() {
        guard let content = presentation.content else {
            layout.update(entries: [], heights: [:])
            return
        }
        let width = max(
            80,
            rootView.scrollView.contentSize.width
                - NativePlaybackSidebarLayout.contentInset * 2
        )
        let heights = Dictionary(
            uniqueKeysWithValues: itemIDs.map { itemID in
                (itemID, height(for: itemID, content: content, width: width))
            }
        )
        let entries = itemIDs.compactMap { itemID in
            dataSource?.indexPath(for: itemID).map {
                NativePlaybackSidebarLayout.Entry(indexPath: $0, itemID: itemID)
            }
        }
        layout.update(entries: entries, heights: heights)
    }

    private func height(
        for itemID: NativePlaybackSidebarItemID,
        content: NativePlaybackSidebarContent,
        width: CGFloat
    ) -> CGFloat {
        switch itemID {
        case .uploader:
            NativePlaybackSidebarItemMeasurement.uploader(
                content.uploader,
                width: width,
                signatureExpanded: signatureExpanded
            )
        case .summary:
            NativePlaybackSidebarItemMeasurement.summary(
                content.summary,
                width: width,
                expanded: summaryExpanded
            )
        case .selection:
            NativePlaybackSidebarItemMeasurement.selection(
                content.selection,
                width: width,
                browsedSectionID: browsedSectionID
            )
        case .commentsUnavailable:
            NativePlaybackSidebarItemMeasurement.commentsUnavailable
        }
    }

    private func viewportSizeDidChange(_ size: CGSize) {
        guard !isTornDown, size.width > 0,
            abs(size.width - measuredViewportWidth) > 0.5
        else { return }
        let anchor = captureAnchor()
        measuredViewportWidth = size.width
        collectionView.frame.size.width = size.width
        updateLayoutHeights()
        collectionView.layoutSubtreeIfNeeded()
        synchronizeDocumentFrame()
        if let anchor {
            restore(anchor)
        }
    }

    private func toggleSummary() {
        mutateItem(.summary(bvid: presentation.content?.bvid ?? "")) {
            summaryExpanded.toggle()
        }
    }

    private func toggleSignature() {
        mutateItem(.uploader(bvid: presentation.content?.bvid ?? "")) {
            signatureExpanded.toggle()
        }
    }

    private func browseSection(_ sectionID: VideoCollectionSectionIdentity) {
        guard let bvid = presentation.content?.bvid else { return }
        mutateItem(.selection(bvid: bvid)) {
            browsedSectionID = sectionID
        }
    }

    private func mutateItem(
        _ itemID: NativePlaybackSidebarItemID,
        mutation: () -> Void
    ) {
        guard itemIDs.contains(itemID), let dataSource else { return }
        let anchor = captureAnchor()
        mutation()
        updateLayoutHeights()
        var snapshot = dataSource.snapshot()
        if snapshot.itemIdentifiers.contains(itemID) {
            snapshot.reloadItems([itemID])
        }
        snapshotGeneration &+= 1
        let generation = snapshotGeneration
        dataSource.apply(snapshot, animatingDifferences: false) { [weak self] in
            guard let self, !self.isTornDown,
                self.snapshotGeneration == generation
            else { return }
            self.collectionView.layoutSubtreeIfNeeded()
            self.synchronizeDocumentFrame()
            if let anchor {
                self.restore(anchor)
            }
        }
    }

    private struct Anchor {
        let itemID: NativePlaybackSidebarItemID
        let relativeY: CGFloat
    }

    private func captureAnchor() -> Anchor? {
        collectionView.layoutSubtreeIfNeeded()
        let viewport = rootView.scrollView.documentVisibleRect
        return collectionView.indexPathsForVisibleItems()
            .compactMap { indexPath -> (NativePlaybackSidebarItemID, NSRect)? in
                guard let itemID = dataSource?.itemIdentifier(for: indexPath),
                    let attributes = layout.layoutAttributesForItem(at: indexPath),
                    attributes.frame.intersects(viewport)
                else { return nil }
                return (itemID, attributes.frame)
            }
            .sorted { $0.1.minY < $1.1.minY }
            .first
            .map { Anchor(itemID: $0.0, relativeY: $0.1.minY - viewport.minY) }
    }

    private func restore(_ anchor: Anchor) {
        guard let indexPath = dataSource?.indexPath(for: anchor.itemID),
            let attributes = layout.layoutAttributesForItem(at: indexPath)
        else { return }
        scroll(to: attributes.frame.minY - anchor.relativeY)
    }

    private func synchronizeDocumentFrame() {
        let size = NSSize(
            width: rootView.scrollView.contentSize.width,
            height: max(
                rootView.scrollView.contentSize.height,
                layout.collectionViewContentSize.height
            )
        )
        guard collectionView.frame.size != size else { return }
        collectionView.setFrameSize(size)
    }

    private func scrollToTop() {
        scroll(to: 0)
    }

    private func scroll(to y: CGFloat) {
        synchronizeDocumentFrame()
        let maximumY = max(
            0,
            layout.collectionViewContentSize.height
                - rootView.scrollView.documentVisibleRect.height
        )
        rootView.scrollView.contentView.scroll(
            to: NSPoint(x: 0, y: min(max(0, y), maximumY))
        )
        rootView.scrollView.reflectScrolledClipView(rootView.scrollView.contentView)
    }

    private func updateOverlay() {
        let blocked = presentation.overlay.blocksContent
        if blocked, !collectionView.isHidden {
            releaseCollectionFirstResponder()
        }
        rootView.overlayView.configure(
            presentation.overlay,
            retry: { [weak self] in self?.actions.retry() }
        )
        rootView.scrollView.setAccessibilityHidden(blocked)
        rootView.scrollView.isHidden = false
        collectionView.isHidden = blocked
        rootView.overlayView.isHidden = !blocked
    }

    private func releaseCollectionFirstResponder() {
        guard let window = rootView.window,
            let responder = window.firstResponder,
            collectionOwnsFirstResponder(responder)
        else { return }
        window.makeFirstResponder(nil)
    }

    private func collectionOwnsFirstResponder(_ responder: NSResponder) -> Bool {
        if let responderView = responder as? NSView,
            responderView === collectionView
                || responderView.isDescendant(of: collectionView)
        {
            return true
        }
        return containsFieldEditor(responder, in: collectionView)
    }

    private func containsFieldEditor(
        _ responder: NSResponder,
        in view: NSView
    ) -> Bool {
        if let textField = view as? NSTextField,
            textField.currentEditor() === responder
        {
            return true
        }
        return view.subviews.contains {
            containsFieldEditor(responder, in: $0)
        }
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        didEndDisplaying item: NSCollectionViewItem,
        forRepresentedObjectAt indexPath: IndexPath
    ) {
        guard collectionView.indexPath(for: item) == nil else { return }
        (item as? NativePlaybackSidebarUploaderItem)?.releaseOffscreenResources()
    }
}

@MainActor
final class NativePlaybackSidebarOverlayView: NSView {
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    private let titleLabel = NSTextField(wrappingLabelWithString: "")
    private let messageLabel = NSTextField(wrappingLabelWithString: "")
    private let progress = NSProgressIndicator()
    private let retryButton = NSButton(title: "重试", target: nil, action: nil)
    private var retry: (() -> Void)?
    private var showsSkeleton = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        titleLabel.font = .systemFont(
            ofSize: NSFont.preferredFont(forTextStyle: .title3).pointSize,
            weight: .semibold
        )
        titleLabel.alignment = .center
        messageLabel.font = .preferredFont(forTextStyle: .body)
        messageLabel.textColor = .secondaryLabelColor
        messageLabel.alignment = .center
        progress.style = .spinning
        progress.controlSize = .small
        retryButton.bezelStyle = .rounded
        retryButton.target = self
        retryButton.action = #selector(retryAction)
        for subview in [titleLabel, messageLabel, progress, retryButton] {
            addSubview(subview)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func configure(
        _ overlay: NativePlaybackSidebarOverlay,
        retry: @escaping () -> Void
    ) {
        self.retry = retry
        showsSkeleton = false
        progress.stopAnimation(nil)
        progress.isHidden = true
        retryButton.isHidden = true
        switch overlay {
        case .none:
            titleLabel.stringValue = ""
            messageLabel.stringValue = ""
        case .loading(let label):
            showsSkeleton = true
            titleLabel.stringValue = ""
            messageLabel.stringValue = ""
            progress.isHidden = false
            progress.startAnimation(nil)
            setAccessibilityElement(true)
            setAccessibilityLabel(label)
        case .failure(let title, let message):
            titleLabel.stringValue = title
            messageLabel.stringValue = message
            retryButton.isHidden = false
            setAccessibilityElement(false)
        case .unavailable(let title, let message):
            titleLabel.stringValue = title
            messageLabel.stringValue = message
            setAccessibilityElement(false)
        }
        needsLayout = true
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        if showsSkeleton {
            progress.frame = NSRect(
                x: bounds.midX - 8,
                y: bounds.midY - 8,
                width: 16,
                height: 16
            )
            return
        }
        let contentWidth = max(120, min(280, bounds.width - 32))
        let titleHeight = titleLabel.sizeThatFits(
            NSSize(width: contentWidth, height: .greatestFiniteMagnitude)
        ).height
        let messageHeight = messageLabel.sizeThatFits(
            NSSize(width: contentWidth, height: .greatestFiniteMagnitude)
        ).height
        let buttonHeight: CGFloat = retryButton.isHidden ? 0 : 30
        let total =
            titleHeight + 8 + messageHeight
            + (buttonHeight > 0 ? 16 + buttonHeight : 0)
        var y = bounds.midY - total / 2
        titleLabel.frame = NSRect(
            x: bounds.midX - contentWidth / 2,
            y: y,
            width: contentWidth,
            height: titleHeight
        )
        y += titleHeight + 8
        messageLabel.frame = NSRect(
            x: bounds.midX - contentWidth / 2,
            y: y,
            width: contentWidth,
            height: messageHeight
        )
        y += messageHeight + 16
        retryButton.frame = NSRect(
            x: bounds.midX - 40,
            y: y,
            width: 80,
            height: buttonHeight
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard showsSkeleton else { return }
        let availableWidth = max(80, bounds.width - 32)
        let rects = [
            NSRect(x: 16, y: 24, width: 48, height: 48),
            NSRect(x: 76, y: 28, width: min(128, availableWidth - 60), height: 18),
            NSRect(x: 76, y: 52, width: min(196, availableWidth - 60), height: 12),
            NSRect(x: 16, y: 96, width: min(64, availableWidth), height: 18),
            NSRect(x: 16, y: 124, width: availableWidth, height: 13),
            NSRect(x: 16, y: 145, width: availableWidth * 0.82, height: 13),
            NSRect(x: 16, y: 184, width: min(132, availableWidth), height: 18),
            NSRect(x: 16, y: 214, width: availableWidth, height: 26),
            NSRect(x: 16, y: 250, width: availableWidth, height: 26),
        ]
        for (index, rect) in rects.enumerated() {
            (index < 2 ? NSColor.quaternaryLabelColor : NSColor.quinaryLabel)
                .setFill()
            NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()
        }
    }

    @objc private func retryAction() {
        retry?()
    }
}
