import AppKit
import BiliApplication
import BiliUI

/// 楼中楼展开后底部的页码条：`‹ 1 … 5 6 [7] 8 9 … N ›`，点数字直接翻到那一页，箭头翻到前后页。
///
/// 排布取 BiliUI 的 `PageNumberSlots`，与来源列表的悬浮页码条一致；不做悬浮玻璃、悬停展开与输入页码跳转（详情区里
/// 常驻显示、一行放得下）。每次配置按页码重建子视图；当前页与总页数归 `PlaybackCommentReplyState`，翻页意图经
/// `onShowPage` 交回控制器。属于播放详情区的原生 item，用 AppKit 的理由见 ARCHITECTURE「原生 AppKit 集合视图」的
/// 播放详情区一条。
@MainActor
final class NativePlaybackCommentReplyPager: NSView {
    /// 页码与箭头的最小边长：比详情区正文略小，十一格加间距在最窄的详情区里也放得下一行。
    static let itemSize: CGFloat = 24
    private static let itemSpacing: CGFloat = 2
    /// 数字两侧的留白：多位页码不贴边，当前页的胶囊底也不显得局促。
    fileprivate static let numberPadding: CGFloat = 5

    nonisolated override var isFlipped: Bool { true }
    private var slotViews: [NSView] = []
    private var onShowPage: ((Int) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// 页码条的总页数：按楼中楼总数（还没读到时用根评论给的回复数）推算。
    ///
    /// 已知是末页时就是当前页；否则至少比当前页多一页，回复总数在翻页期间增长时下一页箭头不会被页数夹死。
    static func pageCount(for state: PlaybackCommentReplyState, replyCount: Int) -> Int {
        let counted = CommentPresentationFormatting.pageCount(
            totalCount: state.totalCount > 0 ? state.totalCount : replyCount,
            pageSize: CommentUseCase.replyPageSize
        )
        return state.isEnd ? state.pageNumber : max(counted, state.pageNumber + 1)
    }

    /// `onShowPage` 只收到 1…`pageCount` 之间、不等于当前页的页码。
    func configure(
        currentPage: Int,
        pageCount: Int,
        onShowPage: @escaping (Int) -> Void
    ) {
        reset()
        self.onShowPage = onShowPage
        let pageCount = max(1, pageCount)
        let currentPage = min(max(1, currentPage), pageCount)
        var views: [NSView] = [
            arrow(
                "chevron.left",
                label: VideoDetailFeatureStrings.localized("上一页"),
                target: currentPage - 1,
                pageCount: pageCount
            )
        ]
        for slot in PageNumberSlots.slots(currentPage: currentPage, pageCount: pageCount) {
            switch slot {
            case .page(let page) where page == currentPage:
                views.append(CurrentPageView(page: page, pageCount: pageCount))
            case .page(let page):
                views.append(pageButton(page, pageCount: pageCount))
            case .gap:
                let gap = PagerLabel(text: "…")
                gap.textColor = .secondaryLabelColor
                views.append(gap)
            }
        }
        views.append(
            arrow(
                "chevron.right",
                label: VideoDetailFeatureStrings.localized("下一页"),
                target: currentPage + 1,
                pageCount: pageCount
            )
        )
        for view in views { addSubview(view) }
        slotViews = views
        needsLayout = true
    }

    func reset() {
        for view in slotViews { view.removeFromSuperview() }
        slotViews.removeAll(keepingCapacity: true)
        onShowPage = nil
    }

    /// 整行水平居中；放不下时从左边排起，超出部分被面板裁掉。
    override func layout() {
        super.layout()
        let widths = slotViews.map { max(Self.itemSize, ceil($0.fittingSize.width)) }
        let total =
            widths.reduce(0, +) + Self.itemSpacing * CGFloat(max(0, widths.count - 1))
        var x = max(0, (bounds.width - total) / 2)
        let y = max(0, (bounds.height - Self.itemSize) / 2)
        for (view, width) in zip(slotViews, widths) {
            view.frame = NSRect(x: x, y: y, width: width, height: Self.itemSize)
            x += width + Self.itemSpacing
        }
    }

    private func arrow(
        _ symbol: String,
        label: String,
        target: Int,
        pageCount: Int
    ) -> NSButton {
        let button = PageButton(page: target) { [weak self] in self?.onShowPage?($0) }
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        button.imagePosition = .imageOnly
        button.toolTip = label
        button.setAccessibilityLabel(label)
        button.isEnabled = target >= 1 && target <= pageCount
        return button
    }

    private func pageButton(_ page: Int, pageCount: Int) -> NSButton {
        let button = PageButton(page: page) { [weak self] in self?.onShowPage?($0) }
        button.title = "\(page)"
        button.font = Self.numberFont
        button.setAccessibilityLabel(
            VideoDetailFeatureStrings.localized("第 \(page) 页，共 \(pageCount) 页")
        )
        return button
    }

    fileprivate static var numberFont: NSFont {
        .monospacedDigitSystemFont(
            ofSize: NSFont.preferredFont(forTextStyle: .callout).pointSize,
            weight: .regular
        )
    }
}

/// 页码条里的一格按钮：无边框，点按时把自己的页码交给页码条。
@MainActor
private final class PageButton: NSButton {
    private let page: Int
    private let onPress: (Int) -> Void

    init(page: Int, onPress: @escaping (Int) -> Void) {
        self.page = page
        self.onPress = onPress
        super.init(frame: .zero)
        isBordered = false
        bezelStyle = .regularSquare
        controlSize = .small
        contentTintColor = .labelColor
        target = self
        action = #selector(press)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var fittingSize: NSSize {
        let size = super.fittingSize
        return NSSize(
            width: size.width + 2 * NativePlaybackCommentReplyPager.numberPadding,
            height: size.height
        )
    }

    @objc private func press() { onPress(page) }
}

/// 页码条里的文字（省略号与当前页数字）：与按钮同一字体，并在给定高度里垂直居中。
///
/// `NSTextField` 标签的文字贴着顶边绘制，直接放进按钮同高的格子会比按钮里的数字偏上。
@MainActor
private final class PagerLabel: NSView {
    private let label: NSTextField

    var textColor: NSColor? {
        get { label.textColor }
        set { label.textColor = newValue }
    }

    init(text: String) {
        label = NSTextField(labelWithString: text)
        super.init(frame: .zero)
        label.font = NativePlaybackCommentReplyPager.numberFont
        label.alignment = .center
        label.setAccessibilityElement(false)
        addSubview(label)
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var fittingSize: NSSize {
        let size = label.fittingSize
        return NSSize(
            width: size.width + 2 * NativePlaybackCommentReplyPager.numberPadding,
            height: size.height
        )
    }

    override func layout() {
        super.layout()
        let height = ceil(label.fittingSize.height)
        label.frame = NSRect(
            x: 0,
            y: (bounds.height - height) / 2,
            width: bounds.width,
            height: height
        )
    }
}

/// 当前页：强调色胶囊底上的页码，不可点按；读屏读作“当前第 n 页，共 N 页”（静态文本读不出“已选”）。
@MainActor
private final class CurrentPageView: NSView {
    private let label: PagerLabel

    init(page: Int, pageCount: Int) {
        label = PagerLabel(text: "\(page)")
        super.init(frame: .zero)
        wantsLayer = true
        addSubview(label)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(
            VideoDetailFeatureStrings.localized("当前第 \(page) 页，共 \(pageCount) 页")
        )
        setAccessibilitySelected(true)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var wantsUpdateLayer: Bool { true }

    override var fittingSize: NSSize { label.fittingSize }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.25).cgColor
        layer?.cornerRadius = bounds.height / 2
    }

    override func layout() {
        super.layout()
        label.frame = bounds
        needsDisplay = true
    }
}
