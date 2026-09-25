import AppKit
import BiliBrowseFeature
import BiliModels
import BiliUI

private final class NativePlaybackEpisodeIdentityBox: NSObject {
    let identity: VideoCollectionEpisodeIdentity

    init(_ identity: VideoCollectionEpisodeIdentity) {
        self.identity = identity
    }
}

private final class NativePlaybackSectionIdentityBox: NSObject {
    let identity: VideoCollectionSectionIdentity

    init(_ identity: VideoCollectionSectionIdentity) {
        self.identity = identity
    }
}

@MainActor
final class NativePlaybackSidebarSelectionItem: NSCollectionViewItem {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier(
        "NativePlaybackSidebarSelectionItem"
    )

    private let contentView = NativePlaybackSidebarSelectionView()

    override func loadView() {
        view = contentView
    }

    func configure(
        projection: PlaybackSelectionProjection,
        browsedSectionID: VideoCollectionSectionIdentity?,
        onSelectSection: @escaping (VideoCollectionSectionIdentity) -> Void,
        onSelectEpisode: @escaping (VideoCollectionEpisodeIdentity) -> Void,
        onSelectPage: @escaping (Int64) -> Void,
        onRetryPages: @escaping () -> Void
    ) {
        representedObject = projection
        contentView.configure(
            projection: projection,
            browsedSectionID: browsedSectionID,
            onSelectSection: onSelectSection,
            onSelectEpisode: onSelectEpisode,
            onSelectPage: onSelectPage,
            onRetryPages: onRetryPages
        )
    }

    override func prepareForReuse() {
        contentView.reset()
        representedObject = nil
        super.prepareForReuse()
    }
}

@MainActor
private final class NativePlaybackSidebarSelectionView: NSView {
    override var isFlipped: Bool { true }

    private let titleLabel = NSTextField(labelWithString: "")
    private let separator = NSBox()
    private let positionLabel = NSTextField(labelWithString: "")
    private let sectionLabel = NSTextField(labelWithString: AppStrings.localized("分区"))
    private let sectionPopUp = NSPopUpButton()
    private let episodeLabel = NSTextField(labelWithString: AppStrings.localized("选集"))
    private let episodePopUp = NSPopUpButton()
    private let placeholderLabel = NSTextField(wrappingLabelWithString: "")
    private let pageLabel = NSTextField(labelWithString: AppStrings.localized("分 P"))
    private let pagePopUp = NSPopUpButton()
    private let pageStatusLabel = NSTextField(labelWithString: "")
    private let progress = NSProgressIndicator()
    private let retryButton = NSButton(title: AppStrings.localized("重试"), target: nil, action: nil)
    private var projection: PlaybackSelectionProjection?
    private var browsedSectionID: VideoCollectionSectionIdentity?
    private var onSelectSection: ((VideoCollectionSectionIdentity) -> Void)?
    private var onSelectEpisode: ((VideoCollectionEpisodeIdentity) -> Void)?
    private var onSelectPage: ((Int64) -> Void)?
    private var onRetryPages: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        titleLabel.font = .systemFont(
            ofSize: NSFont.preferredFont(forTextStyle: .headline).pointSize,
            weight: .semibold
        )
        titleLabel.isSelectable = true
        positionLabel.font = .monospacedDigitSystemFont(
            ofSize: NSFont.preferredFont(forTextStyle: .callout).pointSize,
            weight: .regular
        )
        positionLabel.textColor = .secondaryLabelColor
        positionLabel.alignment = .right
        placeholderLabel.font = .preferredFont(forTextStyle: .callout)
        placeholderLabel.textColor = .secondaryLabelColor
        pageStatusLabel.font = .preferredFont(forTextStyle: .callout)
        pageStatusLabel.textColor = .secondaryLabelColor
        progress.style = .spinning
        progress.controlSize = .small
        retryButton.bezelStyle = .rounded
        retryButton.controlSize = .small
        retryButton.target = self
        retryButton.action = #selector(retryPages)
        sectionPopUp.target = self
        episodePopUp.target = self
        pagePopUp.target = self
        separator.boxType = .separator
        for subview in [
            separator,
            titleLabel,
            positionLabel,
            sectionLabel,
            sectionPopUp,
            episodeLabel,
            episodePopUp,
            placeholderLabel,
            pageLabel,
            pagePopUp,
            pageStatusLabel,
            progress,
            retryButton
        ] {
            addSubview(subview)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func configure(
        projection: PlaybackSelectionProjection,
        browsedSectionID: VideoCollectionSectionIdentity?,
        onSelectSection: @escaping (VideoCollectionSectionIdentity) -> Void,
        onSelectEpisode: @escaping (VideoCollectionEpisodeIdentity) -> Void,
        onSelectPage: @escaping (Int64) -> Void,
        onRetryPages: @escaping () -> Void
    ) {
        self.projection = projection
        self.browsedSectionID = resolvedSectionID(
            browsedSectionID,
            projection: projection
        )
        self.onSelectSection = onSelectSection
        self.onSelectEpisode = onSelectEpisode
        self.onSelectPage = onSelectPage
        self.onRetryPages = onRetryPages
        titleLabel.stringValue = projection.collectionTitle ?? ""
        positionLabel.stringValue =
            self.browsedSectionID == projection.selectedEpisodeSectionID
            ? projection.episodePositionText ?? "" : ""
        configureSection(projection)
        configureEpisode(projection)
        placeholderLabel.stringValue = projection.episodePlaceholder ?? ""
        configurePages(
            projection,
            isBrowsingSelectedSection:
                self.browsedSectionID == projection.selectedEpisodeSectionID
        )
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let width = bounds.width
        let labelWidth: CGFloat = 46
        separator.frame = NSRect(x: 0, y: 0, width: width, height: 1)
        var y = NativePlaybackSidebarItemMeasurement.sectionTopInset

        let showsTitle = !titleLabel.stringValue.isEmpty
        titleLabel.isHidden = !showsTitle
        positionLabel.isHidden = !showsTitle
        if showsTitle {
            titleLabel.frame = NSRect(x: 0, y: y, width: max(1, width - 70), height: 22)
            positionLabel.frame = NSRect(x: max(0, width - 70), y: y, width: 70, height: 22)
            y += 22 + NativePlaybackSidebarItemMeasurement.sectionSpacing
        }

        if !sectionLabel.isHidden {
            sectionLabel.frame = NSRect(x: 0, y: y + 3, width: labelWidth, height: 20)
            sectionPopUp.frame = NSRect(
                x: labelWidth + 8,
                y: y,
                width: max(1, width - labelWidth - 8),
                height: NativePlaybackSidebarItemMeasurement.rowHeight
            )
            y +=
                NativePlaybackSidebarItemMeasurement.rowHeight
                + NativePlaybackSidebarItemMeasurement.sectionSpacing
        }

        let showsEpisode = !episodeLabel.isHidden
        if showsEpisode {
            episodeLabel.frame = NSRect(x: 0, y: y + 3, width: labelWidth, height: 20)
            episodePopUp.frame = NSRect(
                x: labelWidth + 8,
                y: y,
                width: max(1, width - labelWidth - 8),
                height: NativePlaybackSidebarItemMeasurement.rowHeight
            )
            y +=
                NativePlaybackSidebarItemMeasurement.rowHeight
                + NativePlaybackSidebarItemMeasurement.sectionSpacing
        }

        let showsPlaceholder = !placeholderLabel.stringValue.isEmpty
        placeholderLabel.isHidden = !showsPlaceholder
        if showsPlaceholder {
            let height = NativePlaybackSidebarTextLayout.height(
                placeholderLabel.stringValue,
                width: width,
                font: .preferredFont(forTextStyle: .callout)
            )
            placeholderLabel.frame = NSRect(x: 0, y: y, width: width, height: height)
            y += height + NativePlaybackSidebarItemMeasurement.sectionSpacing
        }

        if !pageLabel.isHidden {
            pageLabel.frame = NSRect(x: 0, y: y + 3, width: labelWidth, height: 20)
            let controlX = labelWidth + 8
            let controlWidth = max(1, width - controlX)
            pagePopUp.frame = NSRect(
                x: controlX,
                y: y,
                width: controlWidth,
                height: NativePlaybackSidebarItemMeasurement.rowHeight
            )
            progress.frame = NSRect(x: controlX, y: y + 4, width: 16, height: 16)
            pageStatusLabel.frame = NSRect(
                x: controlX + (progress.isHidden ? 0 : 22),
                y: y + 3,
                width: max(1, controlWidth - (retryButton.isHidden ? 0 : 58)),
                height: 20
            )
            retryButton.frame = NSRect(
                x: max(controlX, width - 54),
                y: y,
                width: 54,
                height: NativePlaybackSidebarItemMeasurement.rowHeight
            )
        }
    }

    func reset() {
        projection = nil
        browsedSectionID = nil
        onSelectSection = nil
        onSelectEpisode = nil
        onSelectPage = nil
        onRetryPages = nil
        sectionPopUp.menu = nil
        episodePopUp.menu = nil
        pagePopUp.menu = nil
        titleLabel.stringValue = ""
        positionLabel.stringValue = ""
        placeholderLabel.stringValue = ""
        pageStatusLabel.stringValue = ""
        progress.stopAnimation(nil)
    }

    private func resolvedSectionID(
        _ requestedID: VideoCollectionSectionIdentity?,
        projection: PlaybackSelectionProjection
    ) -> VideoCollectionSectionIdentity? {
        if let requestedID,
            projection.episodeSections.contains(where: { $0.id == requestedID })
        {
            return requestedID
        }
        return projection.selectedEpisodeSectionID ?? projection.episodeSections.first?.id
    }

    private func configureSection(_ projection: PlaybackSelectionProjection) {
        sectionLabel.isHidden = !projection.showsSectionPicker
        sectionPopUp.isHidden = !projection.showsSectionPicker
        guard projection.showsSectionPicker else {
            sectionPopUp.menu = nil
            return
        }

        let menu = NSMenu(title: AppStrings.localized("分区"))
        var selectedItem: NSMenuItem?
        for (index, section) in projection.episodeSections.enumerated() {
            let item = NSMenuItem(
                title: section.title.isEmpty
                    ? AppStrings.localized("分区 \(index + 1)") : section.title,
                action: #selector(selectSection(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = NativePlaybackSectionIdentityBox(section.id)
            if section.id == browsedSectionID {
                selectedItem = item
                item.state = .on
            }
            menu.addItem(item)
        }
        sectionPopUp.menu = menu
        if let selectedItem {
            sectionPopUp.select(selectedItem)
        }
        sectionPopUp.setAccessibilityLabel(AppStrings.localized("分区"))
    }

    private func configureEpisode(_ projection: PlaybackSelectionProjection) {
        let showsEpisode = projection.showsEpisodePicker
        episodeLabel.isHidden = !showsEpisode
        episodePopUp.isHidden = !projection.showsEpisodePicker
        guard projection.showsEpisodePicker else { return }

        let menu = NSMenu(title: AppStrings.localized("选集"))
        var selectedItem: NSMenuItem?
        let displayedSection = projection.episodeSections.first {
            $0.id == browsedSectionID
        }
        for episode in displayedSection?.episodes ?? [] {
            let item = NSMenuItem(
                title: episode.title,
                action: #selector(selectEpisode(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = NativePlaybackEpisodeIdentityBox(episode.id)
            item.isEnabled = episode.isEnabled
            if episode.id == projection.selectedEpisodeID {
                selectedItem = item
                item.state = .on
            }
            menu.addItem(item)
        }
        if selectedItem == nil {
            let fallback = NSMenuItem(
                title: projection.selectedEpisodeID == nil
                    ? AppStrings.localized("当前视频不在合集目录中")
                    : AppStrings.localized("请选择选集"),
                action: nil,
                keyEquivalent: ""
            )
            fallback.isEnabled = false
            menu.insertItem(fallback, at: 0)
            selectedItem = fallback
        }
        episodePopUp.menu = menu
        if let selectedItem {
            episodePopUp.select(selectedItem)
        }
        episodePopUp.setAccessibilityLabel(AppStrings.localized("选集"))
    }

    @objc private func selectSection(_ sender: NSMenuItem) {
        guard let box = sender.representedObject as? NativePlaybackSectionIdentityBox,
            let projection
        else { return }
        browsedSectionID = box.identity
        positionLabel.stringValue =
            box.identity == projection.selectedEpisodeSectionID
            ? projection.episodePositionText ?? "" : ""
        configureEpisode(projection)
        configurePages(
            projection,
            isBrowsingSelectedSection:
                box.identity == projection.selectedEpisodeSectionID
        )
        needsLayout = true
        onSelectSection?(box.identity)
    }

    private func configurePages(
        _ projection: PlaybackSelectionProjection,
        isBrowsingSelectedSection: Bool
    ) {
        pagePopUp.menu = nil
        pagePopUp.isHidden = true
        pageStatusLabel.isHidden = true
        progress.isHidden = true
        progress.stopAnimation(nil)
        retryButton.isHidden = true
        pageLabel.isHidden = true
        guard isBrowsingSelectedSection else { return }

        switch projection.selectedPages {
        case .ready(let pages) where pages.count > 1:
            pageLabel.isHidden = false
            pagePopUp.isHidden = false
            let menu = NSMenu(title: AppStrings.localized("分 P"))
            var selectedItem: NSMenuItem?
            for page in pages {
                let title =
                    "P\(page.index) · \(page.title) · "
                    + VideoDurationFormatting.string(seconds: page.durationSeconds)
                let item = NSMenuItem(
                    title: title,
                    action: #selector(selectPage(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = NSNumber(value: page.cid)
                if page.cid == projection.selectedPageCID {
                    selectedItem = item
                    item.state = .on
                }
                menu.addItem(item)
            }
            if selectedItem == nil {
                let fallback = NSMenuItem(
                    title: AppStrings.localized("请选择分 P"),
                    action: nil,
                    keyEquivalent: ""
                )
                fallback.isEnabled = false
                menu.insertItem(fallback, at: 0)
                selectedItem = fallback
            }
            pagePopUp.menu = menu
            if let selectedItem {
                pagePopUp.select(selectedItem)
            }
            pagePopUp.setAccessibilityLabel(AppStrings.localized("分 P"))
        case .loading:
            pageLabel.isHidden = false
            pageStatusLabel.isHidden = false
            progress.isHidden = false
            progress.startAnimation(nil)
            pageStatusLabel.stringValue = AppStrings.localized("正在加载所选视频的分 P")
        case .failed:
            pageLabel.isHidden = false
            pageStatusLabel.isHidden = false
            retryButton.isHidden = false
            pageStatusLabel.stringValue = AppStrings.localized("无法加载所选视频的分 P")
        case .ready, .empty:
            break
        }
    }

    @objc private func selectEpisode(_ sender: NSMenuItem) {
        guard let box = sender.representedObject as? NativePlaybackEpisodeIdentityBox else {
            return
        }
        onSelectEpisode?(box.identity)
    }

    @objc private func selectPage(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? NSNumber else { return }
        onSelectPage?(value.int64Value)
    }

    @objc private func retryPages() {
        onRetryPages?()
    }
}
