import AppKit
import BiliBrowseFeature
import BiliModels
import BiliUI

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

        nameLabel.font = NativePlaybackUploaderGeometry.nameFont
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
            signatureButton
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
        nameLabel.setAccessibilityLabel(AppStrings.localized("UP 主，\(content.name)"))

        switch content.signature {
        case .loading:
            signatureText.isHidden = true
            signatureLoadingBar.isHidden = false
            signatureButton.isHidden = true
            signatureLoadingBar.setAccessibilityElement(true)
            signatureLoadingBar.setAccessibilityLabel(AppStrings.localized("签名正在加载"))
        case .hidden:
            signatureText.isHidden = true
            signatureLoadingBar.isHidden = true
            signatureButton.isHidden = true
        case .text:
            signatureText.isHidden = false
            signatureLoadingBar.isHidden = true
        }
        needsLayout = true
        if avatarChanged || avatar.image == nil {
            loadAvatar(content.avatarURL, imagePipeline: imagePipeline)
        }
    }

    override func layout() {
        super.layout()
        let avatarSize = NativePlaybackSidebarItemMeasurement.avatarSize
        avatar.frame = NSRect(x: 0, y: 0, width: avatarSize, height: avatarSize)
        guard let content else { return }
        let geometry = NativePlaybackUploaderGeometry(
            content: content,
            width: bounds.width,
            signatureExpanded: signatureExpanded
        )
        if case .text(let signature) = content.signature {
            updateSignatureText(signature, geometry: geometry)
        }
        nameLabel.frame = geometry.nameFrame
        signatureText.frame = geometry.signatureTextFrame
        signatureLoadingBar.frame = geometry.loadingBarFrame
        signatureButton.frame = geometry.signatureToggleFrame
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

    private func updateSignatureText(
        _ signature: String,
        geometry: NativePlaybackUploaderGeometry
    ) {
        let maximumLines = geometry.signatureMaximumLines
        signatureButton.isHidden = !geometry.signatureOverflows
        signatureButton.title =
            signatureExpanded
            ? AppStrings.localized("收起") : AppStrings.localized("展开")
        signatureButton.setAccessibilityLabel(AppStrings.localized("UP 主签名"))
        signatureButton.setAccessibilityValue(
            signatureExpanded
                ? AppStrings.localized("已展开，\(signature)")
                : AppStrings.localized("已收起，\(signature)")
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
            font: NativePlaybackUploaderGeometry.signatureFont,
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

    private let titleLabel = NSTextField(labelWithString: AppStrings.localized("简介"))
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
        let geometry = NativePlaybackSummaryGeometry(
            summary: summary,
            width: bounds.width,
            expanded: expanded
        )
        titleLabel.frame = geometry.titleFrame
        let maximumLines = geometry.maximumLines
        if !hasConfiguredText
            || configuredSummary != summary
            || configuredMaximumLines != maximumLines
        {
            hasConfiguredText = true
            configuredSummary = summary
            configuredMaximumLines = maximumLines
            textView.setText(
                summary,
                font: NativePlaybackSummaryGeometry.textFont,
                color: .secondaryLabelColor,
                maximumLines: maximumLines
            )
        }
        textView.frame = geometry.textFrame
        toggleButton.isHidden = !geometry.overflows
        toggleButton.title =
            expanded
            ? AppStrings.localized("收起") : AppStrings.localized("展开")
        toggleButton.setAccessibilityLabel(
            expanded ? AppStrings.localized("收起简介") : AppStrings.localized("展开简介")
        )
        toggleButton.setAccessibilityValue(
            expanded ? AppStrings.localized("已展开") : AppStrings.localized("已折叠为五行")
        )
        toggleButton.frame = geometry.toggleFrame
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
