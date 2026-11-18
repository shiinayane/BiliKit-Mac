import AppKit
import BiliUI

extension NSUserInterfaceItemIdentifier {
    /// 网格注册、取用 `NativePersonCollectionItem` 的复用标识。
    static let nativePersonCard = Self("native.person-card")
}

/// 人物卡片的唯一几何来源：网格几何（`CardGridGeometry.person`）的卡片高度与卡片内的排版都取这里。
enum NativePersonCardLayout {
    /// 头像上下各留 `contentInset`：40 + 12 × 2。
    static let height: CGFloat = 64
    static let avatarSize: CGFloat = 40
    /// 头像与卡片边缘、星标与卡片右缘的距离，也是悬停底色里内容的边距。
    static let contentInset: CGFloat = 12
    static let avatarTextSpacing: CGFloat = 12
    static let nameSubtitleSpacing: CGFloat = 2
    static let badgeSpacing: CGFloat = 6
    static let badgeHeight: CGFloat = 16
    static let badgeHorizontalPadding: CGFloat = 5
    static let starPointSize: CGFloat = 12
    static let starSpacing: CGFloat = 8
}

/// 网格的人物卡片集合项（关注列表），用 AppKit 的理由见 ARCHITECTURE「原生 AppKit 集合视图」。
///
/// 拥有头像的图片位（`NativeCardImageSlot`）及配置代次；不拥有图片管线与悬停仲裁（交给 `NativeVideoHoverTracker`）。
/// 离屏（`invalidateImageRequests`）、复用与拆除（`invalidate`）时取消取图；`generation` 在换人、换头像地址与
/// `invalidate` 时递增，晚到的头像按复用身份比对后丢弃。
@MainActor
package final class NativePersonCollectionItem: NativeInteractiveCardItem, NativeGridCardItem {
    package static let reuseIdentifier = NSUserInterfaceItemIdentifier.nativePersonCard

    private let card = NativePersonCardView()
    private let avatarImage = NativeCardImageSlot(kind: .avatar)
    private var reuseIdentity: NativeVideoReuseIdentity?
    private var generation: UInt64 = 0
    private var currentPresentation: NativePersonCardPresentation?
    private var activation: ((String) -> Void)?
    private var hoverChanged: ((NativePersonCollectionItem, Bool) -> Void)?

    override var interactiveCard: NativeInteractiveCardView { card }

    package var representedCardID: String? { currentPresentation?.id }

    package var displayedImages: [URL: CGImage] {
        guard let displayed = avatarImage.displayedImage else { return [:] }
        return [displayed.url: displayed.image]
    }

    /// 内容相同时只补发缺失的头像；换人或换头像地址时先取消旧请求、清掉旧图再配置。
    package func configure(
        presentation: NativePersonCardPresentation,
        imagePipeline: any NativeVideoImageLoading,
        hoverChanged: @escaping (NativePersonCollectionItem, Bool) -> Void,
        activation: @escaping (String) -> Void
    ) {
        self.activation = activation
        self.hoverChanged = hoverChanged
        representedObject = presentation.id
        if currentPresentation != presentation {
            let previous = currentPresentation
            if previous?.id != presentation.id || previous?.avatarURL != presentation.avatarURL {
                invalidateImageRequests()
                generation &+= 1
                avatarImage.clear()
                card.setAvatar(nil, animated: false)
            }
            currentPresentation = presentation
            reuseIdentity = NativeVideoReuseIdentity(
                itemID: presentation.id,
                generation: generation
            )
            card.configure(
                presentation: presentation,
                hoverDidChange: { [weak self] isHovered in
                    guard let self else { return }
                    self.hoverChanged?(self, isHovered)
                },
                activation: { [weak self] in
                    guard let id = self?.reuseIdentity?.itemID else { return }
                    self?.activation?(id)
                }
            )
        }
        guard let reuseIdentity else { return }
        let currentIdentity: @MainActor () -> NativeVideoReuseIdentity? = { [weak self] in
            self?.reuseIdentity
        }
        avatarImage.requestIfIdle(
            presentation.avatarURL,
            identity: reuseIdentity,
            currentIdentity: currentIdentity,
            pipeline: imagePipeline
        ) { [weak self] image, fadesIn in
            self?.card.setAvatar(image, animated: fadesIn)
        }
    }

    package override func prepareForReuse() {
        super.prepareForReuse()
        invalidate()
    }

    package func invalidateImageRequests() {
        avatarImage.cancel()
    }

    package func releaseDisplayedImages() {
        invalidateImageRequests()
        avatarImage.clear()
        card.setAvatar(nil, animated: false)
    }

    package func invalidate() {
        invalidateImageRequests()
        generation &+= 1
        currentPresentation = nil
        reuseIdentity = nil
        avatarImage.clear()
        activation = nil
        representedObject = nil
        card.reset()
        hoverChanged = nil
    }
}

/// 人物卡片视图：头像、名字（大会员配色）、可选的互关角标、一行副标题与特别关注星标的排版；交互状态与读屏按钮语义在
/// `NativeInteractiveCardView`。
///
/// 不取图，头像由 `NativePersonCollectionItem` 设置。读屏标签是名字，值依次列出互关、特别关注与“已选择”，帮助是
/// 副标题；按下即激活（打开空间页）。
@MainActor
final class NativePersonCardView: NativeInteractiveCardView {
    private let avatar = NativeVideoLayerImageView(
        placeholderSystemSymbolName: NativeAvatarPlaceholder.systemSymbolName,
        placeholderTintColor: NativeAvatarPlaceholder.tintColor
    )
    private let nameLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let badge = NativePersonBadgeView()
    private let star = NSImageView()
    private var presentation: NativePersonCardPresentation?

    override init(frame: NSRect) {
        super.init(frame: frame)
        nameLabel.font = NSFont.systemFont(
            ofSize: NSFont.preferredFont(forTextStyle: .body).pointSize,
            weight: .semibold
        )
        subtitleLabel.font = .preferredFont(forTextStyle: .callout)
        subtitleLabel.textColor = .secondaryLabelColor
        for label in [nameLabel, subtitleLabel] {
            label.lineBreakMode = .byTruncatingTail
            label.maximumNumberOfLines = 1
            label.usesSingleLineMode = true
            label.cell?.truncatesLastVisibleLine = true
        }
        star.image = NSImage(systemSymbolName: "star.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(
                NSImage.SymbolConfiguration(
                    pointSize: NativePersonCardLayout.starPointSize,
                    weight: .regular
                )
            )
        star.contentTintColor = .systemYellow
        for subview in [avatar, nameLabel, subtitleLabel, badge, star] {
            subview.setAccessibilityElement(false)
            addSubview(subview)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(
        presentation: NativePersonCardPresentation,
        hoverDidChange: @escaping (Bool) -> Void,
        activation: @escaping () -> Void
    ) {
        self.presentation = presentation
        configureInteraction(hoverDidChange: hoverDidChange, activation: activation)
        nameLabel.stringValue = presentation.name
        nameLabel.textColor = NativeMemberNameColor.color(isVIP: presentation.isVIP)
        subtitleLabel.stringValue = presentation.subtitle ?? ""
        subtitleLabel.isHidden = presentation.subtitle == nil
        badge.text = presentation.mutualBadge
        badge.isHidden = presentation.mutualBadge == nil
        star.isHidden = presentation.specialLabel == nil
        setAccessibilityLabel(presentation.name)
        setAccessibilityHelp(presentation.subtitle)
        updateAccessibilityValue()
        needsLayout = true
    }

    func setAvatar(_ image: CGImage?, animated: Bool = true) {
        avatar.setImage(image, animated: animated)
    }

    override var accessibilityStateParts: [String] {
        [presentation?.mutualBadge, presentation?.specialLabel].compactMap(\.self)
    }

    override func resetContent() {
        presentation = nil
        nameLabel.stringValue = ""
        subtitleLabel.stringValue = ""
        badge.text = nil
        badge.isHidden = true
        star.isHidden = true
        setAvatar(nil, animated: false)
    }

    override func layout() {
        super.layout()
        typealias Layout = NativePersonCardLayout
        let avatarY = floor((bounds.height - Layout.avatarSize) / 2)
        avatar.frame = NSRect(
            x: Layout.contentInset,
            y: avatarY,
            width: Layout.avatarSize,
            height: Layout.avatarSize
        )
        avatar.layer?.cornerRadius = Layout.avatarSize / 2

        let starSize = star.isHidden ? .zero : star.intrinsicContentSize
        star.frame = NSRect(
            x: bounds.width - Layout.contentInset - starSize.width,
            y: floor((bounds.height - starSize.height) / 2),
            width: starSize.width,
            height: starSize.height
        )
        let textX = Layout.contentInset + Layout.avatarSize + Layout.avatarTextSpacing
        let textMaxX =
            bounds.width - Layout.contentInset
            - (star.isHidden ? 0 : starSize.width + Layout.starSpacing)
        let textWidth = max(0, textMaxX - textX)

        // 卡片高度固定，名字与副标题各只排一行：行高按字体算，不取固有高度。文字里的换行（签名常带）会让固有高度按多行算，
        // 整块超出卡片、把名字顶出上沿；调用方另把文字规整成一行（关注页经 `UploaderProfileUseCase.singleLine`）。
        let nameHeight = Self.singleLineHeight(of: nameLabel)
        let subtitleHeight = subtitleLabel.isHidden ? 0 : Self.singleLineHeight(of: subtitleLabel)
        let blockHeight =
            nameHeight + (subtitleLabel.isHidden ? 0 : Layout.nameSubtitleSpacing + subtitleHeight)
        let nameY = floor((bounds.height - blockHeight) / 2)

        // 名字放不下时先截断名字，角标始终完整显示在名字之后（角标只有几个字）。
        let badgeWidth = badge.isHidden ? 0 : min(textWidth, badge.fittingWidth)
        let nameWidth = min(
            nativeCardLabelContentSize(nameLabel).width,
            max(0, textWidth - (badge.isHidden ? 0 : badgeWidth + Layout.badgeSpacing))
        )
        nameLabel.frame = NSRect(x: textX, y: nameY, width: nameWidth, height: nameHeight)
        badge.frame = NSRect(
            x: textX + nameWidth + Layout.badgeSpacing,
            y: nameY + floor((nameHeight - Layout.badgeHeight) / 2),
            width: badgeWidth,
            height: Layout.badgeHeight
        )
        subtitleLabel.frame = NSRect(
            x: textX,
            y: nameY + nameHeight + Layout.nameSubtitleSpacing,
            width: textWidth,
            height: subtitleHeight
        )
    }

    /// 一行文字的高度：按标签字体的默认行高。
    private static func singleLineHeight(of label: NSTextField) -> CGFloat {
        guard let font = label.font else { return 0 }
        return ceil(NSLayoutManager().defaultLineHeight(for: font))
    }

    /// 点击与右键都落在卡片自己身上，不交给名字、副标题等子视图：否则文字标签可能接住按下或给出自己的右键菜单，
    /// 卡片的点击激活与卡片菜单就走不到集合视图。
    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) == nil ? nil : self
    }
}

/// 「互相关注」角标：次要色小字放在填充色胶囊里；填充色是按外观解析后写进 layer 的，外观变化时重写。
@MainActor
private final class NativePersonBadgeView: NSView {
    private let label = NSTextField(labelWithString: "")

    var text: String? {
        get { label.stringValue.isEmpty ? nil : label.stringValue }
        set {
            label.stringValue = newValue ?? ""
            needsLayout = true
        }
    }

    /// 文字宽度加左右内边距。
    var fittingWidth: CGFloat {
        nativeCardLabelContentSize(label).width + NativePersonCardLayout.badgeHorizontalPadding * 2
    }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = NativePersonCardLayout.badgeHeight / 2
        label.font = .preferredFont(forTextStyle: .caption1)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        // 互关已在卡片的读屏值里；角标的文字若仍是读屏元素，「互相关注」会被读两遍。
        label.setAccessibilityElement(false)
        addSubview(label)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.quaternarySystemFill.cgColor(for: effectiveAppearance)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        let height = nativeCardLabelContentSize(label).height
        label.frame = NSRect(
            x: NativePersonCardLayout.badgeHorizontalPadding,
            y: floor((bounds.height - height) / 2),
            width: max(0, bounds.width - NativePersonCardLayout.badgeHorizontalPadding * 2),
            height: height
        )
    }
}

/// 标签画出全部文字需要的尺寸（向上取整）：按单元格测量，与标签此刻的框无关。
///
/// 不用 `intrinsicContentSize`：它不含单元格两侧的内边距，按它给框会让放得下的文字也出省略号；也不用 `fittingSize`：
/// 标签还没排过版（框为零）时它按自动尺寸约束只给出内边距。
@MainActor
private func nativeCardLabelContentSize(_ label: NSTextField) -> NSSize {
    let unbounded = NSRect(
        x: 0,
        y: 0,
        width: CGFloat.greatestFiniteMagnitude,
        height: .greatestFiniteMagnitude
    )
    guard let size = label.cell?.cellSize(forBounds: unbounded) else { return .zero }
    return NSSize(width: ceil(size.width), height: ceil(size.height))
}
