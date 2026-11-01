import AppKit
import BiliModels
import BiliUI
import BiliVideoCollectionUI

/// 详情区顶部的 UP 主名片条目：头像、名字、签名与进入空间的入口。
///
/// 内容视图拥有头像加载 Task；复用前（`prepareForReuse`）与离屏（控制器在条目结束显示时调用
/// `releaseOffscreenResources`）取消并放下图片。
@MainActor
final class NativePlaybackDetailsUploaderItem: NSCollectionViewItem {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier(
        "NativePlaybackDetailsUploaderItem"
    )

    private let contentView = NativePlaybackDetailsUploaderView()

    override func loadView() {
        view = contentView
    }

    func configure(
        content: VideoUploaderHeaderContent,
        imagePipeline: any VideoDetailImageLoading,
        onOpenSpace: (() -> Void)?
    ) {
        representedObject = content
        contentView.configure(
            content: content,
            imagePipeline: imagePipeline,
            onOpenSpace: onOpenSpace
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

/// 名片的内容视图：拥有头像加载 Task 与它的代次，以及头像与名字这一行的可点区域。
///
/// `generation` 在每次取消或重新加载头像时递增；到达的头像只在代次与地址都仍相同时显示，否则丢弃。
@MainActor
private final class NativePlaybackDetailsUploaderView: NSView {
    override var isFlipped: Bool { true }

    private let avatar = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    /// 签名只显示一行，超出省略；被截断时指针移上去由系统原地浮出完整文字（expansion tooltip）。
    private let signatureLabel = NativePlaybackUploaderGeometry.makeSignatureLabel()
    private let signatureLoadingBar = NSView()
    /// 头像与名字这一行可点进入 UP 主空间；右侧箭头同时是给键盘与 VoiceOver 的显式按钮。
    private let spaceButton = NSButton(
        image: NSImage(
            systemSymbolName: "chevron.right",
            accessibilityDescription: VideoDetailFeatureStrings.localized("查看空间")
        ) ?? NSImage(),
        target: nil,
        action: nil
    )
    private var onOpenSpace: (() -> Void)?
    /// 只认头像与名字这一行，点签名不会进空间。
    private let spaceRegion = NativeClickRegion()
    private var imageTask: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var content: VideoUploaderHeaderContent?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        avatar.imageScaling = .scaleProportionallyUpOrDown
        avatar.contentTintColor = NativeAvatarPlaceholder.tintColor
        avatar.wantsLayer = true
        avatar.layer?.cornerRadius = NativePlaybackDetailsItemMeasurement.avatarSize / 2
        avatar.layer?.masksToBounds = true
        avatar.setAccessibilityElement(false)

        nameLabel.font = NativePlaybackUploaderGeometry.nameFont
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.maximumNumberOfLines = 1
        // 名字这一行可点，名字不再可选中复制，否则文本框会吃掉点击。
        nameLabel.isSelectable = false

        spaceButton.isBordered = false
        spaceButton.imagePosition = .imageOnly
        spaceButton.contentTintColor = .tertiaryLabelColor
        spaceButton.target = self
        spaceButton.action = #selector(openSpace)
        spaceButton.toolTip = VideoDetailFeatureStrings.localized("查看空间")
        spaceButton.setAccessibilityLabel(VideoDetailFeatureStrings.localized("查看空间"))
        spaceButton.isHidden = true
        spaceRegion.attach(to: self) { [weak self] in self?.openSpace() }

        signatureLoadingBar.wantsLayer = true
        signatureLoadingBar.layer?.cornerRadius = 3
        refreshLoadingBarColor()

        signatureLabel.setAccessibilityLabel(VideoDetailFeatureStrings.localized("UP 主签名"))

        for subview in [
            avatar,
            nameLabel,
            signatureLabel,
            signatureLoadingBar,
            spaceButton
        ] {
            addSubview(subview)
        }
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshLoadingBarColor()
    }

    private func refreshLoadingBarColor() {
        signatureLoadingBar.layer?.backgroundColor =
            NSColor.quaternaryLabelColor.cgColor(for: effectiveAppearance)
    }

    func configure(
        content: VideoUploaderHeaderContent,
        imagePipeline: any VideoDetailImageLoading,
        onOpenSpace: (() -> Void)?
    ) {
        self.onOpenSpace = onOpenSpace
        spaceButton.isHidden = onOpenSpace == nil
        let avatarChanged = self.content?.avatarURL != content.avatarURL
        if NativePlaybackUploaderProfileReveal.fades(from: self.content, to: content) {
            NativePlaybackDetailsFade.crossfade(
                self,
                key: "native-playback-uploader.profile-reveal"
            )
        }
        self.content = content
        nameLabel.stringValue = content.name
        nameLabel.textColor = NativeMemberNameColor.color(isVIP: content.isVIP)
        nameLabel.setAccessibilityLabel(
            content.isVIP
                ? VideoDetailFeatureStrings.localized("UP 主，\(content.name)，大会员")
                : VideoDetailFeatureStrings.localized("UP 主，\(content.name)")
        )

        switch content.signature {
        case .loading:
            signatureLabel.isHidden = true
            signatureLoadingBar.isHidden = false
            signatureLoadingBar.setAccessibilityElement(true)
            signatureLoadingBar.setAccessibilityLabel(VideoDetailFeatureStrings.localized("签名正在加载"))
        case .hidden:
            signatureLabel.isHidden = true
            signatureLoadingBar.isHidden = true
        case .text(let signature):
            signatureLabel.stringValue = signature
            signatureLabel.isHidden = false
            signatureLoadingBar.isHidden = true
        }
        needsLayout = true
        spaceRegion.setRects([spaceHitRect])
        if avatarChanged || avatar.image == nil {
            loadAvatar(content.avatarURL, imagePipeline: imagePipeline)
        }
    }

    override func layout() {
        super.layout()
        let avatarSize = NativePlaybackDetailsItemMeasurement.avatarSize
        avatar.frame = NSRect(x: 0, y: 0, width: avatarSize, height: avatarSize)
        guard let content else { return }
        let geometry = NativePlaybackUploaderGeometry(content: content, width: bounds.width)
        nameLabel.frame = geometry.nameFrame
        if !spaceButton.isHidden {
            let buttonSize = NativePlaybackUploaderGeometry.spaceButtonSize
            nameLabel.frame.size.width = max(
                0,
                geometry.nameFrame.width - buttonSize
                    - NativePlaybackUploaderGeometry.spaceButtonSpacing
            )
            spaceButton.frame = NSRect(
                x: bounds.width - buttonSize,
                y: geometry.nameFrame.midY - buttonSize / 2,
                width: buttonSize,
                height: buttonSize
            )
        }
        signatureLabel.frame = geometry.signatureTextFrame
        signatureLoadingBar.frame = geometry.loadingBarFrame
        spaceRegion.setRects([spaceHitRect])
    }

    /// 头像加上名字所在整行；没有签名时整块都可点；没有空间入口时为空。
    private var spaceHitRect: NSRect {
        guard onOpenSpace != nil, let content else { return .zero }
        if content.signature == .hidden {
            return bounds
        }
        let nameRow = NSRect(x: 0, y: 0, width: bounds.width, height: nameLabel.frame.maxY)
        return nameRow.union(avatar.frame)
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
        onOpenSpace = nil
        spaceButton.isHidden = true
        spaceRegion.setRects([spaceHitRect])
        avatar.image = nil
        nameLabel.stringValue = ""
        signatureLabel.stringValue = ""
        signatureLoadingBar.isHidden = true
    }

    private func loadAvatar(
        _ url: URL?,
        imagePipeline: any VideoDetailImageLoading
    ) {
        cancelImageRequest()
        avatar.image = NSImage(
            systemSymbolName: NativeAvatarPlaceholder.systemSymbolName,
            accessibilityDescription: nil
        )
        guard let url else { return }
        generation &+= 1
        let requestGeneration = generation
        if let cached = imagePipeline.cachedImage(for: url, purpose: .avatar) {
            avatar.image = NSImage(cgImage: cached, size: .zero)
            return
        }
        imageTask = Task { [weak self] in
            let result = await imagePipeline.image(for: url, purpose: .avatar)
            guard let self, !Task.isCancelled,
                self.generation == requestGeneration,
                self.content?.avatarURL == url,
                let result
            else { return }
            avatar.image = NSImage(cgImage: result.image, size: .zero)
            imageTask = nil
        }
    }

    @objc private func openSpace() {
        onOpenSpace?()
    }
}

/// 视频简介条目：可选择的正文、链接与时间戳，超过五行时可展开或收起；展开状态由详情区控制器持有。
@MainActor
final class NativePlaybackDetailsSummaryItem: NSCollectionViewItem {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier(
        "NativePlaybackDetailsSummaryItem"
    )

    private let contentView = NativePlaybackDetailsSummaryView()

    override func loadView() {
        view = contentView
    }

    func configure(
        summary: String,
        links: [CommentLink],
        timestampLimitSeconds: Int?,
        expanded: Bool,
        onToggle: @escaping () -> Void,
        onOpenLink: @escaping (CommentLinkTarget) -> Void
    ) {
        representedObject = summary
        contentView.configure(
            text: NativePlaybackDetailsLinkedText(
                text: summary,
                links: links,
                timestampLimitSeconds: timestampLimitSeconds
            ),
            expanded: expanded,
            onToggle: onToggle,
            onOpenLink: onOpenLink
        )
    }

    override func prepareForReuse() {
        contentView.reset()
        representedObject = nil
        super.prepareForReuse()
    }
}

/// 简介的内容视图：持有当前正文、展开状态与动作回调；高度由 `NativePlaybackSummaryGeometry` 决定，与测量一致。
@MainActor
private final class NativePlaybackDetailsSummaryView: NSView {
    override var isFlipped: Bool { true }

    private let titleLabel = NSTextField(labelWithString: VideoDetailFeatureStrings.localized("简介"))
    private let separator = NSBox()
    private let textView = NativePlaybackDetailsReadOnlyTextView(
        font: .preferredFont(forTextStyle: .callout),
        color: .secondaryLabelColor
    )
    private let toggleButton = NSButton()
    private var text = NativePlaybackDetailsLinkedText(
        text: "",
        links: [],
        timestampLimitSeconds: nil
    )
    private var expanded = false
    private var onToggle: (() -> Void)?
    private var configuredText: NativePlaybackDetailsLinkedText?
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

    func configure(
        text: NativePlaybackDetailsLinkedText,
        expanded: Bool,
        onToggle: @escaping () -> Void,
        onOpenLink: @escaping (CommentLinkTarget) -> Void
    ) {
        self.text = text
        self.expanded = expanded
        self.onToggle = onToggle
        textView.onOpenLink = onOpenLink
        needsLayout = true
    }

    override func layout() {
        super.layout()
        separator.frame = NSRect(x: 0, y: 0, width: bounds.width, height: 1)
        let geometry = NativePlaybackSummaryGeometry(
            summary: text.text,
            width: bounds.width,
            expanded: expanded
        )
        titleLabel.frame = geometry.titleFrame
        let maximumLines = geometry.maximumLines
        if !hasConfiguredText
            || configuredText != text
            || configuredMaximumLines != maximumLines
        {
            hasConfiguredText = true
            configuredText = text
            configuredMaximumLines = maximumLines
            textView.setText(
                text,
                font: NativePlaybackSummaryGeometry.textFont,
                color: .secondaryLabelColor,
                maximumLines: maximumLines
            )
        }
        textView.frame = geometry.textFrame
        toggleButton.isHidden = !geometry.overflows
        toggleButton.title =
            expanded
            ? VideoDetailFeatureStrings.localized("收起") : VideoDetailFeatureStrings.localized("展开")
        toggleButton.setAccessibilityLabel(
            expanded
                ? VideoDetailFeatureStrings.localized("收起简介")
                : VideoDetailFeatureStrings.localized("展开简介")
        )
        toggleButton.setAccessibilityValue(
            expanded
                ? VideoDetailFeatureStrings.localized("已展开")
                : VideoDetailFeatureStrings.localized("已折叠为五行")
        )
        toggleButton.frame = geometry.toggleFrame
    }

    func reset() {
        onToggle = nil
        textView.onOpenLink = nil
        text = NativePlaybackDetailsLinkedText(text: "", links: [], timestampLimitSeconds: nil)
        expanded = false
        textView.string = ""
        toggleButton.title = ""
        configuredText = nil
        configuredMaximumLines = nil
        hasConfiguredText = false
    }

    @objc private func toggle() {
        onToggle?()
    }
}
