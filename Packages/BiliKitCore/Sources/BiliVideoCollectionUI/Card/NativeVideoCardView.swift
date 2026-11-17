import AppKit
import BiliUI
import CoreGraphics
import QuartzCore

extension NSUserInterfaceItemIdentifier {
    /// 网格与 shelf 注册、取用 `NativeVideoCollectionItem` 的复用标识（`NativeVideoCollectionItem.reuseIdentifier`）。
    package static let nativeVideoCard = Self("native.video-card")
}

/// 页脚首尾两段文字分到的宽度。
struct NativeVideoCardFooterWidths: Equatable {
    let leading: CGFloat
    let trailing: CGFloat
}

/// 页脚宽度分配的唯一计算，测量与排版共用。
///
/// 普通页脚：尾部取测得宽度（上限是给首段留 1pt 与间距后的剩余），余下给首段文字。推荐理由胶囊：先给首段保留
/// `recommendationFooterMinimumLeadingWidth`，胶囊取测得宽度与剩余宽度中较小者，余下仍归首段。
enum NativeVideoCardLayout {
    static let footerSpacing: CGFloat = 8
    /// 胶囊再长也给其后的页脚文字保留的宽度；取值没有另行记录的依据，按 13pt 正文约能放下 5 个汉字；
    /// 调大则窄卡片上的胶囊更早截断，调小则长理由会把作者名挤到只剩几个字。
    static let recommendationFooterMinimumLeadingWidth: CGFloat = 72
    /// 不可用卡片头像与文字的不透明度，与封面暗层一起表达“不能播放”；调高与可播放卡片难以区分，调低则标题
    /// 难读。
    static let unavailableContentOpacity: Float = 0.45

    static func footerWidths(
        contentWidth: CGFloat,
        leadingInset: CGFloat,
        trailingIntrinsicWidth: CGFloat,
        showsTrailing: Bool
    ) -> NativeVideoCardFooterWidths {
        let availableWidth = max(0, contentWidth - leadingInset)
        guard showsTrailing else {
            return NativeVideoCardFooterWidths(
                leading: availableWidth,
                trailing: 0
            )
        }
        let maximumTrailingWidth = max(
            0,
            availableWidth - footerSpacing - 1
        )
        let trailingWidth = min(
            max(0, ceil(trailingIntrinsicWidth)),
            maximumTrailingWidth
        )
        return NativeVideoCardFooterWidths(
            leading: max(
                1,
                availableWidth - trailingWidth - footerSpacing
            ),
            trailing: trailingWidth
        )
    }

    static func recommendationFooterWidths(
        contentWidth: CGFloat,
        leadingInset: CGFloat,
        capsuleIntrinsicWidth: CGFloat
    ) -> NativeVideoCardFooterWidths {
        let availableWidth = max(0, contentWidth - leadingInset)
        let reservedLeadingWidth = min(
            recommendationFooterMinimumLeadingWidth,
            availableWidth
        )
        let maximumCapsuleWidth = max(
            0,
            availableWidth
                - NativeVideoCardTextLayout.recommendationCapsuleSpacing
                - reservedLeadingWidth
        )
        let capsuleWidth = min(
            max(0, ceil(capsuleIntrinsicWidth)),
            maximumCapsuleWidth
        )
        return NativeVideoCardFooterWidths(
            leading: max(
                0,
                availableWidth
                    - capsuleWidth
                    - NativeVideoCardTextLayout.recommendationCapsuleSpacing
            ),
            trailing: capsuleWidth
        )
    }
}

/// 单行宽度的单项缓存：文字与测量变体（样式、字体、字号）都不变时不重新测量。
struct NativeVideoSingleLineWidthCache {
    private var text: String?
    private var variant = ""
    private var width: CGFloat = 0

    mutating func width(
        for text: String,
        variant: String = "",
        measure: () -> CGFloat
    ) -> CGFloat {
        guard self.text != text || self.variant != variant else { return width }
        self.text = text
        self.variant = variant
        width = measure()
        return width
    }

    mutating func reset() {
        text = nil
        variant = ""
        width = 0
    }
}

/// 网格与 shelf 复用的视频卡片集合项，用 AppKit 的理由见 ARCHITECTURE「原生 AppKit 集合视图」。
///
/// 拥有封面与头像两个图片位（`NativeCardImageSlot`）及配置代次；不拥有图片管线与悬停仲裁（交给
/// `NativeVideoHoverTracker`）。离屏（`invalidateImageRequests`）、复用与拆除（`invalidate`）时取消取图，图片位释放时
/// 兜底取消；`generation` 在换视频、换封面或头像地址、头像显隐变化与 `invalidate` 时递增，晚到的结果按复用身份比对后丢弃。
@MainActor
package final class NativeVideoCollectionItem: NativeInteractiveCardItem, NativeGridCardItem {
    package static let reuseIdentifier = NSUserInterfaceItemIdentifier.nativeVideoCard

    private let card = NativeVideoCardView()
    private let coverImage = NativeCardImageSlot(kind: .cover)
    private let avatarImage = NativeCardImageSlot(kind: .avatar)
    private var reuseIdentity: NativeVideoReuseIdentity?
    private var generation: UInt64 = 0
    private var currentPresentation: NativeVideoCardPresentation?
    private var activation: ((String) -> Void)?
    private var hoverChanged: ((NativeVideoCollectionItem, Bool) -> Void)?

    override var interactiveCard: NativeInteractiveCardView { card }

    package var representedCardID: String? { currentPresentation?.id }

    /// 卡片此刻显示着的封面与头像，按图片地址。
    package var displayedImages: [URL: CGImage] {
        var images: [URL: CGImage] = [:]
        let displayed = [coverImage.displayedImage, avatarImage.displayedImage]
        for (url, image) in displayed.compactMap(\.self) {
            images[url] = image
        }
        return images
    }

    /// 内容相同时只补发缺失的取图；换视频或换图片地址时先取消旧请求、清掉旧图再配置。
    package func configure(
        presentation: NativeVideoCardPresentation,
        imagePipeline: any NativeVideoImageLoading,
        hoverChanged: @escaping (NativeVideoCollectionItem, Bool) -> Void,
        activation: @escaping (String) -> Void
    ) {
        self.activation = activation
        self.hoverChanged = hoverChanged
        representedObject = presentation.id
        if currentPresentation == presentation, let reuseIdentity {
            restartMissingImageRequests(
                presentation: presentation,
                identity: reuseIdentity,
                pipeline: imagePipeline
            )
            return
        }

        let previous = currentPresentation
        let changesIdentity = previous?.id != presentation.id
        let changesCover = previous?.coverURL != presentation.coverURL
        let changesAvatar =
            previous?.avatarURL != presentation.avatarURL
            || previous?.showsAvatar != presentation.showsAvatar
        if changesIdentity || changesCover || changesAvatar {
            invalidateImageRequests()
            generation &+= 1
            if changesIdentity || changesCover {
                coverImage.clear()
                card.setCover(nil, animated: false)
            }
            if changesIdentity || changesAvatar {
                avatarImage.clear()
                card.setAvatar(nil, animated: false)
            }
        }
        let identity = NativeVideoReuseIdentity(itemID: presentation.id, generation: generation)
        currentPresentation = presentation
        reuseIdentity = identity
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
        restartMissingImageRequests(
            presentation: presentation,
            identity: identity,
            pipeline: imagePipeline
        )
    }

    package override func prepareForReuse() {
        super.prepareForReuse()
        invalidate()
    }

    package func invalidateImageRequests() {
        coverImage.cancel()
        avatarImage.cancel()
    }

    package func invalidate() {
        invalidateImageRequests()
        generation &+= 1
        currentPresentation = nil
        reuseIdentity = nil
        coverImage.clear()
        avatarImage.clear()
        activation = nil
        representedObject = nil
        card.reset()
        hoverChanged = nil
    }

    private func restartMissingImageRequests(
        presentation: NativeVideoCardPresentation,
        identity: NativeVideoReuseIdentity,
        pipeline: any NativeVideoImageLoading
    ) {
        let currentIdentity: @MainActor () -> NativeVideoReuseIdentity? = { [weak self] in
            self?.reuseIdentity
        }
        coverImage.requestIfIdle(
            presentation.coverURL,
            identity: identity,
            currentIdentity: currentIdentity,
            pipeline: pipeline
        ) { [weak self] image, fadesIn in
            self?.card.setCover(image, animated: fadesIn)
        }
        guard presentation.showsAvatar else { return }
        avatarImage.requestIfIdle(
            presentation.avatarURL,
            identity: identity,
            currentIdentity: currentIdentity,
            pipeline: pipeline
        ) { [weak self] image, fadesIn in
            self?.card.setAvatar(image, animated: fadesIn)
        }
    }
}

/// 视频卡片视图：封面、头像与文字层的排版；交互状态与读屏按钮语义在 `NativeInteractiveCardView`。
///
/// 不取图，图片由 `NativeVideoCollectionItem` 设置。不可用卡片（`NativeVideoCardAvailability.unavailable`）变暗并显示
/// 原因角标，交互上按不可激活处理（不画悬停与按下，读屏呈现为不可用的按钮且按下不激活）；网格另在自己的激活入口拦截。
@MainActor
final class NativeVideoCardView: NativeInteractiveCardView {
    private let cover = NativeVideoMergedCoverView(frame: .zero)
    private let avatar = NativeVideoLayerImageView(
        placeholderSystemSymbolName: NativeAvatarPlaceholder.systemSymbolName,
        placeholderTintColor: NativeAvatarPlaceholder.tintColor
    )
    private let titleFont = NSFont.systemFont(
        ofSize: NSFont.preferredFont(forTextStyle: .title3).pointSize,
        weight: .medium
    )
    private let footerFont = NSFont.preferredFont(forTextStyle: .body)
    private let textRenderer = NativeVideoCardTextRenderer()
    /// 正在播放的强调底色，放在最底层，与悬停底色、描边互不覆盖。
    private let nowPlayingFill = CALayer()
    private var isNowPlaying = false
    private var showsAvatar = true

    override init(frame: NSRect) {
        super.init(frame: frame)
        nowPlayingFill.cornerRadius = NativeInteractiveSurface.cornerRadius
        layer?.insertSublayer(nowPlayingFill, at: 0)
        for subview in [cover, avatar] {
            subview.setAccessibilityElement(false)
            addSubview(subview)
        }
        if let layer { textRenderer.install(in: layer) }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(
        presentation: NativeVideoCardPresentation,
        hoverDidChange: @escaping (Bool) -> Void,
        activation: @escaping () -> Void
    ) {
        configureInteraction(hoverDidChange: hoverDidChange, activation: activation)
        showsAvatar = presentation.showsAvatar
        avatar.isHidden = !showsAvatar
        let badgeText: String?
        if case .unavailable(let badge) = presentation.availability {
            badgeText = badge
        } else {
            badgeText = nil
        }
        cover.configure(
            metrics: presentation.coverMetrics,
            trailingText: presentation.coverTrailingText,
            badgeText: badgeText,
            isDimmed: !presentation.isActivatable
        )
        isNowPlaying = presentation.nowPlayingText != nil
        if let nowPlayingText = presentation.nowPlayingText {
            textRenderer.configure(
                title: presentation.title,
                footerLeading: presentation.footerLeadingText,
                footerTrailing: nowPlayingText,
                footerTrailingSymbolName: NativeNowPlayingAppearance.symbolName,
                footerTrailingStyle: .nowPlaying
            )
        } else {
            textRenderer.configure(
                title: presentation.title,
                footerLeading: presentation.footerLeadingText,
                footerTrailing: presentation.footerTrailingText,
                footerTrailingSymbolName: presentation.footerTrailingSymbolName,
                footerTrailingStyle: presentation.footerTrailingStyle
            )
        }
        setContentActivatable(presentation.isActivatable)
        setAccessibilityLabel(presentation.accessibilityLabel)
        setAccessibilityHelp(presentation.accessibilityHelp)
        updateAccessibilityValue()
        needsLayout = true
    }

    func setCover(_ image: CGImage?, animated: Bool = true) {
        cover.setImage(image, animated: animated)
    }

    func setAvatar(_ image: CGImage?, animated: Bool = true) {
        avatar.setImage(image, animated: animated)
    }

    override func resetContent() {
        isNowPlaying = false
        cover.reset()
        textRenderer.reset()
        avatar.isHidden = false
        showsAvatar = true
        setCover(nil, animated: false)
        setAvatar(nil, animated: false)
        setContentActivatable(true)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        needsLayout = true
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsLayout = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        nowPlayingFill.frame = bounds
        CATransaction.commit()
        NativeNowPlayingAppearance.applyFill(
            isNowPlaying,
            to: nowPlayingFill,
            appearance: effectiveAppearance
        )
        let coverHeight = VideoCardGeometry.coverHeight(forWidth: bounds.width)
        cover.frame = NSRect(x: 0, y: 0, width: bounds.width, height: coverHeight)
        let textX = VideoCardGeometry.textLeadingInset(showsAvatar: showsAvatar)
        let textY = coverHeight + VideoCardGeometry.textTopSpacing
        let avatarSize = VideoCardGeometry.avatarSize
        avatar.frame = NSRect(x: 0, y: textY, width: avatarSize, height: avatarSize)
        avatar.layer?.cornerRadius = avatarSize / 2
        let titleFrame = NSRect(
            x: textX,
            y: textY,
            width: max(1, bounds.width - textX),
            height: VideoCardGeometry.titleHeight
        )
        let footerY = coverHeight + VideoCardGeometry.footerTopOffset
        let footerHeight = VideoCardGeometry.footerHeight
        let showsFooterTrailing = textRenderer.showsFooterTrailing
        let trailingWidth = textRenderer.trailingWidth(font: footerFont)
        let contentsScale =
            window?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor
            ?? 2
        let footerLeadingFrame: NSRect
        let footerTrailingFrame: NSRect
        if textRenderer.usesLeadingCapsule {
            let footerWidths = NativeVideoCardLayout.recommendationFooterWidths(
                contentWidth: bounds.width,
                leadingInset: textX,
                capsuleIntrinsicWidth: trailingWidth
            )
            footerTrailingFrame = Self.pixelAligned(
                NSRect(
                    x: textX,
                    y: footerY
                        + (footerHeight - NativeVideoCardTextLayout.recommendationCapsuleHeight) / 2
                        + NativeVideoCardTextLayout.recommendationCapsuleVerticalAdjustment,
                    width: footerWidths.trailing,
                    height: NativeVideoCardTextLayout.recommendationCapsuleHeight
                ),
                scale: contentsScale
            )
            let leadingX =
                footerTrailingFrame.maxX
                + NativeVideoCardTextLayout.recommendationCapsuleSpacing
            footerLeadingFrame = NSRect(
                x: leadingX,
                y: footerY,
                width: footerWidths.leading,
                height: footerHeight
            )
        } else {
            let footerWidths = NativeVideoCardLayout.footerWidths(
                contentWidth: bounds.width,
                leadingInset: textX,
                trailingIntrinsicWidth: trailingWidth,
                showsTrailing: showsFooterTrailing
            )
            footerLeadingFrame = NSRect(
                x: textX,
                y: footerY,
                width: footerWidths.leading,
                height: footerHeight
            )
            footerTrailingFrame = NSRect(
                x: max(textX, bounds.width - footerWidths.trailing),
                y: footerY,
                width: footerWidths.trailing,
                height: footerHeight
            )
        }
        textRenderer.layout(
            titleFrame: titleFrame,
            footerLeadingFrame: footerLeadingFrame,
            footerTrailingFrame: footerTrailingFrame,
            titleFont: titleFont,
            footerFont: footerFont,
            appearance: effectiveAppearance,
            contentsScale: contentsScale
        )
    }

    private static func pixelAligned(_ rect: NSRect, scale: CGFloat) -> NSRect {
        let scale = max(1, scale)
        let minX = round(rect.minX * scale) / scale
        let minY = round(rect.minY * scale) / scale
        let maxX = round(rect.maxX * scale) / scale
        let maxY = round(rect.maxY * scale) / scale
        return NSRect(
            x: minX,
            y: minY,
            width: max(0, maxX - minX),
            height: max(0, maxY - minY)
        )
    }

    /// 可用性变化时同步变暗，交互外观与读屏可用状态交给 `setActivatable`。
    private func setContentActivatable(_ activatable: Bool) {
        let opacity: Float = activatable ? 1 : NativeVideoCardLayout.unavailableContentOpacity
        textRenderer.setContentOpacity(opacity)
        avatar.alphaValue = CGFloat(opacity)
        setActivatable(activatable)
    }
}
