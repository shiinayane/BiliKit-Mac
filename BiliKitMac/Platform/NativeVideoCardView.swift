import AppKit
import BiliUI
import CoreGraphics
import QuartzCore

extension NSUserInterfaceItemIdentifier {
    static let nativeVideoCard = Self("native.video-card")
}

struct NativeVideoCardFooterWidths: Equatable {
    let leading: CGFloat
    let trailing: CGFloat
}

enum NativeVideoCardLayout {
    static let footerSpacing: CGFloat = 8
    static let recommendationFooterMinimumLeadingWidth: CGFloat = 72

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

@MainActor
final class NativeVideoCollectionItem: NSCollectionViewItem {
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

    override var isSelected: Bool {
        didSet { card.setSelected(isSelected) }
    }

    override var highlightState: NSCollectionViewItem.HighlightState {
        didSet { card.setPressed(highlightState == .forSelection) }
    }

    var representedVideoID: String? { currentPresentation?.id }

    override func loadView() {
        view = card
    }

    func configure(
        presentation: NativeVideoCardPresentation,
        imagePipeline: NativeVideoImagePipeline,
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

    override func prepareForReuse() {
        super.prepareForReuse()
        invalidate()
    }

    deinit {
        coverTask?.cancel()
        avatarTask?.cancel()
    }

    func invalidateImageRequests() {
        coverTask?.cancel()
        avatarTask?.cancel()
        if case .loading = coverPhase { coverPhase = .idle }
        if case .failed = coverPhase { coverPhase = .idle }
        if case .loading = avatarPhase { avatarPhase = .idle }
        if case .failed = avatarPhase { avatarPhase = .idle }
        coverTask = nil
        avatarTask = nil
    }

    func invalidate() {
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

    func setHovered(_ isHovered: Bool) { card.setHovered(isHovered) }
    func clearHover() { card.setHovered(false) }
    func setKeyboardFocusVisible(_ isVisible: Bool) {
        card.setKeyboardFocusVisible(isVisible)
    }
    func refreshEnvironmentAppearance() { card.refreshEnvironmentAppearance() }

    private func restartMissingImageRequests(
        presentation: NativeVideoCardPresentation,
        identity: NativeVideoReuseIdentity,
        pipeline: NativeVideoImagePipeline
    ) {
        if let coverURL = presentation.coverURL, coverPhase == .idle {
            if let cached = pipeline.cachedImage(for: coverURL, variant: .cover) {
                coverPhase = .loaded(coverURL)
                card.setCover(cached, animated: false)
            } else {
                coverPhase = .loading(coverURL)
                coverTask = loadImage(
                    at: coverURL,
                    variant: .cover,
                    identity: identity,
                    pipeline: pipeline
                ) { [weak self] result in
                    guard let self else { return }
                    coverTask = nil
                    if let result {
                        coverPhase = .loaded(coverURL)
                        card.setCover(result.image, animated: result.origin.shouldAnimate)
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
            if let cached = pipeline.cachedImage(for: avatarURL, variant: .avatar) {
                avatarPhase = .loaded(avatarURL)
                card.setAvatar(cached, animated: false)
                return
            }
            avatarPhase = .loading(avatarURL)
            avatarTask = loadImage(
                at: avatarURL,
                variant: .avatar,
                identity: identity,
                pipeline: pipeline
            ) { [weak self] result in
                guard let self else { return }
                avatarTask = nil
                if let result {
                    avatarPhase = .loaded(avatarURL)
                    card.setAvatar(result.image, animated: result.origin.shouldAnimate)
                } else {
                    avatarPhase = .failed(avatarURL)
                }
            }
        }
    }

    private func loadImage(
        at url: URL,
        variant: NativeVideoImageVariant,
        identity: NativeVideoReuseIdentity,
        pipeline: NativeVideoImagePipeline,
        apply: @escaping @MainActor (NativeVideoImageLoadResult?) -> Void
    ) -> Task<Void, Never> {
        Task { [weak self] in
            let result = await pipeline.image(for: url, variant: variant)
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

@MainActor
final class NativeVideoCardView: NSView {
    private let cover = NativeVideoMergedCoverView(frame: .zero)
    private let avatar = NativeVideoLayerImageView(
        placeholderSystemSymbolName: "person.crop.circle.fill",
        placeholderTintColor: .quaternaryLabelColor
    )
    private let titleFont = NSFont.systemFont(
        ofSize: NSFont.preferredFont(forTextStyle: .title3).pointSize,
        weight: .medium
    )
    private let footerFont = NSFont.preferredFont(forTextStyle: .body)
    private let textRenderer = NativeVideoCardTextRenderer()
    private var activation: (() -> Void)?
    private var hoverDidChange: ((Bool) -> Void)?
    private var trackingArea: NSTrackingArea?
    private var showsAvatar = true
    private var isHovered = false
    private var selected = false
    private var showsKeyboardFocus = false
    private var isPressed = false

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
        cover.configure(
            metrics: presentation.coverMetrics,
            trailingText: presentation.coverTrailingText
        )
        textRenderer.configure(
            title: presentation.title,
            footerLeading: presentation.footerLeadingText,
            footerTrailing: presentation.footerTrailingText,
            footerTrailingStyle: presentation.footerTrailingStyle
        )
        setAccessibilityLabel(presentation.accessibilityLabel)
        setAccessibilityHelp(presentation.accessibilityHelp)
        setAccessibilityValue(selected ? AppStrings.localized("已选择") : nil)
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
        setAccessibilityValue(selected ? AppStrings.localized("已选择") : nil)
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

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func mouseEntered(with event: NSEvent) { setHovered(true) }
    override func mouseExited(with event: NSEvent) { setHovered(false) }

    override func accessibilityPerformPress() -> Bool {
        guard let activation else { return false }
        activation()
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
            from: presentation?.backgroundColor,
            to: targetBackground,
            duration: duration
        )
        addAnimation(
            to: layer,
            keyPath: "borderColor",
            from: presentation?.borderColor,
            to: showsStroke ? targetBorder : NSColor.clear.cgColor,
            duration: duration
        )
        addAnimation(
            to: layer,
            keyPath: "borderWidth",
            from: presentation?.borderWidth,
            to: targetBorderWidth,
            duration: duration
        )
        addAnimation(
            to: layer,
            keyPath: "transform",
            from: presentation?.transform,
            to: targetTransform,
            duration: duration
        )
        addAnimation(
            to: layer,
            keyPath: "opacity",
            from: presentation?.opacity,
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
        layer.add(animation, forKey: "native-video-card.\(keyPath)")
    }
}
