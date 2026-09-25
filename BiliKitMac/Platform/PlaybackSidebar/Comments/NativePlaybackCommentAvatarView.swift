import AppKit
import BiliModels

@MainActor
final class NativePlaybackCommentAvatarView: NSView {
    override var isFlipped: Bool { true }
    private let avatarImage = NSImageView()
    private let initialLabel = NSTextField(labelWithString: "")
    private let badgeImage = NSImageView()
    private var author: CommentAuthor?
    private var isReply = false
    private var imageGeneration: UInt64 = 0
    private var imageTask: Task<Void, Never>?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        avatarImage.wantsLayer = true
        avatarImage.imageScaling = .scaleAxesIndependently
        avatarImage.setAccessibilityElement(false)
        initialLabel.alignment = .center
        initialLabel.textColor = .white
        badgeImage.contentTintColor = .white
        badgeImage.imageScaling = .scaleProportionallyDown
        badgeImage.setAccessibilityElement(false)
        addSubview(avatarImage)
        addSubview(initialLabel)
        addSubview(badgeImage)
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func configure(
        author: CommentAuthor,
        isReply: Bool,
        loader: NativePlaybackCommentAvatarLoader
    ) {
        cancelImageRequest()
        self.author = author
        self.isReply = isReply
        avatarImage.image = nil
        avatarImage.isHidden = true
        initialLabel.isHidden = false
        initialLabel.stringValue = author.name.first.map(String.init) ?? "•"
        initialLabel.font = .systemFont(ofSize: isReply ? 9 : 12, weight: .bold)
        let symbolName: String? =
            switch author.verification {
            case .personal: "person.fill.checkmark"
            case .organization: "building.2.fill"
            case nil: author.isVIP ? "crown.fill" : nil
            }
        badgeImage.image = symbolName.flatMap {
            NSImage(systemSymbolName: $0, accessibilityDescription: nil)
        }
        badgeImage.isHidden = badgeImage.image == nil
        if let reference = author.avatar {
            if let cached = loader.cachedImage(for: reference) {
                apply(cached, animated: false)
            } else {
                let generation = imageGeneration
                imageTask = Task { [weak self] in
                    let result = await loader.image(for: reference)
                    guard let self, !Task.isCancelled,
                        self.imageGeneration == generation,
                        self.author?.avatar == reference
                    else { return }
                    self.imageTask = nil
                    guard let result else { return }
                    self.apply(
                        result.image,
                        animated: result.origin.shouldAnimate
                    )
                }
            }
        }
        needsLayout = true
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        avatarImage.frame = bounds
        avatarImage.wantsLayer = true
        avatarImage.layer?.cornerRadius = bounds.width / 2
        avatarImage.layer?.masksToBounds = true
        initialLabel.frame = bounds
        let badgeSize: CGFloat = isReply ? 10 : 13
        badgeImage.frame = NSRect(
            x: bounds.maxX - badgeSize,
            y: bounds.maxY - badgeSize,
            width: badgeSize,
            height: badgeSize
        )
        badgeImage.symbolConfiguration = NSImage.SymbolConfiguration(
            pointSize: isReply ? 6 : 8,
            weight: .bold
        )
        badgeImage.wantsLayer = true
        badgeImage.layer?.cornerRadius = badgeSize / 2
        badgeImage.layer?.backgroundColor = NSColor.systemPink.cgColor
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard !initialLabel.isHidden else { return }
        let path = NSBezierPath(ovalIn: bounds)
        path.addClip()
        NSGradient(
            starting: .systemPink,
            ending: .systemBlue
        )?.draw(in: bounds, angle: -45)
    }

    func releaseImage() {
        cancelImageRequest()
        avatarImage.image = nil
        avatarImage.isHidden = true
        initialLabel.isHidden = false
        needsDisplay = true
    }

    func reset() {
        releaseImage()
        author = nil
        initialLabel.stringValue = ""
        badgeImage.image = nil
        badgeImage.isHidden = true
    }

    private func cancelImageRequest() {
        imageGeneration &+= 1
        imageTask?.cancel()
        imageTask = nil
        avatarImage.layer?.removeAnimation(
            forKey: "native-playback-comment-avatar.fade"
        )
        avatarImage.layer?.opacity = 1
    }

    private func apply(_ image: CGImage, animated: Bool) {
        let generation = imageGeneration
        avatarImage.image = NSImage(
            cgImage: image,
            size: NSSize(width: image.width, height: image.height)
        )
        avatarImage.isHidden = false
        guard animated,
            !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
            let imageLayer = avatarImage.layer
        else {
            initialLabel.isHidden = true
            needsDisplay = true
            return
        }
        imageLayer.removeAnimation(
            forKey: "native-playback-comment-avatar.fade"
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
            self.initialLabel.isHidden = true
            self.needsDisplay = true
        }
        imageLayer.add(
            animation,
            forKey: "native-playback-comment-avatar.fade"
        )
        CATransaction.commit()
        needsDisplay = true
    }
}
