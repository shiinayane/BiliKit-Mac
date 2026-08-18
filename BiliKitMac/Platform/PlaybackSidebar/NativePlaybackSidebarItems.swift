import AppKit
import BiliBrowseFeature
import BiliModels
import BiliUI

@MainActor
enum NativePlaybackSidebarItemMeasurement {
    static let avatarSize: CGFloat = 48
    static let rowHeight: CGFloat = 26
    static let textSpacing: CGFloat = 4
    static let sectionSpacing: CGFloat = 10
    static let dividerInset: CGFloat = 8
    static let sectionTopInset: CGFloat = 13

    static func uploader(
        _ content: VideoUploaderHeaderContent,
        width: CGFloat,
        signatureExpanded: Bool
    ) -> CGFloat {
        let textWidth = max(80, width - avatarSize - 12)
        let nameHeight = ceil(NSFont.preferredFont(forTextStyle: .title3).pointSize * 1.35)
        let signatureHeight: CGFloat
        switch content.signature {
        case .hidden:
            signatureHeight = 0
        case .loading:
            signatureHeight = 14
        case .text(let signature):
            let font = NSFont.preferredFont(forTextStyle: .callout)
            let overflows =
                NativePlaybackSidebarTextLayout.singleLineWidth(signature, font: font)
                > textWidth
            let measuredWidth = overflows ? max(40, textWidth - 52) : textWidth
            signatureHeight = NativePlaybackSidebarTextLayout.height(
                signature,
                width: measuredWidth,
                font: font,
                maximumLines: overflows && !signatureExpanded ? 1 : nil
            )
        }
        let textHeight = nameHeight + (signatureHeight > 0 ? textSpacing + signatureHeight : 0)
        return max(avatarSize, textHeight)
    }

    static func summary(
        _ summary: String,
        width: CGFloat,
        expanded: Bool
    ) -> CGFloat {
        let headerHeight: CGFloat = 22
        let font = NSFont.preferredFont(forTextStyle: .callout)
        let fullTextHeight = NativePlaybackSidebarTextLayout.height(
            summary,
            width: width,
            font: font
        )
        let collapsedTextHeight = NativePlaybackSidebarTextLayout.height(
            summary,
            width: width,
            font: font,
            maximumLines: 5
        )
        let overflows = fullTextHeight > collapsedTextHeight + 0.5
        let textHeight = expanded && overflows ? fullTextHeight : collapsedTextHeight
        let toggleHeight: CGFloat = overflows ? 26 : 0
        return sectionTopInset + headerHeight + 8 + textHeight + toggleHeight
    }

    static func selection(
        _ projection: PlaybackSelectionProjection,
        width: CGFloat,
        browsedSectionID: VideoCollectionSectionIdentity?
    ) -> CGFloat {
        var heights: [CGFloat] = []
        if projection.collectionTitle != nil {
            heights.append(22)
        }
        if projection.showsSectionPicker {
            heights.append(rowHeight)
        }
        if projection.showsEpisodePicker {
            heights.append(rowHeight)
        }
        if let placeholder = projection.episodePlaceholder {
            heights.append(
                NativePlaybackSidebarTextLayout.height(
                    placeholder,
                    width: width,
                    font: .preferredFont(forTextStyle: .callout)
                )
            )
        }
        if browsedSectionID == projection.selectedEpisodeSectionID {
            switch projection.selectedPages {
            case .ready(let pages) where pages.count > 1:
                heights.append(rowHeight)
            case .loading, .failed:
                heights.append(rowHeight)
            case .ready, .empty:
                break
            }
        }
        guard !heights.isEmpty else { return 1 }
        return sectionTopInset + heights.reduce(0, +)
            + CGFloat(heights.count - 1) * sectionSpacing
    }
}

@MainActor
final class NativePlaybackSidebarReadOnlyTextView: NSTextView {
    init(font: NSFont, color: NSColor = .labelColor) {
        let storage = NSTextStorage()
        let manager = NSLayoutManager()
        let container = NSTextContainer(
            size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        )
        storage.addLayoutManager(manager)
        manager.addTextContainer(container)
        container.lineFragmentPadding = 0
        container.widthTracksTextView = true
        container.heightTracksTextView = false
        super.init(frame: .zero, textContainer: container)
        drawsBackground = false
        isEditable = false
        isSelectable = true
        isRichText = true
        isHorizontallyResizable = false
        isVerticallyResizable = false
        textContainerInset = .zero
        typingAttributes = [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: NativePlaybackSidebarTextLayout.paragraphStyle,
        ]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func layout() {
        textContainer?.containerSize = NSSize(
            width: max(1, bounds.width),
            height: CGFloat.greatestFiniteMagnitude
        )
        super.layout()
    }

    func setText(
        _ text: String,
        font: NSFont,
        color: NSColor,
        maximumLines: Int? = nil
    ) {
        let previousSelections = selectedRanges
        textContainer?.maximumNumberOfLines = maximumLines ?? 0
        textContainer?.lineBreakMode = maximumLines == nil ? .byCharWrapping : .byTruncatingTail
        textStorage?.setAttributedString(
            NSAttributedString(
                string: text,
                attributes: [
                    .font: font,
                    .foregroundColor: color,
                    .paragraphStyle: NativePlaybackSidebarTextLayout.paragraphStyle(
                        maximumLines: maximumLines
                    ),
                ]
            )
        )
        let textLength = (text as NSString).length
        selectedRanges = Self.clampedSelections(
            previousSelections,
            textLength: textLength
        )
    }

    static func clampedSelections(
        _ selections: [NSValue],
        textLength: Int
    ) -> [NSValue] {
        selections.map { value in
            let range = value.rangeValue
            let location = min(range.location, textLength)
            return NSValue(
                range: NSRange(
                    location: location,
                    length: min(range.length, textLength - location)
                )
            )
        }
    }
}

@MainActor
final class NativePlaybackSidebarUploaderItem: NSCollectionViewItem {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier(
        "NativePlaybackSidebarUploaderItem"
    )

    private let contentView = NativePlaybackSidebarUploaderView()

    override func loadView() {
        view = contentView
    }

    func configure(
        content: VideoUploaderHeaderContent,
        signatureExpanded: Bool,
        imagePipeline: NativeVideoImagePipeline,
        onToggleSignature: @escaping () -> Void
    ) {
        representedObject = content
        contentView.configure(
            content: content,
            signatureExpanded: signatureExpanded,
            imagePipeline: imagePipeline,
            onToggleSignature: onToggleSignature
        )
    }

    override func prepareForReuse() {
        contentView.reset()
        representedObject = nil
        super.prepareForReuse()
    }

    func releaseOffscreenResources() {
        contentView.releaseOffscreenResources()
    }
}

@MainActor
private final class NativePlaybackSidebarUploaderView: NSView {
    override var isFlipped: Bool { true }

    private let avatar = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let signatureText = NativePlaybackSidebarReadOnlyTextView(
        font: .preferredFont(forTextStyle: .callout),
        color: .secondaryLabelColor
    )
    private let signatureLoadingBar = NSView()
    private let signatureButton = NSButton()
    private var imageTask: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var content: VideoUploaderHeaderContent?
    private var signatureExpanded = false
    private var onToggleSignature: (() -> Void)?
    private var configuredSignature: String?
    private var configuredSignatureMaximumLines: Int?
    private var hasConfiguredSignatureText = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        avatar.imageScaling = .scaleProportionallyUpOrDown
        avatar.wantsLayer = true
        avatar.layer?.cornerRadius = NativePlaybackSidebarItemMeasurement.avatarSize / 2
        avatar.layer?.masksToBounds = true
        avatar.setAccessibilityElement(false)

        nameLabel.font = .systemFont(
            ofSize: NSFont.preferredFont(forTextStyle: .title3).pointSize,
            weight: .semibold
        )
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.maximumNumberOfLines = 1
        nameLabel.isSelectable = true

        signatureLoadingBar.wantsLayer = true
        signatureLoadingBar.layer?.cornerRadius = 3
        signatureLoadingBar.layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor

        signatureButton.isBordered = false
        signatureButton.font = .preferredFont(forTextStyle: .caption1)
        signatureButton.contentTintColor = .linkColor
        signatureButton.target = self
        signatureButton.action = #selector(toggleSignature)

        for subview in [
            avatar,
            nameLabel,
            signatureText,
            signatureLoadingBar,
            signatureButton,
        ] {
            addSubview(subview)
        }
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func configure(
        content: VideoUploaderHeaderContent,
        signatureExpanded: Bool,
        imagePipeline: NativeVideoImagePipeline,
        onToggleSignature: @escaping () -> Void
    ) {
        let avatarChanged = self.content?.avatarURL != content.avatarURL
        self.content = content
        self.signatureExpanded = signatureExpanded
        self.onToggleSignature = onToggleSignature
        nameLabel.stringValue = content.name
        nameLabel.setAccessibilityLabel("UP 主，\(content.name)")

        switch content.signature {
        case .loading:
            signatureText.isHidden = true
            signatureLoadingBar.isHidden = false
            signatureButton.isHidden = true
            signatureLoadingBar.setAccessibilityElement(true)
            signatureLoadingBar.setAccessibilityLabel("签名正在加载")
        case .hidden:
            signatureText.isHidden = true
            signatureLoadingBar.isHidden = true
            signatureButton.isHidden = true
        case .text(let signature):
            signatureText.isHidden = false
            signatureLoadingBar.isHidden = true
            updateSignatureTextIfNeeded(signature)
        }
        needsLayout = true
        if avatarChanged || avatar.image == nil {
            loadAvatar(content.avatarURL, imagePipeline: imagePipeline)
        }
    }

    override func layout() {
        super.layout()
        if case .text(let signature) = content?.signature {
            updateSignatureTextIfNeeded(signature)
        }
        let avatarSize = NativePlaybackSidebarItemMeasurement.avatarSize
        avatar.frame = NSRect(x: 0, y: 0, width: avatarSize, height: avatarSize)
        let textX = avatarSize + 12
        let textWidth = max(40, bounds.width - textX)
        let nameHeight = ceil(nameLabel.font?.pointSize ?? 17) * 1.35
        nameLabel.frame = NSRect(x: textX, y: 0, width: textWidth, height: nameHeight)
        let signatureY = nameHeight + NativePlaybackSidebarItemMeasurement.textSpacing
        let buttonWidth: CGFloat = signatureButton.isHidden ? 0 : 48
        signatureText.frame = NSRect(
            x: textX,
            y: signatureY,
            width: max(1, textWidth - buttonWidth),
            height: max(0, bounds.height - signatureY)
        )
        signatureLoadingBar.frame = NSRect(
            x: textX,
            y: signatureY + 2,
            width: min(196, textWidth),
            height: 14
        )
        signatureButton.frame = NSRect(
            x: bounds.width - buttonWidth,
            y: signatureY,
            width: buttonWidth,
            height: 20
        )
    }

    func cancelImageRequest() {
        generation &+= 1
        imageTask?.cancel()
        imageTask = nil
    }

    func releaseOffscreenResources() {
        cancelImageRequest()
        avatar.image = nil
    }

    func reset() {
        cancelImageRequest()
        content = nil
        onToggleSignature = nil
        avatar.image = nil
        nameLabel.stringValue = ""
        signatureText.string = ""
        signatureButton.isHidden = true
        signatureLoadingBar.isHidden = true
        configuredSignature = nil
        configuredSignatureMaximumLines = nil
        hasConfiguredSignatureText = false
    }

    private func loadAvatar(
        _ url: URL?,
        imagePipeline: NativeVideoImagePipeline
    ) {
        cancelImageRequest()
        avatar.image = NSImage(
            systemSymbolName: "person.crop.circle.fill",
            accessibilityDescription: nil
        )
        guard let url else { return }
        generation &+= 1
        let requestGeneration = generation
        if let cached = imagePipeline.cachedImage(for: url, variant: .avatar) {
            avatar.image = NSImage(cgImage: cached, size: .zero)
            return
        }
        imageTask = Task { [weak self] in
            let result = await imagePipeline.image(for: url, variant: .avatar)
            guard let self, !Task.isCancelled,
                self.generation == requestGeneration,
                self.content?.avatarURL == url,
                let result
            else { return }
            avatar.image = NSImage(cgImage: result.image, size: .zero)
            imageTask = nil
        }
    }

    private func updateSignatureTextIfNeeded(
        _ signature: String
    ) {
        let availableWidth = max(
            40,
            bounds.width - NativePlaybackSidebarItemMeasurement.avatarSize - 12
        )
        let font = NSFont.preferredFont(forTextStyle: .callout)
        let overflows =
            NativePlaybackSidebarTextLayout.singleLineWidth(signature, font: font)
            > availableWidth
        let maximumLines = overflows && !signatureExpanded ? 1 : nil
        signatureButton.isHidden = !overflows
        signatureButton.title = signatureExpanded ? "收起" : "展开"
        signatureButton.setAccessibilityLabel("UP 主签名")
        signatureButton.setAccessibilityValue(
            signatureExpanded ? "已展开，\(signature)" : "已收起，\(signature)"
        )
        guard
            !hasConfiguredSignatureText
                || configuredSignature != signature
                || configuredSignatureMaximumLines != maximumLines
        else { return }
        hasConfiguredSignatureText = true
        configuredSignature = signature
        configuredSignatureMaximumLines = maximumLines
        signatureText.setText(
            signature,
            font: font,
            color: .secondaryLabelColor,
            maximumLines: maximumLines
        )
    }

    @objc private func toggleSignature() {
        onToggleSignature?()
    }
}

@MainActor
final class NativePlaybackSidebarSummaryItem: NSCollectionViewItem {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier(
        "NativePlaybackSidebarSummaryItem"
    )

    private let contentView = NativePlaybackSidebarSummaryView()

    override func loadView() {
        view = contentView
    }

    func configure(
        summary: String,
        expanded: Bool,
        onToggle: @escaping () -> Void
    ) {
        representedObject = summary
        contentView.configure(summary: summary, expanded: expanded, onToggle: onToggle)
    }

    override func prepareForReuse() {
        contentView.reset()
        representedObject = nil
        super.prepareForReuse()
    }
}

@MainActor
private final class NativePlaybackSidebarSummaryView: NSView {
    override var isFlipped: Bool { true }

    private let titleLabel = NSTextField(labelWithString: "简介")
    private let separator = NSBox()
    private let textView = NativePlaybackSidebarReadOnlyTextView(
        font: .preferredFont(forTextStyle: .callout),
        color: .secondaryLabelColor
    )
    private let toggleButton = NSButton()
    private var summary = ""
    private var expanded = false
    private var onToggle: (() -> Void)?
    private var configuredSummary: String?
    private var configuredMaximumLines: Int?
    private var hasConfiguredText = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        titleLabel.font = .systemFont(
            ofSize: NSFont.preferredFont(forTextStyle: .headline).pointSize,
            weight: .semibold
        )
        toggleButton.isBordered = false
        toggleButton.font = .preferredFont(forTextStyle: .caption1)
        toggleButton.contentTintColor = .linkColor
        toggleButton.alignment = .left
        toggleButton.target = self
        toggleButton.action = #selector(toggle)
        separator.boxType = .separator
        addSubview(separator)
        addSubview(titleLabel)
        addSubview(textView)
        addSubview(toggleButton)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func configure(summary: String, expanded: Bool, onToggle: @escaping () -> Void) {
        self.summary = summary
        self.expanded = expanded
        self.onToggle = onToggle
        needsLayout = true
    }

    override func layout() {
        super.layout()
        separator.frame = NSRect(x: 0, y: 0, width: bounds.width, height: 1)
        titleLabel.frame = NSRect(
            x: 0,
            y: NativePlaybackSidebarItemMeasurement.sectionTopInset,
            width: bounds.width,
            height: 22
        )
        let font = NSFont.preferredFont(forTextStyle: .callout)
        let collapsedHeight = NativePlaybackSidebarTextLayout.height(
            summary,
            width: bounds.width,
            font: font,
            maximumLines: 5
        )
        let fullHeight = NativePlaybackSidebarTextLayout.height(
            summary,
            width: bounds.width,
            font: font
        )
        let overflows = fullHeight > collapsedHeight + 0.5
        let showsExpandedText = expanded && overflows
        let textHeight = showsExpandedText ? fullHeight : collapsedHeight
        let maximumLines = overflows && !expanded ? 5 : nil
        if !hasConfiguredText
            || configuredSummary != summary
            || configuredMaximumLines != maximumLines
        {
            hasConfiguredText = true
            configuredSummary = summary
            configuredMaximumLines = maximumLines
            textView.setText(
                summary,
                font: font,
                color: .secondaryLabelColor,
                maximumLines: maximumLines
            )
        }
        textView.frame = NSRect(
            x: 0,
            y: NativePlaybackSidebarItemMeasurement.sectionTopInset + 30,
            width: bounds.width,
            height: textHeight
        )
        toggleButton.isHidden = !overflows
        toggleButton.title = expanded ? "收起" : "展开"
        toggleButton.setAccessibilityLabel(expanded ? "收起简介" : "展开简介")
        toggleButton.setAccessibilityValue(expanded ? "已展开" : "已折叠为五行")
        toggleButton.frame = NSRect(
            x: 0,
            y: textView.frame.maxY + 4,
            width: min(56, bounds.width),
            height: overflows ? 22 : 0
        )
    }

    func reset() {
        onToggle = nil
        summary = ""
        expanded = false
        textView.string = ""
        toggleButton.title = ""
        configuredSummary = nil
        configuredMaximumLines = nil
        hasConfiguredText = false
    }

    @objc private func toggle() {
        onToggle?()
    }
}

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
    private let sectionLabel = NSTextField(labelWithString: "分区")
    private let sectionPopUp = NSPopUpButton()
    private let episodeLabel = NSTextField(labelWithString: "选集")
    private let episodePopUp = NSPopUpButton()
    private let placeholderLabel = NSTextField(wrappingLabelWithString: "")
    private let pageLabel = NSTextField(labelWithString: "分 P")
    private let pagePopUp = NSPopUpButton()
    private let pageStatusLabel = NSTextField(labelWithString: "")
    private let progress = NSProgressIndicator()
    private let retryButton = NSButton(title: "重试", target: nil, action: nil)
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
            retryButton,
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

        let menu = NSMenu(title: "分区")
        var selectedItem: NSMenuItem?
        for (index, section) in projection.episodeSections.enumerated() {
            let item = NSMenuItem(
                title: section.title.isEmpty ? "分区 \(index + 1)" : section.title,
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
        sectionPopUp.setAccessibilityLabel("分区")
    }

    private func configureEpisode(_ projection: PlaybackSelectionProjection) {
        let showsEpisode = projection.showsEpisodePicker
        episodeLabel.isHidden = !showsEpisode
        episodePopUp.isHidden = !projection.showsEpisodePicker
        guard projection.showsEpisodePicker else { return }

        let menu = NSMenu(title: "选集")
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
                    ? "当前视频不在合集目录中" : "请选择选集",
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
        episodePopUp.setAccessibilityLabel("选集")
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
            let menu = NSMenu(title: "分 P")
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
                let fallback = NSMenuItem(title: "请选择分 P", action: nil, keyEquivalent: "")
                fallback.isEnabled = false
                menu.insertItem(fallback, at: 0)
                selectedItem = fallback
            }
            pagePopUp.menu = menu
            if let selectedItem {
                pagePopUp.select(selectedItem)
            }
            pagePopUp.setAccessibilityLabel("分 P")
        case .loading:
            pageLabel.isHidden = false
            pageStatusLabel.isHidden = false
            progress.isHidden = false
            progress.startAnimation(nil)
            pageStatusLabel.stringValue = "正在加载所选视频的分 P"
        case .failed:
            pageLabel.isHidden = false
            pageStatusLabel.isHidden = false
            retryButton.isHidden = false
            pageStatusLabel.stringValue = "无法加载所选视频的分 P"
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

@MainActor
final class NativePlaybackSidebarUnavailableItem: NSCollectionViewItem {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier(
        "NativePlaybackSidebarUnavailableItem"
    )

    private let titleLabel = NSTextField(labelWithString: "评论尚未接入")
    private let messageLabel = NSTextField(
        wrappingLabelWithString: "当前版本不会伪造评论内容。"
    )
    private let separator = NSBox()

    override func loadView() {
        let root = NativePlaybackSidebarFlippedView()
        titleLabel.font = .systemFont(
            ofSize: NSFont.preferredFont(forTextStyle: .headline).pointSize,
            weight: .semibold
        )
        messageLabel.font = .preferredFont(forTextStyle: .callout)
        messageLabel.textColor = .secondaryLabelColor
        separator.boxType = .separator
        for subview in [separator, titleLabel, messageLabel] {
            root.addSubview(subview)
        }
        view = root
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        separator.frame = NSRect(
            x: 0,
            y: 0,
            width: view.bounds.width,
            height: 1
        )
        titleLabel.frame = NSRect(x: 0, y: 13, width: view.bounds.width, height: 20)
        messageLabel.frame = NSRect(x: 0, y: 35, width: view.bounds.width, height: 18)
    }
}

@MainActor
final class NativePlaybackSidebarFlippedView: NSView {
    override var isFlipped: Bool { true }
}
