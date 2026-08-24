import AppKit
import SwiftUI

struct NativePlaybackDetailUpdatePlan: Equatable {
    let resetsToLeading: Bool

    init(previousIdentity: String?, updatedIdentity: String?) {
        resetsToLeading =
            previousIdentity != nil
            && updatedIdentity != nil
            && previousIdentity != updatedIdentity
    }
}

/// 让 AppKit 独占详情页的纵向滚动，同时把现有 SwiftUI 详情内容作为一个稳定 document 承载。
///
/// 根视图延伸到 toolbar 与侧栏下方；外层仅投影纵向 safe area，水平安全区由 SwiftUI
/// 正文和横向 shelf 分别处理，避免祖先 clip view 重复缩进或裁剪 shelf。
struct NativePlaybackDetailView<Content: View>: NSViewRepresentable {
    let contentIdentity: String?
    private let content: Content

    init(
        contentIdentity: String?,
        @ViewBuilder content: () -> Content
    ) {
        self.contentIdentity = contentIdentity
        self.content = content()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(contentIdentity: contentIdentity, content: content)
    }

    func makeNSView(context: Context) -> NativePlaybackDetailRootView {
        context.coordinator.rootView
    }

    func updateNSView(
        _ view: NativePlaybackDetailRootView,
        context: Context
    ) {
        context.coordinator.update(
            contentIdentity: contentIdentity,
            content: content
        )
    }

    static func dismantleNSView(
        _ view: NativePlaybackDetailRootView,
        coordinator: Coordinator
    ) {
        coordinator.reset()
    }

    @MainActor
    final class Coordinator {
        let rootView: NativePlaybackDetailRootView
        private let contentSizeRelay: NativePlaybackDetailContentSizeRelay
        private let hostingController:
            NSHostingController<NativePlaybackDetailMeasuredContent<Content>>
        private var contentIdentity: String?
        private var operationGeneration: UInt64 = 0
        private var isReset = false

        init(contentIdentity: String?, content: Content) {
            self.contentIdentity = contentIdentity
            let contentSizeRelay = NativePlaybackDetailContentSizeRelay()
            self.contentSizeRelay = contentSizeRelay
            let contentGeneration = contentSizeRelay.beginContent()
            hostingController = NSHostingController(
                rootView: NativePlaybackDetailMeasuredContent(
                    content: content,
                    relay: contentSizeRelay,
                    generation: contentGeneration
                )
            )
            hostingController.sizingOptions = []
            rootView = NativePlaybackDetailRootView(
                hostingController: hostingController
            )
            contentSizeRelay.setHandler { [weak rootView] size in
                rootView?.hostedContentSizeDidChange(size)
            }
        }

        func update(contentIdentity: String?, content: Content) {
            guard !isReset else { return }
            let plan = NativePlaybackDetailUpdatePlan(
                previousIdentity: self.contentIdentity,
                updatedIdentity: contentIdentity
            )
            self.contentIdentity = contentIdentity
            let contentGeneration = contentSizeRelay.beginContent()
            hostingController.rootView = NativePlaybackDetailMeasuredContent(
                content: content,
                relay: contentSizeRelay,
                generation: contentGeneration
            )
            rootView.invalidateDocumentLayout()
            guard plan.resetsToLeading else { return }
            operationGeneration &+= 1
            let generation = operationGeneration
            rootView.scrollToLeading()
            DispatchQueue.main.async { [weak self] in
                guard
                    let self,
                    !self.isReset,
                    self.operationGeneration == generation
                else { return }
                self.rootView.scrollToLeading()
            }
        }

        func reset() {
            guard !isReset else { return }
            isReset = true
            operationGeneration &+= 1
            contentSizeRelay.reset()
            rootView.reset()
        }
    }
}

@MainActor
final class NativePlaybackDetailContentSizeRelay {
    private var handler: ((CGSize) -> Void)?
    private var contentGeneration: UInt64 = 0

    func beginContent() -> UInt64 {
        contentGeneration &+= 1
        return contentGeneration
    }

    func setHandler(_ handler: @escaping (CGSize) -> Void) {
        self.handler = handler
    }

    func report(_ size: CGSize, generation: UInt64) {
        guard generation == contentGeneration else { return }
        handler?(size)
    }

    func reset() {
        contentGeneration &+= 1
        handler = nil
    }
}

struct NativePlaybackDetailMeasuredContent<Content: View>: View {
    let content: Content
    let relay: NativePlaybackDetailContentSizeRelay
    let generation: UInt64

    var body: some View {
        content
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .top)
            .onGeometryChange(for: CGSize.self) { proxy in
                proxy.size
            } action: { size in
                relay.report(size, generation: generation)
            }
    }
}

@MainActor
final class NativePlaybackDetailRootView: NSView {
    let scrollView = NativePlaybackDetailScrollView()
    private let documentView = NativePlaybackDetailDocumentView()
    private weak var hostedContentView: NSView?
    private var contentHeightForWidth: ((CGFloat) -> CGFloat)?
    private var documentHeightConstraint: NSLayoutConstraint?
    private var lastMeasuredViewportWidth: CGFloat?
    private var needsDocumentMeasurement = true
    private var layoutGeneration: UInt64 = 0
    private var isReset = false

    init<Content: View>(hostingController: NSHostingController<Content>) {
        let hostingView = hostingController.view
        hostedContentView = hostingView
        contentHeightForWidth = { [weak hostingController] width in
            guard let hostingController else { return 0 }
            return hostingController.sizeThatFits(
                in: CGSize(
                    width: width,
                    height: CGFloat.greatestFiniteMagnitude
                )
            ).height
        }
        super.init(frame: .zero)
        wantsLayer = true

        scrollView.drawsBackground = true
        scrollView.backgroundColor = .windowBackgroundColor
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.hasHorizontalScroller = false
        scrollView.usesPredominantAxisScrolling = true
        scrollView.verticalScrollElasticity = .automatic
        scrollView.horizontalScrollElasticity = .none
        scrollView.allowsMagnification = false
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.onContentInsetsChange = { [weak self] oldInsets, newInsets in
            self?.contentInsetsDidChange(from: oldInsets, to: newInsets)
        }
        scrollView.documentView = documentView
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)

        documentView.translatesAutoresizingMaskIntoConstraints = false
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(hostingView)
        let documentHeightConstraint = documentView.heightAnchor.constraint(
            equalToConstant: 0
        )
        self.documentHeightConstraint = documentHeightConstraint
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            documentView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            documentView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            documentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            documentHeightConstraint,
            hostingView.leadingAnchor.constraint(equalTo: documentView.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: documentView.trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: documentView.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: documentView.bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        projectSafeAreaInsets()
        let viewportWidth = scrollView.contentView.bounds.width
        if lastMeasuredViewportWidth.map({ abs($0 - viewportWidth) > 0.5 }) ?? true {
            needsDocumentMeasurement = true
        }
        updateDocumentHeightIfNeeded()
    }

    private func projectSafeAreaInsets() {
        let projectedScrollInsets = NSEdgeInsets(
            top: safeAreaInsets.top,
            left: 0,
            bottom: safeAreaInsets.bottom,
            right: 0
        )
        if abs(scrollView.contentInsets.top - projectedScrollInsets.top) > 0.5
            || abs(scrollView.contentInsets.bottom - projectedScrollInsets.bottom) > 0.5
        {
            scrollView.contentInsets = projectedScrollInsets
        }
        if abs(scrollView.contentView.bounds.origin.x) > 0.5 {
            scrollView.contentView.scroll(
                to: NSPoint(
                    x: 0,
                    y: scrollView.contentView.bounds.origin.y
                )
            )
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }

    func invalidateDocumentLayout() {
        guard !isReset else { return }
        layoutGeneration &+= 1
        needsDocumentMeasurement = true
        let generation = layoutGeneration
        DispatchQueue.main.async { [weak self] in
            guard
                let self,
                !self.isReset,
                self.layoutGeneration == generation
            else { return }
            self.documentView.needsLayout = true
            self.hostedContentView?.needsLayout = true
            self.needsLayout = true
        }
    }

    private func updateDocumentHeightIfNeeded() {
        guard
            !isReset,
            needsDocumentMeasurement,
            let contentHeightForWidth
        else { return }
        let viewportSize = scrollView.contentView.bounds.size
        guard viewportSize.width > 0 else { return }
        needsDocumentMeasurement = false
        lastMeasuredViewportWidth = viewportSize.width
        let measuredHeight = contentHeightForWidth(viewportSize.width)
        applyDocumentHeight(measuredHeight, viewportHeight: viewportSize.height)
    }

    func hostedContentSizeDidChange(_ size: CGSize) {
        guard !isReset else { return }
        let viewportSize = scrollView.contentView.bounds.size
        guard
            viewportSize.width > 0,
            abs(size.width - viewportSize.width) <= 1
        else { return }
        lastMeasuredViewportWidth = viewportSize.width
        needsDocumentMeasurement = false
        applyDocumentHeight(size.height, viewportHeight: viewportSize.height)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private func applyDocumentHeight(
        _ measuredHeight: CGFloat,
        viewportHeight: CGFloat
    ) {
        guard let documentHeightConstraint else { return }
        let resolvedHeight = ceil(max(measuredHeight, viewportHeight))
        guard abs(documentHeightConstraint.constant - resolvedHeight) > 0.5 else { return }
        documentHeightConstraint.constant = resolvedHeight
        documentView.needsLayout = true
        hostedContentView?.needsLayout = true
    }

    func scrollToLeading() {
        guard !isReset else { return }
        let leadingOffset = NativeVideoScrollCoordinateSpace.physicalOffsetY(
            logicalOffsetY: 0,
            topInset: scrollView.contentInsets.top
        )
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: leadingOffset))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private func contentInsetsDidChange(
        from oldInsets: NSEdgeInsets,
        to newInsets: NSEdgeInsets
    ) {
        guard !isReset else { return }
        let logicalOffset = NativeVideoScrollCoordinateSpace.logicalOffsetY(
            physicalOffsetY: scrollView.contentView.bounds.origin.y,
            topInset: oldInsets.top
        )
        let physicalOffset = NativeVideoScrollCoordinateSpace.physicalOffsetY(
            logicalOffsetY: logicalOffset,
            topInset: newInsets.top
        )
        scrollView.contentView.scroll(
            to: NSPoint(
                x: 0,
                y: physicalOffset
            )
        )
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    func reset() {
        guard !isReset else { return }
        isReset = true
        layoutGeneration &+= 1
        if let responder = window?.firstResponder as? NSView,
            responder.isDescendant(of: self)
        {
            window?.makeFirstResponder(nil)
        }
        hostedContentView?.removeFromSuperview()
        hostedContentView = nil
        contentHeightForWidth = nil
        documentHeightConstraint = nil
        scrollView.onContentInsetsChange = nil
        scrollView.documentView = nil
    }
}

@MainActor
final class NativePlaybackDetailScrollView: NSScrollView {
    var onContentInsetsChange: ((NSEdgeInsets, NSEdgeInsets) -> Void)?
    private var lastContentInsets = NSEdgeInsetsZero

    override func layout() {
        super.layout()
        let changed =
            abs(contentInsets.top - lastContentInsets.top) > 0.5
            || abs(contentInsets.left - lastContentInsets.left) > 0.5
            || abs(contentInsets.bottom - lastContentInsets.bottom) > 0.5
            || abs(contentInsets.right - lastContentInsets.right) > 0.5
        guard changed else { return }
        let oldInsets = lastContentInsets
        lastContentInsets = contentInsets
        onContentInsetsChange?(oldInsets, contentInsets)
    }

    override func wantsForwardedScrollEvents(for axis: NSEvent.GestureAxis) -> Bool {
        axis == .vertical
    }

    override func scrollWheel(with event: NSEvent) {
        let horizontalMagnitude = abs(event.scrollingDeltaX)
        let verticalMagnitude = abs(event.scrollingDeltaY)
        guard horizontalMagnitude <= verticalMagnitude else { return }
        super.scrollWheel(with: event)
    }
}

@MainActor
private final class NativePlaybackDetailDocumentView: NSView {
    override var isFlipped: Bool { true }
}
