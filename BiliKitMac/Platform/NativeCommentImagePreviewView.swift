import AppKit
import BiliModels
import SwiftUI

@MainActor
struct NativeCommentImagePreviewRequest: Identifiable {
    let id = UUID()
    let bvid: String
    let references: [CommentAssetReference]
    let selectedIndex: Int
    let restoreFocus: () -> Void
}

private struct NativeCommentImagePreviewRepresentable: NSViewRepresentable {
    let request: NativeCommentImagePreviewRequest
    let imagePipeline: NativeVideoImagePipeline
    let resolveURL: CommentAssetURLResolver
    let onDismiss: () -> Void

    func makeNSView(context: Context) -> NativeCommentImagePreviewRootView {
        let view = NativeCommentImagePreviewRootView(
            imagePipeline: imagePipeline,
            resolveURL: resolveURL
        )
        view.configure(request: request, onDismiss: onDismiss)
        return view
    }

    func updateNSView(
        _ view: NativeCommentImagePreviewRootView,
        context: Context
    ) {
        view.configure(request: request, onDismiss: onDismiss)
    }

    static func dismantleNSView(
        _ view: NativeCommentImagePreviewRootView,
        coordinator: Void
    ) {
        view.tearDown()
    }
}

struct NativeCommentImagePreviewView: View {
    let request: NativeCommentImagePreviewRequest
    let imagePipeline: NativeVideoImagePipeline
    let resolveURL: CommentAssetURLResolver
    let onDismiss: () -> Void

    var body: some View {
        NativeCommentImagePreviewRepresentable(
            request: request,
            imagePipeline: imagePipeline,
            resolveURL: resolveURL,
            onDismiss: onDismiss
        )
        .id(request.id)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
    }
}

struct NativeCommentImagePreviewSelection: Equatable {
    let count: Int
    private(set) var index: Int

    init(count: Int, requestedIndex: Int) {
        self.count = max(0, count)
        index =
            self.count > 0
            ? min(max(0, requestedIndex), self.count - 1)
            : 0
    }

    var canSelectPrevious: Bool { index > 0 }
    var canSelectNext: Bool { index + 1 < count }

    mutating func selectPrevious() -> Bool {
        guard canSelectPrevious else { return false }
        index -= 1
        return true
    }

    mutating func selectNext() -> Bool {
        guard canSelectNext else { return false }
        index += 1
        return true
    }
}

@MainActor
final class NativeCommentImagePreviewRootView: NSView {
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { true }

    private let loader: NativePlaybackCommentPictureLoader
    private let imageView = NSImageView()
    private let closeButton = NSButton()
    private let previousButton = NSButton()
    private let nextButton = NSButton()
    private let counterLabel = NSTextField(labelWithString: "")
    private let progress = NSProgressIndicator()
    private let statusLabel = NSTextField(labelWithString: "")
    private let retryButton = NSButton(
        title: AppStrings.localized("重试"),
        target: nil,
        action: nil
    )
    private var requestID: UUID?
    private var references: [CommentAssetReference] = []
    private var selection = NativeCommentImagePreviewSelection(
        count: 0,
        requestedIndex: 0
    )
    private var currentReference: CommentAssetReference?
    private var loadGeneration: UInt64 = 0
    private var imageTask: Task<Void, Never>?
    private var onDismiss: (() -> Void)?

    init(
        imagePipeline: NativeVideoImagePipeline,
        resolveURL: @escaping CommentAssetURLResolver
    ) {
        loader = NativePlaybackCommentPictureLoader(
            imagePipeline: imagePipeline,
            resolveURL: resolveURL,
            variant: .commentPicturePreview
        )
        super.init(frame: .zero)
        wantsLayer = true
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = 6
        imageView.layer?.masksToBounds = true
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignCenter
        imageView.setAccessibilityElement(true)
        configureButton(
            closeButton,
            symbol: "xmark",
            accessibilityLabel: AppStrings.localized("关闭图片预览")
        )
        configureButton(
            previousButton,
            symbol: "chevron.left",
            accessibilityLabel: AppStrings.localized("上一张图片")
        )
        configureButton(
            nextButton,
            symbol: "chevron.right",
            accessibilityLabel: AppStrings.localized("下一张图片")
        )
        closeButton.target = self
        closeButton.action = #selector(dismissPreview)
        previousButton.target = self
        previousButton.action = #selector(selectPrevious)
        nextButton.target = self
        nextButton.action = #selector(selectNext)
        retryButton.target = self
        retryButton.action = #selector(retry)
        retryButton.bezelStyle = .rounded
        retryButton.setAccessibilityLabel(AppStrings.localized("重新加载评论图片"))
        counterLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        counterLabel.textColor = .white
        counterLabel.alignment = .center
        progress.style = .spinning
        progress.controlSize = .regular
        progress.setAccessibilityLabel(AppStrings.localized("评论图片加载中"))
        statusLabel.font = .preferredFont(forTextStyle: .body)
        statusLabel.textColor = .white
        statusLabel.alignment = .center
        for subview in [
            imageView,
            closeButton,
            previousButton,
            nextButton,
            counterLabel,
            progress,
            statusLabel,
            retryButton,
        ] {
            addSubview(subview)
        }
        closeButton.nextKeyView = previousButton
        previousButton.nextKeyView = nextButton
        nextButton.nextKeyView = retryButton
        retryButton.nextKeyView = closeButton
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilitySubrole(.dialog)
        setAccessibilityLabel(AppStrings.localized("评论图片预览"))
        setAccessibilityModal(true)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func updateLayer() {
        super.updateLayer()
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.82).cgColor
    }

    override func layout() {
        super.layout()
        let horizontalInset = min(96, max(56, bounds.width * 0.08))
        let verticalInset = min(86, max(54, bounds.height * 0.08))
        imageView.frame = NSRect(
            x: horizontalInset,
            y: verticalInset,
            width: max(1, bounds.width - horizontalInset * 2),
            height: max(1, bounds.height - verticalInset * 2)
        )
        let buttonSize: CGFloat = 40
        closeButton.frame = NSRect(
            x: max(12, bounds.maxX - buttonSize - 18),
            y: 18,
            width: buttonSize,
            height: buttonSize
        )
        previousButton.frame = NSRect(
            x: 18,
            y: max(18, bounds.midY - buttonSize / 2),
            width: buttonSize,
            height: buttonSize
        )
        nextButton.frame = NSRect(
            x: max(18, bounds.maxX - buttonSize - 18),
            y: max(18, bounds.midY - buttonSize / 2),
            width: buttonSize,
            height: buttonSize
        )
        counterLabel.frame = NSRect(
            x: max(0, bounds.midX - 60),
            y: max(0, bounds.maxY - 38),
            width: 120,
            height: 20
        )
        progress.frame = NSRect(
            x: bounds.midX - 12,
            y: bounds.midY - 12,
            width: 24,
            height: 24
        )
        statusLabel.frame = NSRect(
            x: max(20, bounds.midX - 150),
            y: bounds.midY - 34,
            width: min(300, max(1, bounds.width - 40)),
            height: 24
        )
        retryButton.frame = NSRect(
            x: bounds.midX - 40,
            y: bounds.midY + 4,
            width: 80,
            height: 30
        )
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        Task { @MainActor [weak self, weak window] in
            await Task.yield()
            guard let self, let window, self.window === window else { return }
            window.makeFirstResponder(self.closeButton)
        }
    }

    override func mouseDown(with event: NSEvent) {
        dismissPreview()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        switch event.keyCode {
        case 53:
            dismissPreview()
            return true
        case 123:
            selectPrevious()
            return true
        case 124:
            selectNext()
            return true
        default:
            return super.performKeyEquivalent(with: event)
        }
    }

    func configure(
        request: NativeCommentImagePreviewRequest,
        onDismiss: @escaping () -> Void
    ) {
        self.onDismiss = onDismiss
        guard requestID != request.id else { return }
        requestID = request.id
        references = request.references
        selection = NativeCommentImagePreviewSelection(
            count: references.count,
            requestedIndex: request.selectedIndex
        )
        updateNavigation()
        loadCurrentImage()
    }

    func tearDown() {
        cancelImageRequest()
        requestID = nil
        references.removeAll(keepingCapacity: false)
        currentReference = nil
        onDismiss = nil
        imageView.image = nil
        imageView.isHidden = true
        progress.stopAnimation(nil)
    }

    private func configureButton(
        _ button: NSButton,
        symbol: String,
        accessibilityLabel: String
    ) {
        button.title = ""
        button.image = NSImage(
            systemSymbolName: symbol,
            accessibilityDescription: nil
        )
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.controlSize = .large
        if #available(macOS 26.0, *) {
            button.bezelStyle = .glass
        } else {
            button.bezelStyle = .circular
        }
        button.setAccessibilityLabel(accessibilityLabel)
    }

    private func updateNavigation() {
        let hasMultipleImages = selection.count > 1
        previousButton.isHidden = !hasMultipleImages
        nextButton.isHidden = !hasMultipleImages
        previousButton.isEnabled = selection.canSelectPrevious
        nextButton.isEnabled = selection.canSelectNext
        counterLabel.stringValue =
            selection.count > 0
            ? "\(selection.index + 1) / \(selection.count)"
            : ""
        imageView.setAccessibilityLabel(
            selection.count > 0
                ? AppStrings.localized("评论图片，第 \(selection.index + 1) 张，共 \(selection.count) 张")
                : AppStrings.localized("评论图片")
        )
    }

    private func loadCurrentImage() {
        cancelImageRequest()
        imageView.image = nil
        imageView.isHidden = true
        statusLabel.isHidden = true
        retryButton.isHidden = true
        guard references.indices.contains(selection.index) else {
            showFailure()
            return
        }
        let reference = references[selection.index]
        currentReference = reference
        if let cached = loader.cachedImage(for: reference) {
            apply(cached, animated: false)
            return
        }
        progress.isHidden = false
        progress.startAnimation(nil)
        let generation = loadGeneration
        imageTask = Task { [weak self] in
            guard let self else { return }
            let result = await self.loader.image(for: reference)
            guard !Task.isCancelled,
                self.loadGeneration == generation,
                self.currentReference == reference
            else { return }
            self.imageTask = nil
            guard let result else {
                self.showFailure()
                return
            }
            self.apply(
                result.image,
                animated: NativePlaybackCommentImageTransition.shouldAnimate(
                    loadOrigin: result.origin
                )
            )
        }
    }

    private func cancelImageRequest() {
        loadGeneration &+= 1
        imageTask?.cancel()
        imageTask = nil
        imageView.layer?.removeAnimation(
            forKey: "native-comment-image-preview.fade"
        )
        imageView.layer?.opacity = 1
        progress.stopAnimation(nil)
        progress.isHidden = true
    }

    private func apply(_ image: CGImage, animated: Bool) {
        progress.stopAnimation(nil)
        progress.isHidden = true
        statusLabel.isHidden = true
        retryButton.isHidden = true
        imageView.image = NSImage(
            cgImage: image,
            size: NSSize(width: image.width, height: image.height)
        )
        imageView.isHidden = false
        guard animated,
            !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
            let imageLayer = imageView.layer
        else { return }
        imageLayer.removeAnimation(forKey: "native-comment-image-preview.fade")
        imageLayer.opacity = 1
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = 0
        animation.toValue = 1
        animation.duration = NativePlaybackCommentImageTransition.duration
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        imageLayer.add(animation, forKey: "native-comment-image-preview.fade")
    }

    private func showFailure() {
        progress.stopAnimation(nil)
        progress.isHidden = true
        imageView.image = nil
        imageView.isHidden = true
        statusLabel.stringValue = AppStrings.localized("图片加载失败")
        statusLabel.isHidden = false
        retryButton.isHidden = false
    }

    @objc private func dismissPreview() {
        onDismiss?()
    }

    @objc private func selectPrevious() {
        guard selection.selectPrevious() else { return }
        updateNavigation()
        loadCurrentImage()
    }

    @objc private func selectNext() {
        guard selection.selectNext() else { return }
        updateNavigation()
        loadCurrentImage()
    }

    @objc private func retry() {
        loadCurrentImage()
    }
}
