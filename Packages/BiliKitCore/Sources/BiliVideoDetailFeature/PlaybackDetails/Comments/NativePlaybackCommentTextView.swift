import AppKit
import BiliModels

/// 评论正文：可选择、不可编辑的 `NSTextView`，显示渲染器给出的富文本，点击链接（含链接前的图标附件）交给
/// `onOpenLink`。
///
/// 拥有表情与链接图标的加载 Task 与它的代次 `renderGeneration`：每次设置内容或释放时递增并取消在途加载；加载结果
/// 只在代次与渲染作用域都仍相同时写回附件。有附件加载失败时重新渲染（失败的改回原文）并通知行高变化。
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
        NativePlaybackTextLinks.configure(self)
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
        selectedRanges = NativePlaybackDetailsReadOnlyTextView.clampedSelections(
            previousSelections,
            textLength: rendered.attributedString.length
        )
        setAccessibilityLabel(rendered.accessibilityText)
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
                    VideoDetailImage?
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
                        VideoDetailImage?
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
        guard let target = NativePlaybackTextLinks.target(for: link, in: linkTargets) else {
            return true
        }
        onOpenLink?(target)
        return true
    }

    /// 链接前的图标是图片附件，点它时系统走附件点击而不是链接点击；读出同一个链接值，与点标题走同一条路径。
    func textView(
        _ textView: NSTextView,
        clickedOn cell: any NSTextAttachmentCellProtocol,
        in cellFrame: NSRect,
        at charIndex: Int
    ) {
        guard let textStorage, charIndex >= 0, charIndex < textStorage.length,
            let link = textStorage.attribute(.link, at: charIndex, effectiveRange: nil)
        else { return }
        _ = self.textView(textView, clickedOnLink: link, at: charIndex)
    }
}
