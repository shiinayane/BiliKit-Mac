import AppKit
import BiliModels

struct NativePlaybackCommentPictureSlot: Equatable {
    let reference: CommentAssetReference?
    let pixelWidth: Int?
    let pixelHeight: Int?
}

struct NativePlaybackCommentPictureSlots {
    static func slots(
        images: [CommentImage],
        count: Int
    ) -> [NativePlaybackCommentPictureSlot] {
        let displayedCount = min(max(count, 0), 9)
        var result = [NativePlaybackCommentPictureSlot](
            repeating: NativePlaybackCommentPictureSlot(
                reference: nil,
                pixelWidth: nil,
                pixelHeight: nil
            ),
            count: displayedCount
        )
        for (fallbackPosition, image) in images.enumerated() {
            let position = image.position ?? fallbackPosition
            guard result.indices.contains(position),
                result[position].reference == nil
            else { continue }
            result[position] = NativePlaybackCommentPictureSlot(
                reference: image.asset,
                pixelWidth: image.pixelWidth,
                pixelHeight: image.pixelHeight
            )
        }
        return result
    }
}

struct NativePlaybackCommentPictureLayout: Equatable {
    static let maximumContentWidth: CGFloat = 364
    static let maximumImageHeight: CGFloat = 180
    static let gap: CGFloat = 4
    static let fallbackExtent: CGFloat = 120
    static let sourcePixelScale: CGFloat = 2

    let frames: [CGRect]
    let size: CGSize

    static func make(
        images: [CommentImage],
        count: Int,
        availableWidth: CGFloat
    ) -> Self {
        make(
            slots: NativePlaybackCommentPictureSlots.slots(
                images: images,
                count: count
            ),
            availableWidth: availableWidth
        )
    }

    static func make(
        slots: [NativePlaybackCommentPictureSlot],
        availableWidth: CGFloat
    ) -> Self {
        let contentWidth = floor(
            min(max(0, availableWidth), maximumContentWidth)
        )
        guard !slots.isEmpty, contentWidth >= 1 else {
            return Self(frames: [], size: .zero)
        }

        var frames: [CGRect] = []
        frames.reserveCapacity(slots.count)
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0

        for slot in slots {
            let itemSize = displaySize(
                for: slot,
                availableWidth: contentWidth
            )
            if x > 0, x + itemSize.width > contentWidth {
                y += rowHeight + gap
                x = 0
                rowHeight = 0
            }
            let frame = CGRect(origin: CGPoint(x: x, y: y), size: itemSize)
            frames.append(frame)
            x = frame.maxX + gap
            rowHeight = max(rowHeight, itemSize.height)
        }

        return Self(
            frames: frames,
            size: CGSize(width: contentWidth, height: ceil(y + rowHeight))
        )
    }

    private static func displaySize(
        for slot: NativePlaybackCommentPictureSlot,
        availableWidth: CGFloat
    ) -> CGSize {
        guard let pixelWidth = slot.pixelWidth,
            let pixelHeight = slot.pixelHeight,
            pixelWidth > 0,
            pixelHeight > 0
        else {
            let extent = min(fallbackExtent, availableWidth)
            return CGSize(width: extent, height: extent)
        }

        let sourceWidth = CGFloat(pixelWidth) / sourcePixelScale
        let sourceHeight = CGFloat(pixelHeight) / sourcePixelScale
        let scale = min(
            1,
            min(
                availableWidth / sourceWidth,
                maximumImageHeight / sourceHeight
            )
        )
        return CGSize(
            width: max(1, floor(sourceWidth * scale)),
            height: max(1, floor(sourceHeight * scale))
        )
    }
}

@MainActor
struct NativePlaybackCommentPictureGallery {
    let references: [CommentAssetReference]
    let selectedIndex: Int
    let restoreFocus: () -> Void
}

@MainActor
final class NativePlaybackCommentPicturesView: NSView {
    nonisolated override var isFlipped: Bool { true }
    private let tiles = (0..<9).map { _ in NativePlaybackCommentPictureTileView() }
    private var slots: [NativePlaybackCommentPictureSlot] = []
    private var onOpen: ((NativePlaybackCommentPictureGallery) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        for tile in tiles {
            tile.isHidden = true
            addSubview(tile)
        }
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func configure(
        images: [CommentImage],
        count: Int,
        loader: NativePlaybackCommentPictureLoader,
        onOpen: @escaping (NativePlaybackCommentPictureGallery) -> Void
    ) {
        self.onOpen = onOpen
        slots = NativePlaybackCommentPictureSlots.slots(
            images: images,
            count: count
        )
        for (index, tile) in tiles.enumerated() {
            guard slots.indices.contains(index) else {
                tile.isHidden = true
                tile.reset()
                continue
            }
            tile.isHidden = false
            tile.configure(
                reference: slots[index].reference,
                position: index,
                loader: loader,
                onOpen: { [weak self] in self?.openPicture(at: index) }
            )
        }
        setAccessibilityElement(!slots.isEmpty)
        setAccessibilityRole(.group)
        setAccessibilityLabel(AppStrings.localized("评论图片，共 \(slots.count) 张"))
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let pictureLayout = NativePlaybackCommentPictureLayout.make(
            slots: slots,
            availableWidth: bounds.width
        )
        for (index, frame) in pictureLayout.frames.enumerated() {
            tiles[index].frame = frame
        }
    }

    func releaseImages() {
        for tile in tiles { tile.releaseImage() }
    }

    func reset() {
        slots = []
        onOpen = nil
        for tile in tiles {
            tile.isHidden = true
            tile.reset()
        }
        setAccessibilityElement(false)
        setAccessibilityLabel(nil)
    }

    private func openPicture(at slotIndex: Int) {
        let validSlots = slots.enumerated().compactMap { index, slot in
            slot.reference.map { (slotIndex: index, reference: $0) }
        }
        guard
            let selectedIndex = validSlots.firstIndex(where: {
                $0.slotIndex == slotIndex
            }), tiles.indices.contains(slotIndex)
        else { return }
        let sourceTile = tiles[slotIndex]
        let selectedReference = validSlots[selectedIndex].reference
        onOpen?(
            NativePlaybackCommentPictureGallery(
                references: validSlots.map(\.reference),
                selectedIndex: selectedIndex,
                restoreFocus: { [weak sourceTile] in
                    guard
                        let sourceTile,
                        sourceTile.represents(selectedReference),
                        let window = sourceTile.window
                    else { return }
                    window.makeFirstResponder(sourceTile)
                }
            )
        )
    }
}

@MainActor
private final class NativePlaybackCommentPictureTileView: NSButton {
    nonisolated override var isFlipped: Bool { true }
    private let imageView = NSImageView()
    private let placeholderLabel = NSTextField(labelWithString: AppStrings.localized("图片"))
    private var reference: CommentAssetReference?
    private var imageGeneration: UInt64 = 0
    private var imageTask: Task<Void, Never>?
    private var isShowingPlaceholder = true
    private var onOpen: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        title = ""
        isBordered = false
        focusRingType = .exterior
        target = self
        action = #selector(openPicture)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.masksToBounds = true
        imageView.wantsLayer = true
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignCenter
        imageView.setAccessibilityElement(false)
        placeholderLabel.font = .preferredFont(forTextStyle: .caption2)
        placeholderLabel.textColor = .secondaryLabelColor
        placeholderLabel.alignment = .center
        placeholderLabel.setAccessibilityElement(false)
        addSubview(imageView)
        addSubview(placeholderLabel)
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard super.hitTest(point) != nil else { return nil }
        return self
    }

    override func updateLayer() {
        super.updateLayer()
        layer?.backgroundColor =
            isShowingPlaceholder
            ? NSColor.secondaryLabelColor.withAlphaComponent(0.06).cgColor
            : NSColor.clear.cgColor
        layer?.borderWidth = 0
    }

    override func layout() {
        super.layout()
        imageView.frame = bounds
        placeholderLabel.frame = NSRect(
            x: 4,
            y: max(0, bounds.midY - 9),
            width: max(0, bounds.width - 8),
            height: 18
        )
    }

    func configure(
        reference: CommentAssetReference?,
        position: Int,
        loader: NativePlaybackCommentPictureLoader,
        onOpen: @escaping () -> Void
    ) {
        cancelImageRequest()
        self.reference = reference
        self.onOpen = reference == nil ? nil : onOpen
        isEnabled = reference != nil
        setAccessibilityElement(reference != nil)
        setAccessibilityRole(.button)
        setAccessibilityLabel(
            reference == nil
                ? nil : AppStrings.localized("查看第 \(position + 1) 张评论图片")
        )
        imageView.image = nil
        imageView.isHidden = true
        placeholderLabel.isHidden = false
        isShowingPlaceholder = true
        needsDisplay = true
        guard let reference else { return }
        if let cached = loader.cachedImage(for: reference) {
            apply(cached, animated: false)
            return
        }
        let generation = imageGeneration
        imageTask = Task { [weak self] in
            let result = await loader.image(for: reference)
            guard let self, !Task.isCancelled,
                self.imageGeneration == generation,
                self.reference == reference
            else { return }
            self.imageTask = nil
            guard let result else { return }
            self.apply(
                result.image,
                animated: result.origin.shouldAnimate
            )
        }
    }

    func releaseImage() {
        cancelImageRequest()
        imageView.image = nil
        imageView.isHidden = true
        placeholderLabel.isHidden = false
        isShowingPlaceholder = true
        needsDisplay = true
    }

    func reset() {
        releaseImage()
        reference = nil
        onOpen = nil
        isEnabled = false
        setAccessibilityElement(false)
        setAccessibilityLabel(nil)
    }

    func represents(_ reference: CommentAssetReference) -> Bool {
        self.reference == reference && isEnabled && !isHidden
    }

    private func cancelImageRequest() {
        imageGeneration &+= 1
        imageTask?.cancel()
        imageTask = nil
        imageView.layer?.removeAnimation(
            forKey: "native-playback-comment-picture.fade"
        )
        imageView.layer?.opacity = 1
    }

    private func apply(_ image: CGImage, animated: Bool) {
        let generation = imageGeneration
        imageView.image = NSImage(
            cgImage: image,
            size: NSSize(width: image.width, height: image.height)
        )
        imageView.isHidden = false
        placeholderLabel.isHidden = true
        guard animated,
            !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
            let imageLayer = imageView.layer
        else {
            isShowingPlaceholder = false
            needsDisplay = true
            return
        }
        imageLayer.removeAnimation(
            forKey: "native-playback-comment-picture.fade"
        )
        imageLayer.opacity = 1
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = 0
        animation.toValue = 1
        animation.duration = NativePlaybackCommentImageTransition.duration
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            guard let self, self.imageGeneration == generation else { return }
            self.isShowingPlaceholder = false
            self.needsDisplay = true
        }
        imageLayer.add(
            animation,
            forKey: "native-playback-comment-picture.fade"
        )
        CATransaction.commit()
        needsDisplay = true
    }

    @objc private func openPicture() {
        onOpen?()
    }
}
