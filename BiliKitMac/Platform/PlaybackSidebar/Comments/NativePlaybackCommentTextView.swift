import AppKit
import BiliModels

@MainActor
final class NativePlaybackCommentTextView: NSTextView, NSTextViewDelegate {
    var onOpenLink: ((CommentLinkTarget) -> Void)?
    private var content: CommentContent?
    private var renderer: NativePlaybackCommentTextRenderer?
    private var scope: NativePlaybackCommentTextScope?
    private var onLayoutChange: (() -> Void)?
    private var renderGeneration: UInt64 = 0
    private var renderTask: Task<Void, Never>?
    private var linkTargets: [CommentLinkTarget] = []

    init() {
        let storage = NSTextStorage()
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: .zero)
        storage.addLayoutManager(manager)
        manager.addTextContainer(container)
        container.lineFragmentPadding = 0
        container.widthTracksTextView = true
        container.heightTracksTextView = false
        super.init(frame: .zero, textContainer: container)
        delegate = self
        drawsBackground = false
        isEditable = false
        isSelectable = true
        isRichText = true
        isHorizontallyResizable = false
        isVerticallyResizable = false
        textContainerInset = .zero
        linkTextAttributes = [
            .foregroundColor: NSColor.linkColor
        ]
        setAccessibilityRole(.staticText)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func layout() {
        textContainer?.containerSize = NSSize(
            width: max(1, bounds.width),
            height: .greatestFiniteMagnitude
        )
        super.layout()
    }

    func setContent(
        _ content: CommentContent,
        renderer: NativePlaybackCommentTextRenderer,
        scope: NativePlaybackCommentTextScope,
        onLayoutChange: @escaping () -> Void
    ) {
        renderGeneration &+= 1
        renderTask?.cancel()
        self.content = content
        self.renderer = renderer
        self.scope = scope
        self.onLayoutChange = onLayoutChange
        applyContent()
    }

    private func applyContent() {
        guard let content, let renderer, let scope else { return }
        let previousSelections = selectedRanges
        let rendered = renderer.render(content, scope: scope)
        textStorage?.setAttributedString(rendered.attributedString)
        linkTargets = rendered.linkTargets
        selectedRanges = NativePlaybackSidebarReadOnlyTextView.clampedSelections(
            previousSelections,
            textLength: rendered.attributedString.length
        )
        setAccessibilityLabel(content.message)
        scheduleLoads(rendered)
    }

    private func scheduleLoads(
        _ rendered: NativePlaybackCommentTextRenderer.RenderedText
    ) {
        renderTask?.cancel()
        guard let renderer, let scheduledScope = scope,
            !rendered.pendingAssets.isEmpty
        else {
            renderTask = nil
            return
        }
        let generation = renderGeneration
        renderTask = Task { [weak self] in
            let results = await withTaskGroup(
                of: (
                    NativePlaybackCommentTextRenderer.PendingAsset,
                    NativeVideoImageLoadResult?
                ).self
            ) { group in
                for pending in rendered.pendingAssets {
                    group.addTask {
                        (pending, await renderer.load(pending))
                    }
                }
                var values:
                    [(
                        NativePlaybackCommentTextRenderer.PendingAsset,
                        NativeVideoImageLoadResult?
                    )] = []
                for await value in group { values.append(value) }
                return values
            }
            guard !Task.isCancelled,
                let self,
                generation == self.renderGeneration,
                self.scope == scheduledScope
            else { return }

            var hasFailure = false
            for (pending, result) in results {
                if let result {
                    renderer.apply(
                        result,
                        to: rendered.attachments[pending.reference] ?? []
                    )
                } else if renderer.markUnavailable(
                    pending.reference,
                    in: scheduledScope
                ) {
                    hasFailure = true
                }
            }
            if hasFailure {
                applyContent()
                onLayoutChange?()
            } else {
                layoutManager?.invalidateDisplay(
                    forCharacterRange: NSRange(
                        location: 0,
                        length: textStorage?.length ?? 0
                    )
                )
                needsDisplay = true
            }
        }
    }

    func releaseTextStorage() {
        renderGeneration &+= 1
        renderTask?.cancel()
        renderTask = nil
        content = nil
        renderer = nil
        scope = nil
        onLayoutChange = nil
        linkTargets.removeAll(keepingCapacity: false)
        textStorage?.setAttributedString(NSAttributedString(string: ""))
    }

    func reset() {
        onOpenLink = nil
        releaseTextStorage()
    }

    func textView(
        _ textView: NSTextView,
        clickedOnLink link: Any,
        at charIndex: Int
    ) -> Bool {
        guard let value = link as? String,
            value.hasPrefix("bilikit-comment-link-"),
            let index = Int(value.dropFirst("bilikit-comment-link-".count)),
            linkTargets.indices.contains(index)
        else { return true }
        onOpenLink?(linkTargets[index])
        return true
    }
}
