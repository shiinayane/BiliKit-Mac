import AppKit
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
        setAccessibilityValue(selected ? "已选择" : nil)
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
        setAccessibilityValue(selected ? "已选择" : nil)
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
        let coverHeight = floor(bounds.width * 9 / 16)
        cover.frame = NSRect(x: 0, y: 0, width: bounds.width, height: coverHeight)
        let textX: CGFloat = showsAvatar ? 44 : 0
        avatar.frame = NSRect(x: 0, y: coverHeight + 10, width: 34, height: 34)
        avatar.layer?.cornerRadius = 17
        let titleFrame = NSRect(
            x: textX,
            y: coverHeight + 10,
            width: max(1, bounds.width - textX),
            height: 47
        )
        let footerY = coverHeight + 63
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
                        + (21 - NativeVideoCardTextLayout.recommendationCapsuleHeight) / 2
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
                height: 21
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
                height: 21
            )
            footerTrailingFrame = NSRect(
                x: max(textX, bounds.width - footerWidths.trailing),
                y: footerY,
                width: footerWidths.trailing,
                height: 21
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

@MainActor
private final class NativeVideoMergedCoverView: NSView {
    private struct SymbolRasterKey: Hashable {
        let name: String
        let pointSize: CGFloat
        let weight: CGFloat
        let scale: CGFloat
        let appearanceName: String
        let tintName: String
    }

    private static let overlayHeight: CGFloat = 35
    private static let metricBottomOffset: CGFloat = 22
    private static let leadingInset: CGFloat = 9
    private static let iconSize: CGFloat = 12
    private static let symbolPointSize: CGFloat = 11
    private static let symbolWeight = NSFont.Weight.medium
    private static let iconTextSpacing: CGFloat = 4
    private static let metricSpacing: CGFloat = 10
    private static let trailingInset: CGFloat = 9
    private static let maximumSymbolRasterCount = 32
    private static var symbolRasters: [SymbolRasterKey: CGImage] = [:]

    private let placeholderLayer = CALayer()
    private let imageLayer = CALayer()
    private let gradientLayer = CAGradientLayer()
    private let metricIconLayers = [CALayer(), CALayer()]
    private let metricTextLayers = [
        NativeVideoMergedCoverView.makeTextLayer(
            font: .systemFont(ofSize: 12, weight: .medium)
        ),
        NativeVideoMergedCoverView.makeTextLayer(
            font: .systemFont(ofSize: 12, weight: .medium)
        ),
    ]
    private let metricCells = [
        NativeVideoMergedCoverView.makeLabelCell(
            font: .systemFont(ofSize: 12, weight: .medium)
        ),
        NativeVideoMergedCoverView.makeLabelCell(
            font: .systemFont(ofSize: 12, weight: .medium)
        ),
    ]
    private var metricIconNames: [String?] = [nil, nil]
    private var metricSizes: [NSSize] = [.zero, .zero]
    private var metricCount = 0
    private let trailingCell = NativeVideoMergedCoverView.makeLabelCell(
        font: .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
    )
    private let trailingTextLayer = NativeVideoMergedCoverView.makeTextLayer(
        font: .monospacedDigitSystemFont(ofSize: 12, weight: .medium),
        alignmentMode: .right
    )
    private var trailingSize = NSSize.zero
    private var imageGeneration: UInt64 = 0

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.masksToBounds = true
        layer?.backgroundColor = Self.backgroundColor

        placeholderLayer.contentsGravity = .center
        placeholderLayer.actions = Self.imageLayerActions
        imageLayer.contentsGravity = .resizeAspectFill
        imageLayer.actions = Self.imageLayerActions
        gradientLayer.colors = [
            NSColor.clear.cgColor,
            NSColor.black.withAlphaComponent(0.78).cgColor,
        ]
        gradientLayer.startPoint = CGPoint(x: 0.5, y: 0)
        gradientLayer.endPoint = CGPoint(x: 0.5, y: 1)
        gradientLayer.actions = Self.disabledLayerActions
        layer?.addSublayer(placeholderLayer)
        layer?.addSublayer(imageLayer)
        layer?.addSublayer(gradientLayer)
        for index in metricIconLayers.indices {
            let iconLayer = metricIconLayers[index]
            iconLayer.contentsGravity = .resizeAspect
            iconLayer.actions = Self.disabledLayerActions
            iconLayer.isHidden = true
            layer?.addSublayer(iconLayer)

            metricTextLayers[index].isHidden = true
            layer?.addSublayer(metricTextLayers[index])
        }
        trailingTextLayer.isHidden = true
        layer?.addSublayer(trailingTextLayer)
        refreshPlaceholderImage()
        setImage(nil, animated: false)
        updateContentsScale()
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(metrics: [NativeVideoCardMetric], trailingText: String?) {
        metricCount = min(metrics.count, metricCells.count)
        for index in metricCells.indices {
            guard index < metricCount else {
                metricCells[index].stringValue = ""
                metricIconNames[index] = nil
                metricSizes[index] = .zero
                metricIconLayers[index].contents = nil
                metricIconLayers[index].isHidden = true
                metricTextLayers[index].string = nil
                metricTextLayers[index].isHidden = true
                continue
            }
            let metric = metrics[index]
            metricCells[index].stringValue = metric.text
            metricTextLayers[index].string = metric.text
            metricTextLayers[index].isHidden = false
            metricIconNames[index] = metric.systemImage
            metricSizes[index] = integralSize(metricCells[index].cellSize)
        }
        trailingCell.stringValue = trailingText ?? ""
        trailingTextLayer.string = trailingText ?? ""
        trailingTextLayer.isHidden = trailingText?.isEmpty ?? true
        trailingSize = integralSize(trailingCell.cellSize)
        refreshMetricIcons()
        needsLayout = true
    }

    func reset() {
        metricCount = 0
        for index in metricCells.indices {
            metricCells[index].stringValue = ""
            metricIconNames[index] = nil
            metricSizes[index] = .zero
            metricIconLayers[index].contents = nil
            metricIconLayers[index].isHidden = true
            metricTextLayers[index].string = nil
            metricTextLayers[index].isHidden = true
        }
        trailingCell.stringValue = ""
        trailingTextLayer.string = nil
        trailingTextLayer.isHidden = true
        trailingSize = .zero
        setImage(nil, animated: false)
        needsLayout = true
    }

    func setImage(_ image: CGImage?, animated: Bool) {
        imageGeneration &+= 1
        let generation = imageGeneration
        imageLayer.removeAnimation(forKey: "native-video-image.fade")
        imageLayer.contents = image
        imageLayer.opacity = 1
        guard
            image != nil,
            animated,
            !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        else {
            placeholderLayer.isHidden = image != nil
            return
        }
        placeholderLayer.isHidden = false
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = 0
        animation.toValue = 1
        animation.duration = 0.15
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            guard let self, imageGeneration == generation else { return }
            placeholderLayer.isHidden = true
        }
        imageLayer.add(animation, forKey: "native-video-image.fade")
        CATransaction.commit()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateContentsScale()
        refreshMetricIcons()
        needsLayout = true
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateContentsScale()
        refreshMetricIcons()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        layer?.backgroundColor = Self.backgroundColor
        refreshPlaceholderImage()
        refreshMetricIcons()
    }

    override func layout() {
        super.layout()
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let placeholderSize = NSSize(width: 32, height: 32)
        placeholderLayer.frame = NSRect(
            x: floor((bounds.width - placeholderSize.width) / 2),
            y: floor((bounds.height - placeholderSize.height) / 2),
            width: placeholderSize.width,
            height: placeholderSize.height
        )
        imageLayer.frame = bounds
        let overlayHeight = min(Self.overlayHeight, bounds.height)
        gradientLayer.frame = NSRect(
            x: 0,
            y: bounds.height - overlayHeight,
            width: bounds.width,
            height: overlayHeight
        )
        let metricY = bounds.height - Self.metricBottomOffset
        var nextX = Self.leadingInset
        for index in 0..<metricCount {
            let iconFrame = NSRect(
                x: nextX,
                y: metricY + 2,
                width: Self.iconSize,
                height: Self.iconSize
            )
            metricIconLayers[index].frame = iconFrame
            let cellSize = metricSizes[index]
            let cellFrame = NSRect(
                x: iconFrame.maxX + Self.iconTextSpacing,
                y: metricY,
                width: cellSize.width,
                height: cellSize.height
            )
            metricTextLayers[index].frame = cellFrame
            nextX = cellFrame.maxX + Self.metricSpacing
        }
        if !trailingCell.stringValue.isEmpty {
            trailingTextLayer.frame = NSRect(
                x: bounds.width - trailingSize.width - Self.trailingInset,
                y: metricY,
                width: trailingSize.width,
                height: trailingSize.height
            )
        }
        placeholderLayer.contentsScale = scale
        imageLayer.contentsScale = scale
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private func integralSize(_ size: NSSize) -> NSSize {
        NSSize(width: ceil(size.width), height: ceil(size.height))
    }

    private func refreshMetricIcons() {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let appearance = effectiveAppearance
        for index in 0..<metricCount {
            guard let name = metricIconNames[index] else {
                metricIconLayers[index].contents = nil
                metricIconLayers[index].isHidden = true
                continue
            }
            let icon = Self.symbolRaster(
                named: name,
                scale: scale,
                appearance: appearance
            )
            metricIconLayers[index].contents = icon
            metricIconLayers[index].contentsScale = scale
            metricIconLayers[index].isHidden = icon == nil
        }
        needsLayout = true
    }

    private func refreshPlaceholderImage() {
        let configuration = NSImage.SymbolConfiguration(
            paletteColors: [.tertiaryLabelColor]
        )
        placeholderLayer.contents = NSImage(
            systemSymbolName: "photo",
            accessibilityDescription: nil
        )?.withSymbolConfiguration(configuration)
    }

    private func updateContentsScale() {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        placeholderLayer.contentsScale = scale
        imageLayer.contentsScale = scale
        for textLayer in metricTextLayers {
            textLayer.contentsScale = scale
        }
        trailingTextLayer.contentsScale = scale
    }

    private static func makeLabelCell(font: NSFont) -> NSTextFieldCell {
        let cell = NSTextFieldCell(textCell: "")
        cell.font = font
        cell.textColor = .white
        cell.lineBreakMode = .byTruncatingTail
        cell.isBezeled = false
        cell.isBordered = false
        cell.drawsBackground = false
        cell.isEditable = false
        cell.isSelectable = false
        cell.usesSingleLineMode = true
        return cell
    }

    private static func makeTextLayer(
        font: NSFont,
        alignmentMode: CATextLayerAlignmentMode = .left
    ) -> CATextLayer {
        let textLayer = CATextLayer()
        textLayer.font = NativeVideoCardTextLayout.languageAwareCTFont(font)
        textLayer.fontSize = font.pointSize
        textLayer.foregroundColor = NSColor.white.cgColor
        textLayer.alignmentMode = alignmentMode
        textLayer.truncationMode = .end
        textLayer.isWrapped = false
        textLayer.actions = disabledLayerActions
        return textLayer
    }

    private static let disabledLayerActions: [String: CAAction] = [
        "bounds": NSNull(),
        "contents": NSNull(),
        "hidden": NSNull(),
        "position": NSNull(),
        "string": NSNull(),
    ]

    private static let imageLayerActions: [String: CAAction] = [
        "bounds": NSNull(),
        "contents": NSNull(),
        "hidden": NSNull(),
        "opacity": NSNull(),
        "position": NSNull(),
    ]

    private static func symbolRaster(
        named name: String,
        scale: CGFloat,
        appearance: NSAppearance
    ) -> CGImage? {
        let key = SymbolRasterKey(
            name: name,
            pointSize: symbolPointSize,
            weight: symbolWeight.rawValue,
            scale: scale,
            appearanceName: appearance.name.rawValue,
            tintName: "white"
        )
        if let cached = symbolRasters[key] { return cached }

        var raster: CGImage?
        appearance.performAsCurrentDrawingAppearance {
            let pointConfiguration = NSImage.SymbolConfiguration(
                pointSize: symbolPointSize,
                weight: symbolWeight
            )
            let colorConfiguration = NSImage.SymbolConfiguration(paletteColors: [.white])
            guard
                let image = NSImage(
                    systemSymbolName: name,
                    accessibilityDescription: nil
                )?.withSymbolConfiguration(pointConfiguration.applying(colorConfiguration))
            else { return }

            let pixelWidth = max(1, Int(ceil(iconSize * scale)))
            let pixelHeight = max(1, Int(ceil(iconSize * scale)))
            guard
                let representation = NSBitmapImageRep(
                    bitmapDataPlanes: nil,
                    pixelsWide: pixelWidth,
                    pixelsHigh: pixelHeight,
                    bitsPerSample: 8,
                    samplesPerPixel: 4,
                    hasAlpha: true,
                    isPlanar: false,
                    colorSpaceName: .deviceRGB,
                    bytesPerRow: 0,
                    bitsPerPixel: 0
                )
            else { return }
            representation.size = NSSize(width: iconSize, height: iconSize)
            guard let graphicsContext = NSGraphicsContext(bitmapImageRep: representation) else {
                return
            }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = graphicsContext
            graphicsContext.cgContext.clear(
                NSRect(x: 0, y: 0, width: iconSize, height: iconSize)
            )
            image.draw(
                in: NSRect(x: 0, y: 0, width: iconSize, height: iconSize),
                from: .zero,
                operation: .sourceOver,
                fraction: 1,
                respectFlipped: false,
                hints: [.interpolation: NSImageInterpolation.high]
            )
            graphicsContext.flushGraphics()
            NSGraphicsContext.restoreGraphicsState()
            raster = representation.cgImage
        }
        guard let raster else { return nil }

        if symbolRasters.count >= maximumSymbolRasterCount,
            let oldestKey = symbolRasters.keys.first
        {
            symbolRasters.removeValue(forKey: oldestKey)
        }
        symbolRasters[key] = raster
        return raster
    }

    private static var backgroundColor: CGColor {
        NSColor.secondaryLabelColor.withAlphaComponent(0.12).cgColor
    }
}

@MainActor
private final class NativeVideoLayerImageView: NSView {
    private let placeholderSystemSymbolName: String
    private let placeholderTintColor: NSColor
    private let placeholderFrameSize: NSSize?
    private let placeholderLayer = CALayer()
    private let imageLayer = CALayer()
    private var imageGeneration: UInt64 = 0

    init(
        placeholderSystemSymbolName: String,
        placeholderTintColor: NSColor,
        placeholderFrameSize: NSSize? = nil
    ) {
        self.placeholderSystemSymbolName = placeholderSystemSymbolName
        self.placeholderTintColor = placeholderTintColor
        self.placeholderFrameSize = placeholderFrameSize
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        placeholderLayer.contentsGravity = .center
        placeholderLayer.actions = [
            "contents": NSNull(),
            "hidden": NSNull(),
            "position": NSNull(),
            "bounds": NSNull(),
        ]
        imageLayer.contentsGravity = .resizeAspectFill
        imageLayer.actions = [
            "contents": NSNull(),
            "opacity": NSNull(),
            "position": NSNull(),
            "bounds": NSNull(),
        ]
        layer?.addSublayer(placeholderLayer)
        layer?.addSublayer(imageLayer)
        refreshPlaceholderImage()
        setImage(nil, animated: false)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        let size = placeholderFrameSize ?? bounds.size
        placeholderLayer.frame = NSRect(
            x: floor((bounds.width - size.width) / 2),
            y: floor((bounds.height - size.height) / 2),
            width: size.width,
            height: size.height
        )
        imageLayer.frame = bounds
        placeholderLayer.contentsScale = window?.backingScaleFactor ?? 2
        imageLayer.contentsScale = window?.backingScaleFactor ?? 2
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshPlaceholderImage()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        needsLayout = true
    }

    func setImage(_ image: CGImage?, animated: Bool) {
        imageGeneration &+= 1
        let generation = imageGeneration
        imageLayer.removeAnimation(forKey: "native-video-image.fade")
        imageLayer.contents = image
        imageLayer.opacity = 1
        guard
            image != nil,
            animated,
            !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        else {
            placeholderLayer.isHidden = image != nil
            return
        }
        placeholderLayer.isHidden = false
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = 0
        animation.toValue = 1
        animation.duration = 0.15
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            guard let self, imageGeneration == generation else { return }
            placeholderLayer.isHidden = true
        }
        imageLayer.add(animation, forKey: "native-video-image.fade")
        CATransaction.commit()
    }

    private func refreshPlaceholderImage() {
        let colorConfiguration = NSImage.SymbolConfiguration(
            paletteColors: [placeholderTintColor]
        )
        placeholderLayer.contents = NSImage(
            systemSymbolName: placeholderSystemSymbolName,
            accessibilityDescription: nil
        )?.withSymbolConfiguration(colorConfiguration)
    }
}
