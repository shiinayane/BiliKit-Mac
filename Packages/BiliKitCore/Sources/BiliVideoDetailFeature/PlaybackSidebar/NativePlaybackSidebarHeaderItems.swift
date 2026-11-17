import AppKit
import BiliApplication
import BiliModels
import BiliUI
import BiliVideoCollectionUI

/// 侧栏顶部的 UP 主名片条目：头像、名字、粉丝与投稿数、签名、进入空间的入口与关注按钮。
///
/// 内容视图拥有头像加载 Task；复用前（`prepareForReuse`）与离屏（控制器在条目结束显示时调用
/// `releaseOffscreenResources`）取消并放下图片。
@MainActor
final class NativePlaybackSidebarUploaderItem: NativeLayoutSizedCollectionItem {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier(
        "NativePlaybackSidebarUploaderItem"
    )

    private let contentView = NativePlaybackSidebarUploaderView()

    override func loadView() {
        view = contentView
    }

    /// 接上关注按钮的两个出口，都只转发意图，门槛与写入在 App 的写入协调者。
    ///
    /// `onSetFollowing` 收到点按后的目标状态（true 为关注）；已关注且给了 `onShowFollowingMenu` 时点按改为交出按钮，由调用方
    /// 在它下方弹出「已关注」菜单。
    func configure(
        content: VideoUploaderHeaderContent,
        imagePipeline: any VideoDetailImageLoading,
        onOpenSpace: (() -> Void)?,
        onSetFollowing: ((Bool) -> Void)? = nil,
        onShowFollowingMenu: ((NSView) -> Void)? = nil
    ) {
        representedObject = content
        contentView.configure(
            content: content,
            imagePipeline: imagePipeline,
            onOpenSpace: onOpenSpace,
            onSetFollowing: onSetFollowing,
            onShowFollowingMenu: onShowFollowingMenu
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
private final class NativePlaybackSidebarUploaderView: NSView {
    override var isFlipped: Bool { true }

    private let avatar = NSImageView()
    private let nameLabel = NativePlaybackUploaderGeometry.makeNameLabel()
    /// 计数与签名都只显示一行，超出省略；被截断时指针移上去由系统原地浮出完整文字（expansion tooltip）。
    private let statsLabel = NativePlaybackUploaderGeometry.makeStatsLabel()
    private let signatureLabel = NativePlaybackUploaderGeometry.makeSignatureLabel()
    private let statsLoadingBar = NSView()
    private let signatureLoadingBar = NSView()
    /// 头像与名字这一行可点进入 UP 主空间；行尾的箭头同时是给键盘与 VoiceOver 的显式按钮。
    private let spaceButton = NSButton(
        image: NSImage(
            systemSymbolName: "chevron.right",
            accessibilityDescription: VideoDetailFeatureStrings.localized("查看空间")
        ) ?? NSImage(),
        target: nil,
        action: nil
    )
    /// 未关注时点一下关注，已关注时点开「已关注」菜单（没有菜单时点一下取消关注）；不在空间入口的可点区域里，点它不会
    /// 进空间。
    private let followButton = NativePlaybackUploaderGeometry.makeFollowButton()
    private var onOpenSpace: (() -> Void)?
    private var onSetFollowing: ((Bool) -> Void)?
    private var onShowFollowingMenu: ((NSView) -> Void)?
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
        avatar.layer?.cornerRadius = NativePlaybackSidebarItemMeasurement.avatarSize / 2
        avatar.layer?.masksToBounds = true
        avatar.setAccessibilityElement(false)

        spaceButton.isBordered = false
        spaceButton.imagePosition = .imageOnly
        spaceButton.contentTintColor = .tertiaryLabelColor
        spaceButton.target = self
        spaceButton.action = #selector(openSpace)
        spaceButton.toolTip = VideoDetailFeatureStrings.localized("查看空间")
        spaceButton.setAccessibilityLabel(VideoDetailFeatureStrings.localized("查看空间"))
        spaceButton.isHidden = true
        spaceRegion.attach(to: self) { [weak self] in self?.openSpace() }

        followButton.target = self
        followButton.action = #selector(toggleFollowing)
        followButton.isHidden = true

        for bar in [statsLoadingBar, signatureLoadingBar] {
            bar.wantsLayer = true
            bar.layer?.cornerRadius = 3
        }
        // 两条占位属于同一次名片加载，只让签名那条向读屏报告一次“正在加载”。
        statsLoadingBar.setAccessibilityElement(false)
        refreshLoadingBarColor()

        statsLabel.setAccessibilityLabel(VideoDetailFeatureStrings.localized("粉丝与投稿"))
        signatureLabel.setAccessibilityLabel(VideoDetailFeatureStrings.localized("UP 主签名"))

        // 子视图顺序就是读屏顺序：与视觉一致，名字之后是紧跟它的关注按钮，最后是行尾的“查看空间”。
        for subview in [
            avatar,
            nameLabel,
            followButton,
            statsLabel,
            signatureLabel,
            statsLoadingBar,
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
        let color = NSColor.quaternaryLabelColor.cgColor(for: effectiveAppearance)
        statsLoadingBar.layer?.backgroundColor = color
        signatureLoadingBar.layer?.backgroundColor = color
    }

    func configure(
        content: VideoUploaderHeaderContent,
        imagePipeline: any VideoDetailImageLoading,
        onOpenSpace: (() -> Void)?,
        onSetFollowing: ((Bool) -> Void)?,
        onShowFollowingMenu: ((NSView) -> Void)?
    ) {
        self.onOpenSpace = onOpenSpace
        self.onSetFollowing = onSetFollowing
        self.onShowFollowingMenu = onShowFollowingMenu
        spaceButton.isHidden = onOpenSpace == nil
        let avatarChanged = self.content?.avatarURL != content.avatarURL
        if NativePlaybackUploaderProfileReveal.fades(from: self.content, to: content) {
            NativePlaybackSidebarFade.crossfade(
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

        apply(content.stats, to: statsLabel, loadingBar: statsLoadingBar)
        apply(content.signature, to: signatureLabel, loadingBar: signatureLoadingBar)
        if content.signature == .loading {
            signatureLoadingBar.setAccessibilityElement(true)
            signatureLoadingBar.setAccessibilityLabel(
                VideoDetailFeatureStrings.localized("签名正在加载")
            )
        }
        configureFollowButton(content.follow)
        needsLayout = true
        spaceRegion.setRects([spaceHitRect])
        if avatarChanged || avatar.image == nil {
            loadAvatar(
                content.avatarURL,
                purpose: content.avatarPurpose,
                imagePipeline: imagePipeline
            )
        }
    }

    private func apply(
        _ line: VideoUploaderLineContent,
        to label: NSTextField,
        loadingBar: NSView
    ) {
        switch line {
        case .loading:
            label.isHidden = true
            loadingBar.isHidden = false
        case .hidden:
            label.isHidden = true
            loadingBar.isHidden = true
        case .text(let text):
            label.stringValue = text
            label.isHidden = false
            loadingBar.isHidden = true
        }
    }

    /// 标题说明现状（「关注」／「已关注」），读屏的值说明当前状态，提示与读屏帮助说明点按的结果（已关注且有菜单时是弹出
    /// 关注选项，不是取消关注）；未关注且可点时用强调色（与网页一致），禁用时不用：强调色的禁用按钮在侧栏里仍像可点。
    private func configureFollowButton(_ follow: VideoUploaderFollowContent?) {
        guard let follow else {
            followButton.isHidden = true
            return
        }
        followButton.isHidden = false
        NativePlaybackUploaderGeometry.applyFollowLabel(
            isFollowing: follow.isFollowing,
            to: followButton
        )
        followButton.bezelColor =
            follow.isFollowing || !follow.isEnabled ? nil : .controlAccentColor
        followButton.isEnabled = follow.isEnabled
        let help =
            if !follow.isFollowing {
                VideoDetailFeatureStrings.localized("关注")
            } else if onShowFollowingMenu != nil {
                VideoDetailFeatureStrings.localized("显示关注选项")
            } else {
                VideoDetailFeatureStrings.localized("取消关注")
            }
        followButton.toolTip = help
        followButton.setAccessibilityLabel(UploaderFollowButtonLabel.accessibilityLabel)
        followButton.setAccessibilityValue(
            UploaderFollowButtonLabel.accessibilityValue(isFollowing: follow.isFollowing)
        )
        followButton.setAccessibilityHelp(followButton.toolTip)
    }

    override func layout() {
        super.layout()
        guard let content else {
            avatar.frame = NSRect(
                x: 0,
                y: 0,
                width: NativePlaybackSidebarItemMeasurement.avatarSize,
                height: NativePlaybackSidebarItemMeasurement.avatarSize
            )
            return
        }
        let geometry = NativePlaybackUploaderGeometry(
            content: content,
            width: bounds.width,
            showsSpaceButton: !spaceButton.isHidden
        )
        avatar.frame = geometry.avatarFrame
        let nameRow = geometry.nameRow(
            nameWidth: NativePlaybackUploaderGeometry.nameWidth(content.name)
        )
        nameLabel.frame = nameRow.name
        spaceButton.frame = nameRow.spaceButton
        statsLabel.frame = geometry.statsFrame
        signatureLabel.frame = geometry.signatureTextFrame
        statsLoadingBar.frame = geometry.statsLoadingBarFrame
        signatureLoadingBar.frame = geometry.signatureLoadingBarFrame
        followButton.frame = nameRow.followButton
        spaceRegion.setRects([spaceHitRect])
    }

    /// 头像加上名字；没有计数与签名时到名字末尾为止的整块都可点；关注按钮与箭头不在其中（各自是按钮）；没有空间入口时
    /// 为空。
    private var spaceHitRect: NSRect {
        guard onOpenSpace != nil, let content else { return .zero }
        // 箭头在行尾，自己是按钮；可点区域只到名字末尾，不盖住紧跟名字的关注按钮。
        let textMaxX = nameLabel.frame.maxX
        if content.stats == .hidden, content.signature == .hidden {
            return NSRect(x: 0, y: 0, width: textMaxX, height: bounds.height)
        }
        let nameRow = NSRect(
            x: 0,
            y: nameLabel.frame.minY,
            width: textMaxX,
            height: nameLabel.frame.height
        )
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
        onSetFollowing = nil
        onShowFollowingMenu = nil
        spaceButton.isHidden = true
        followButton.isHidden = true
        spaceRegion.setRects([spaceHitRect])
        avatar.image = nil
        nameLabel.stringValue = ""
        statsLabel.stringValue = ""
        signatureLabel.stringValue = ""
        statsLoadingBar.isHidden = true
        signatureLoadingBar.isHidden = true
    }

    private func loadAvatar(
        _ url: URL?,
        purpose: VideoDetailImagePurpose,
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
        if let cached = imagePipeline.cachedImage(for: url, purpose: purpose) {
            avatar.image = NSImage(cgImage: cached, size: .zero)
            return
        }
        imageTask = Task { [weak self] in
            let result = await imagePipeline.image(for: url, purpose: purpose)
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

    /// 未关注时点一下关注；已关注时弹出「已关注」菜单（取消关注在菜单里），没有菜单时照旧点一下取消关注。
    @objc private func toggleFollowing() {
        guard let follow = content?.follow, follow.isEnabled else { return }
        if follow.isFollowing, let onShowFollowingMenu {
            onShowFollowingMenu(followButton)
            return
        }
        onSetFollowing?(!follow.isFollowing)
    }
}

/// 视频简介条目：可选择的正文、链接与时间戳，超过五行时可展开或收起；展开状态由侧栏控制器持有。
@MainActor
final class NativePlaybackSidebarSummaryItem: NativeLayoutSizedCollectionItem {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier(
        "NativePlaybackSidebarSummaryItem"
    )

    private let contentView = NativePlaybackSidebarSummaryView()

    override func loadView() {
        view = contentView
    }

    func configure(
        summary: String,
        links: [CommentLink],
        timestampLimits: TimestampSeekLimits?,
        expanded: Bool,
        onToggle: @escaping () -> Void,
        onOpenLink: @escaping (CommentLinkTarget) -> Void
    ) {
        representedObject = summary
        contentView.configure(
            text: NativePlaybackSidebarLinkedText(
                text: summary,
                links: links,
                timestampLimits: timestampLimits
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
private final class NativePlaybackSidebarSummaryView: NSView {
    override var isFlipped: Bool { true }

    private let titleLabel = NSTextField(labelWithString: VideoDetailFeatureStrings.localized("简介"))
    private let separator = NSBox()
    private let textView = NativePlaybackSidebarReadOnlyTextView(
        font: .preferredFont(forTextStyle: .callout),
        color: .secondaryLabelColor
    )
    private let toggleButton = NSButton()
    private var text = NativePlaybackSidebarLinkedText(
        text: "",
        links: [],
        timestampLimits: nil
    )
    private var expanded = false
    private var onToggle: (() -> Void)?
    private var configuredText: NativePlaybackSidebarLinkedText?
    private var configuredMaximumLines: Int?
    private var hasConfiguredText = false
    /// 简介文字除时间戳上限以外决定显示的部分；只有上限变化时时间戳的变色才淡入。
    private struct SummaryTextContent: Equatable {
        let text: String
        let links: [CommentLink]
        let maximumLines: Int?
    }

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
        text: NativePlaybackSidebarLinkedText,
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
            let previous = configuredText.map { configured in
                (
                    content: SummaryTextContent(
                        text: configured.text,
                        links: configured.links,
                        maximumLines: configuredMaximumLines
                    ),
                    limits: configured.timestampLimits
                )
            }
            let next = (
                content: SummaryTextContent(
                    text: text.text,
                    links: text.links,
                    maximumLines: maximumLines
                ),
                limits: text.timestampLimits
            )
            if NativePlaybackTextLinks.fadesTimestampChange(from: previous, to: next) {
                NativePlaybackSidebarFade.crossfade(
                    textView,
                    key: "native-playback-summary.timestamp-links"
                )
            }
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
        text = NativePlaybackSidebarLinkedText(text: "", links: [], timestampLimits: nil)
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
