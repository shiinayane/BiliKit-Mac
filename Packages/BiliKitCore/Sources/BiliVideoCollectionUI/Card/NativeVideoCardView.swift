import AppKit
import BiliUI
import CoreGraphics
import QuartzCore

extension NSUserInterfaceItemIdentifier {
    /// 网格注册、取用 `NativeVideoCollectionItem` 的复用标识。
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

/// 网格复用的卡片集合项，用 AppKit 的理由见 ARCHITECTURE「原生 AppKit 集合视图」。
///
/// 拥有封面与头像的取图 Task 及配置代次；不拥有图片管线与悬停仲裁（交给 `NativeVideoHoverTracker`）。
/// 离屏（`invalidateImageRequests`）、复用与拆除（`invalidate`）时取消 Task，deinit 兜底取消；`generation`
/// 在换视频、换封面或头像地址、头像显隐变化与 `invalidate` 时递增，晚到的结果经 `NativeVideoImageApplicationGate`
/// 比对身份后丢弃。
@MainActor
package final class NativeVideoCollectionItem: NSCollectionViewItem, NativeHoverableCollectionItem,
    NativeVideoMenuTargetItem
{
    /// 只在 `.idle` 时发起请求；取消把加载中与失败都退回 `.idle`，卡片再次显示时重试。
    private enum ImagePhase: Equatable {
        case idle
        case loading(URL)
        case loaded(URL)
        case failed(URL)
    }

    private let card = NativeVideoCardView()
    private var coverTask: Task<Void, Never>?
    private var avatarTask: Task<Void, Never>?
    private var coverPhase: ImagePhase = .idle
    private var avatarPhase: ImagePhase = .idle
    private var reuseIdentity: NativeVideoReuseIdentity?
    private var generation: UInt64 = 0
    private var currentPresentation: NativeVideoCardPresentation?
    private var activation: ((String) -> Void)?
    private var hoverChanged: ((NativeVideoCollectionItem, Bool) -> Void)?

    package override var isSelected: Bool {
        didSet { card.setSelected(isSelected) }
    }

    package override var highlightState: NSCollectionViewItem.HighlightState {
        didSet { card.setPressed(highlightState == .forSelection) }
    }

    package var representedVideoID: String? { currentPresentation?.id }

    package override func loadView() {
        view = card
        card.menuHost = self
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
                coverPhase = .idle
                card.setCover(nil, animated: false)
            }
            if changesIdentity || changesAvatar {
                avatarPhase = .idle
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

    deinit {
        coverTask?.cancel()
        avatarTask?.cancel()
    }

    package func invalidateImageRequests() {
        coverTask?.cancel()
        avatarTask?.cancel()
        if case .loading = coverPhase { coverPhase = .idle }
        if case .failed = coverPhase { coverPhase = .idle }
        if case .loading = avatarPhase { avatarPhase = .idle }
        if case .failed = avatarPhase { avatarPhase = .idle }
        coverTask = nil
        avatarTask = nil
    }

    package func invalidate() {
        invalidateImageRequests()
        generation &+= 1
        currentPresentation = nil
        reuseIdentity = nil
        coverPhase = .idle
        avatarPhase = .idle
        activation = nil
        representedObject = nil
        card.reset()
        hoverChanged = nil
    }

    package func setHovered(_ isHovered: Bool) { card.setHovered(isHovered) }
    package func clearHover() { card.setHovered(false) }
    func setKeyboardFocusVisible(_ isVisible: Bool) {
        card.setKeyboardFocusVisible(isVisible)
    }
    package func setContextMenuTarget(_ isTarget: Bool) { card.setContextMenuTarget(isTarget) }
    func refreshEnvironmentAppearance() { card.refreshEnvironmentAppearance() }

    private func restartMissingImageRequests(
        presentation: NativeVideoCardPresentation,
        identity: NativeVideoReuseIdentity,
        pipeline: any NativeVideoImageLoading
    ) {
        if let coverURL = presentation.coverURL, coverPhase == .idle {
            if let cached = pipeline.cachedImage(for: coverURL, kind: .cover) {
                coverPhase = .loaded(coverURL)
                card.setCover(cached, animated: false)
            } else {
                coverPhase = .loading(coverURL)
                coverTask = loadImage(
                    at: coverURL,
                    kind: .cover,
                    identity: identity,
                    pipeline: pipeline
                ) { [weak self] result in
                    guard let self else { return }
                    coverTask = nil
                    if let result {
                        coverPhase = .loaded(coverURL)
                        card.setCover(result.image, animated: result.fadesIn)
                    } else {
                        coverPhase = .failed(coverURL)
                    }
                }
            }
        }
        if presentation.showsAvatar,
            let avatarURL = presentation.avatarURL,
            avatarPhase == .idle
        {
            if let cached = pipeline.cachedImage(for: avatarURL, kind: .avatar) {
                avatarPhase = .loaded(avatarURL)
                card.setAvatar(cached, animated: false)
                return
            }
            avatarPhase = .loading(avatarURL)
            avatarTask = loadImage(
                at: avatarURL,
                kind: .avatar,
                identity: identity,
                pipeline: pipeline
            ) { [weak self] result in
                guard let self else { return }
                avatarTask = nil
                if let result {
                    avatarPhase = .loaded(avatarURL)
                    card.setAvatar(result.image, animated: result.fadesIn)
                } else {
                    avatarPhase = .failed(avatarURL)
                }
            }
        }
    }

    private func loadImage(
        at url: URL,
        kind: NativeVideoCardImageKind,
        identity: NativeVideoReuseIdentity,
        pipeline: any NativeVideoImageLoading,
        apply: @escaping @MainActor (NativeVideoCardImage?) -> Void
    ) -> Task<Void, Never> {
        Task { [weak self] in
            let result = await pipeline.image(for: url, kind: kind)
            guard
                NativeVideoImageApplicationGate.accepts(
                    currentIdentity: self?.reuseIdentity,
                    resultIdentity: identity,
                    isCancelled: Task.isCancelled
                )
            else { return }
            apply(result)
        }
    }
}

/// 卡片视图：封面、头像与文字层的排版，悬停、按下、键盘选中与菜单目标的外观，读屏按钮语义。
///
/// 不取图，图片由 `NativeVideoCollectionItem` 设置；悬停变化经回调交给集合项。不可用卡片
/// （`NativeVideoCardAvailability.unavailable`）变暗并显示原因角标，不画悬停与按下，读屏呈现为
/// 不可用的按钮且按下不激活；键盘选中框照常显示，焦点可以停在上面。网格另在自己的激活入口拦截。
/// 读屏自定义操作与「显示菜单」经 `menuHost` 取所在集合视图的卡片菜单，与右键菜单同源。
@MainActor
final class NativeVideoCardView: NSView {
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
    private var activation: (() -> Void)?
    private var hoverDidChange: ((Bool) -> Void)?
    /// 读屏自定义操作与「显示菜单」的转发对象，即拥有这张卡片的集合项（`NativeVideoCardMenu.swift`）。
    weak var menuHost: NativeVideoCollectionItem?
    private var trackingArea: NSTrackingArea?
    private var showsAvatar = true
    private var isHovered = false
    private var selected = false
    private var showsKeyboardFocus = false
    private var isPressed = false
    /// 菜单打开期间的上下文描边，与键盘选中框同一外观。
    private var isContextMenuTarget = false
    private var isActivatable = true

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 12
        for subview in [cover, avatar] {
            subview.setAccessibilityElement(false)
            addSubview(subview)
        }
        if let layer { textRenderer.install(in: layer) }
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(
        presentation: NativeVideoCardPresentation,
        hoverDidChange: @escaping (Bool) -> Void,
        activation: @escaping () -> Void
    ) {
        self.activation = activation
        self.hoverDidChange = hoverDidChange
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
        textRenderer.configure(
            title: presentation.title,
            footerLeading: presentation.footerLeadingText,
            footerTrailing: presentation.footerTrailingText,
            footerTrailingSymbolName: presentation.footerTrailingSymbolName,
            footerTrailingStyle: presentation.footerTrailingStyle
        )
        setActivatable(presentation.isActivatable)
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

    func setSelected(_ selected: Bool) {
        self.selected = selected
        updateAccessibilityValue()
        updateInteractionAppearance()
    }

    func setKeyboardFocusVisible(_ isVisible: Bool) {
        guard showsKeyboardFocus != isVisible else { return }
        showsKeyboardFocus = isVisible
        updateInteractionAppearance()
    }

    func setContextMenuTarget(_ isTarget: Bool) {
        guard isContextMenuTarget != isTarget else { return }
        isContextMenuTarget = isTarget
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
        cover.reset()
        textRenderer.reset()
        avatar.isHidden = false
        showsAvatar = true
        setCover(nil, animated: false)
        setAvatar(nil, animated: false)
        isHovered = false
        selected = false
        showsKeyboardFocus = false
        isPressed = false
        isContextMenuTarget = false
        setActivatable(true)
        updateInteractionAppearance(animated: false)
        setAccessibilityLabel(nil)
        setAccessibilityHelp(nil)
        setAccessibilityValue(nil)
        if wasHovered { hoverDidChange?(false) }
        hoverDidChange = nil
    }

    func refreshEnvironmentAppearance() {
        updateInteractionAppearance(animated: false)
        needsLayout = true
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
        // 悬停与键盘选中的描边、底色是按外观解析后写进 layer 的，换主题时要重新解析。
        updateInteractionAppearance(animated: false)
    }

    override func layout() {
        super.layout()
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

    override func mouseEntered(with event: NSEvent) { setHovered(true) }
    override func mouseExited(with event: NSEvent) { setHovered(false) }

    override func accessibilityPerformPress() -> Bool {
        guard isActivatable, let activation else { return false }
        activation()
        return true
    }

    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
        menuHost?.accessibilityCardActions
    }

    /// 不可用卡片仍有可执行的菜单项时（稍后再看里失效视频的「从稍后再看移除」）保持读屏可用，否则读屏可能不列出操作、
    /// 也不提供「显示菜单」；按下仍由 `accessibilityPerformPress` 拒绝，不会进入播放。
    override func isAccessibilityEnabled() -> Bool {
        isActivatable || accessibilityCustomActions() != nil
    }

    override func accessibilityPerformShowMenu() -> Bool {
        menuHost?.presentCardMenu() ?? false
    }

    /// 可用性变化时同步变暗与读屏可用状态；外观由 `updateInteractionAppearance` 按它忽略悬停与按下。
    private func setActivatable(_ activatable: Bool) {
        let opacity: Float = activatable ? 1 : NativeVideoCardLayout.unavailableContentOpacity
        textRenderer.setContentOpacity(opacity)
        avatar.alphaValue = CGFloat(opacity)
        guard isActivatable != activatable else { return }
        isActivatable = activatable
        updateInteractionAppearance(animated: false)
    }

    private func updateAccessibilityValue() {
        setAccessibilityValue(
            VideoCardAccessibilityText.value(isSelected: selected, isActivatable: isActivatable)
        )
    }

    private func updateInteractionAppearance(animated: Bool = true) {
        guard let layer else { return }
        // 不可用卡片不画悬停与按下：它们暗示点了会有反应；键盘选中框仍画，表示焦点停在这里。
        NativeInteractiveSurface.apply(
            NativeInteractiveSurface.State(
                isHovered: isHovered && isActivatable,
                isPressed: isPressed && isActivatable,
                showsFocusRing: (selected && showsKeyboardFocus) || isContextMenuTarget
            ),
            to: layer,
            appearance: effectiveAppearance,
            animated: animated
        )
    }
}
