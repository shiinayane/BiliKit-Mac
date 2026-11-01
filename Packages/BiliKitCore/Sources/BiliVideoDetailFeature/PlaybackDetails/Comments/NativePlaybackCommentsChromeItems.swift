import AppKit
import BiliApplication
import BiliModels

/// 评论区标题条目：标题、评论总数与热门／最新排序；排序变化经回调交给 ViewModel。
@MainActor
final class NativePlaybackCommentsHeaderItem: NSCollectionViewItem {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier(
        "NativePlaybackCommentsHeaderItem"
    )
    private let contentView = NativePlaybackCommentsHeaderView()

    override func loadView() { view = contentView }

    func configure(
        presentation: NativePlaybackCommentsPresentation,
        onSelectSort: @escaping (CommentSort) -> Void
    ) {
        representedObject = presentation.subject
        contentView.configure(
            presentation: presentation,
            onSelectSort: onSelectSort
        )
    }

    override func prepareForReuse() {
        contentView.reset()
        representedObject = nil
        super.prepareForReuse()
    }
}

/// 评论区标题的内容视图：持有排序回调，排序不可用时禁用分段控件。
@MainActor
private final class NativePlaybackCommentsHeaderView: NSView {
    override var isFlipped: Bool { true }
    private let titleLabel = NSTextField(labelWithString: VideoDetailFeatureStrings.localized("评论"))
    private let countLabel = NSTextField(labelWithString: "")
    private let sortControl = NSSegmentedControl(
        labels: [
            VideoDetailFeatureStrings.localized("热门"), VideoDetailFeatureStrings.localized("最新")
        ],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private var onSelectSort: ((CommentSort) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        titleLabel.font = .systemFont(
            ofSize: NSFont.preferredFont(forTextStyle: .headline).pointSize,
            weight: .semibold
        )
        countLabel.font = .monospacedDigitSystemFont(
            ofSize: NSFont.preferredFont(forTextStyle: .callout).pointSize,
            weight: .regular
        )
        countLabel.textColor = .secondaryLabelColor
        sortControl.controlSize = .regular
        sortControl.target = self
        sortControl.action = #selector(selectSort)
        sortControl.setAccessibilityLabel(VideoDetailFeatureStrings.localized("评论排序"))
        addSubview(titleLabel)
        addSubview(countLabel)
        addSubview(sortControl)
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func configure(
        presentation: NativePlaybackCommentsPresentation,
        onSelectSort: @escaping (CommentSort) -> Void
    ) {
        self.onSelectSort = onSelectSort
        sortControl.selectedSegment = presentation.sort == .hot ? 0 : 1
        sortControl.isEnabled = presentation.sortIsEnabled
        switch presentation.rootState {
        case .loaded, .empty:
            let count = CommentPresentationFormatting.compactCount(
                presentation.totalCount
            )
            countLabel.stringValue = count
            countLabel.setAccessibilityLabel(VideoDetailFeatureStrings.localized("共 \(count) 条评论"))
            countLabel.setAccessibilityElement(true)
        case .idle, .loading, .failed:
            countLabel.stringValue = ""
            countLabel.setAccessibilityLabel(nil)
            countLabel.setAccessibilityElement(false)
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let titleWidth = ceil(titleLabel.intrinsicContentSize.width) + 2
        let sortWidth: CGFloat = 128
        let sortX = max(0, bounds.width - sortWidth)
        titleLabel.frame = NSRect(
            x: 0,
            y: 10,
            width: titleWidth,
            height: 22
        )
        let countWidth = min(
            ceil(countLabel.intrinsicContentSize.width) + 4,
            max(0, sortX - titleWidth - 10)
        )
        countLabel.frame = NSRect(
            x: titleWidth + 6,
            y: 11,
            width: countWidth,
            height: 20
        )
        sortControl.frame = NSRect(
            x: sortX,
            y: 6,
            width: sortWidth,
            height: 30
        )
    }

    func reset() {
        onSelectSort = nil
        countLabel.stringValue = ""
        countLabel.setAccessibilityLabel(nil)
        countLabel.setAccessibilityElement(false)
        sortControl.isEnabled = false
    }

    @objc private func selectSort() {
        onSelectSort?(sortControl.selectedSegment == 0 ? .hot : .latest)
    }
}

/// 评论区没有列表时的状态条目：加载中、暂无评论、已关闭、缺少评论标识或失败（可重试时带重试按钮）。
@MainActor
final class NativePlaybackCommentsStateItem: NSCollectionViewItem {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier(
        "NativePlaybackCommentsStateItem"
    )
    private let contentView = NativePlaybackCommentsStateView()

    override func loadView() { view = contentView }

    func configure(
        kind: NativePlaybackCommentsStateKind,
        onRetry: @escaping () -> Void
    ) {
        representedObject = kind
        contentView.configure(kind: kind, onRetry: onRetry)
    }

    override func prepareForReuse() {
        contentView.reset()
        representedObject = nil
        super.prepareForReuse()
    }
}

/// 状态条目的内容视图：按状态切换文字与重试按钮，加载中在行内居中转圈，并给出与显示一致的读屏标签。
///
/// 加载不画骨架：评论形态不一，占位行会误导条数与长度，与 UP 主空间一致用转圈。转圈只在加载中转动，
/// 其他状态与 `reset()`（条目复用）停止并隐藏。
@MainActor
private final class NativePlaybackCommentsStateView: NSView {
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    private let spinner = NSProgressIndicator.commentsLoadingSpinner(controlSize: .large)
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(wrappingLabelWithString: "")
    private let retryButton = NSButton(
        title: VideoDetailFeatureStrings.localized("重试"),
        target: nil,
        action: nil
    )
    private var kind: NativePlaybackCommentsStateKind = .idle
    private var onRetry: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        titleLabel.font = .systemFont(
            ofSize: NSFont.preferredFont(forTextStyle: .body).pointSize,
            weight: .semibold
        )
        titleLabel.alignment = .center
        detailLabel.font = .preferredFont(forTextStyle: .callout)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.alignment = .center
        retryButton.bezelStyle = .rounded
        retryButton.target = self
        retryButton.action = #selector(retry)
        addSubview(spinner)
        addSubview(titleLabel)
        addSubview(detailLabel)
        addSubview(retryButton)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func configure(
        kind: NativePlaybackCommentsStateKind,
        onRetry: @escaping () -> Void
    ) {
        self.kind = kind
        self.onRetry = onRetry
        retryButton.isHidden = true
        switch kind {
        case .idle:
            titleLabel.stringValue = VideoDetailFeatureStrings.localized("评论暂不可用")
            detailLabel.stringValue = VideoDetailFeatureStrings.localized("当前视频缺少可用的评论标识。")
            setAccessibilityLabel(VideoDetailFeatureStrings.localized("评论暂不可用，当前视频缺少可用的评论标识"))
        case .loading:
            titleLabel.stringValue = ""
            detailLabel.stringValue = ""
            setAccessibilityLabel(VideoDetailFeatureStrings.localized("评论加载中"))
        case .empty:
            titleLabel.stringValue = VideoDetailFeatureStrings.localized("暂无评论")
            detailLabel.stringValue = VideoDetailFeatureStrings.localized("这个视频还没有公开评论。")
            setAccessibilityLabel(VideoDetailFeatureStrings.localized("暂无评论，这个视频还没有公开评论"))
        case .closed:
            titleLabel.stringValue = VideoDetailFeatureStrings.localized("评论区已关闭")
            detailLabel.stringValue = VideoDetailFeatureStrings.localized("这个视频的评论区已关闭。")
            setAccessibilityLabel(VideoDetailFeatureStrings.localized("评论区已关闭"))
        case .failed(let error):
            let title =
                error.isRetryable
                ? VideoDetailFeatureStrings.localized("评论加载失败") : error.nonRetryableDescription
            titleLabel.stringValue = title
            detailLabel.stringValue = ""
            retryButton.isHidden = !error.isRetryable
            setAccessibilityLabel(title)
        }
        spinner.setCommentsLoading(kind == .loading)
        setAccessibilityElement(true)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        spinner.frame = spinner.centeredFrame(in: bounds)
        guard kind != .loading else { return }
        let contentWidth = max(120, bounds.width - 24)
        if case .failed = kind {
            titleLabel.alignment = .left
            titleLabel.frame = NSRect(x: 0, y: 13, width: contentWidth - 84, height: 22)
            retryButton.frame = NSRect(
                x: max(0, bounds.width - 76),
                y: 8,
                width: 76,
                height: 30
            )
            detailLabel.frame = .zero
            return
        }
        titleLabel.alignment = .center
        titleLabel.frame = NSRect(x: 12, y: 30, width: contentWidth, height: 22)
        detailLabel.frame = NSRect(x: 12, y: 59, width: contentWidth, height: 38)
    }

    func reset() {
        onRetry = nil
        titleLabel.stringValue = ""
        detailLabel.stringValue = ""
        retryButton.isHidden = true
        spinner.setCommentsLoading(false)
    }

    @objc private func retry() { onRetry?() }
}

/// 评论列表的页脚条目：加载更多、加载中、失败或停止（可重试时带按钮）与已显示全部；它进入视野时控制器判断
/// 是否请求下一页。
@MainActor
final class NativePlaybackCommentsFooterItem: NSCollectionViewItem {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier(
        "NativePlaybackCommentsFooterItem"
    )
    private let contentView = NativePlaybackCommentsFooterView()

    override func loadView() { view = contentView }

    func configure(
        footer: NativePlaybackCommentsFooter,
        onRetry: @escaping () -> Void,
        onLoadMore: @escaping () -> Void
    ) {
        representedObject = footer
        contentView.configure(
            footer: footer,
            onRetry: onRetry,
            onLoadMore: onLoadMore
        )
    }

    override func prepareForReuse() {
        contentView.reset()
        representedObject = nil
        super.prepareForReuse()
    }
}

extension NativePlaybackCommentsFooter {
    /// 失败与停止共用左侧说明、右侧按钮的一行布局；按钮是否显示由各自的配置决定。
    fileprivate var isInlineStatus: Bool {
        switch self {
        case .failed, .stopped: true
        case .loading, .end, .loadMore: false
        }
    }
}

/// 页脚的内容视图：持有重试与加载更多回调，按页脚状态切换文字与按钮，追加加载中在行内居中转圈。
///
/// 转圈只在加载中转动，其他状态与 `reset()`（条目复用）停止并隐藏；读屏只读页脚自己的“后续评论加载中”。
@MainActor
private final class NativePlaybackCommentsFooterView: NSView {
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    private let spinner = NSProgressIndicator.commentsLoadingSpinner(controlSize: .small)
    private let label = NSTextField(labelWithString: "")
    private let actionButton = NSButton(
        title: VideoDetailFeatureStrings.localized("重试"),
        target: nil,
        action: nil
    )
    private var footer: NativePlaybackCommentsFooter = .loadMore
    private var onRetry: (() -> Void)?
    private var onLoadMore: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        label.font = .preferredFont(forTextStyle: .caption1)
        label.textColor = .tertiaryLabelColor
        label.alignment = .center
        actionButton.bezelStyle = .rounded
        actionButton.target = self
        actionButton.action = #selector(performAction)
        addSubview(spinner)
        addSubview(label)
        addSubview(actionButton)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func configure(
        footer: NativePlaybackCommentsFooter,
        onRetry: @escaping () -> Void,
        onLoadMore: @escaping () -> Void
    ) {
        self.footer = footer
        self.onRetry = onRetry
        self.onLoadMore = onLoadMore
        actionButton.isHidden = true
        switch footer {
        case .loading:
            label.stringValue = ""
            setAccessibilityElement(true)
            setAccessibilityRole(.staticText)
            setAccessibilityLabel(VideoDetailFeatureStrings.localized("后续评论加载中"))
            setAccessibilityValue(nil)
        case .failed(let error):
            label.stringValue =
                error.isRetryable
                ? VideoDetailFeatureStrings.localized("后续评论加载失败") : error.nonRetryableDescription
            actionButton.title = VideoDetailFeatureStrings.localized("重试")
            actionButton.isHidden = !error.isRetryable
            setAccessibilityElement(false)
            setAccessibilityValue(nil)
        case .stopped:
            label.stringValue = VideoDetailFeatureStrings.localized("后续评论暂不可用")
            actionButton.title = VideoDetailFeatureStrings.localized("重试")
            actionButton.isHidden = false
            setAccessibilityElement(false)
            setAccessibilityValue(nil)
        case .end(let memoryLimited):
            label.stringValue =
                memoryLimited
                ? VideoDetailFeatureStrings.localized("已显示本次上限 1,000 条评论")
                : VideoDetailFeatureStrings.localized("已显示全部评论")
            setAccessibilityElement(false)
            setAccessibilityValue(nil)
        case .loadMore:
            label.stringValue = ""
            actionButton.title = VideoDetailFeatureStrings.localized("加载更多")
            actionButton.isHidden = false
            setAccessibilityElement(false)
            setAccessibilityValue(nil)
        }
        spinner.setCommentsLoading(footer == .loading)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        spinner.frame = spinner.centeredFrame(in: bounds)
        if footer.isInlineStatus {
            label.alignment = .left
            label.frame = NSRect(x: 0, y: 14, width: max(1, bounds.width - 84), height: 20)
            actionButton.frame = NSRect(x: max(0, bounds.width - 76), y: 8, width: 76, height: 30)
        } else if footer == .loadMore {
            label.frame = .zero
            let width = min(120, max(1, bounds.width))
            actionButton.frame = NSRect(
                x: max(0, (bounds.width - width) / 2),
                y: 5,
                width: width,
                height: 30
            )
        } else {
            label.alignment = .center
            label.frame = bounds
            actionButton.frame = .zero
        }
    }

    func reset() {
        onRetry = nil
        onLoadMore = nil
        label.stringValue = ""
        actionButton.isHidden = true
        spinner.setCommentsLoading(false)
        setAccessibilityElement(false)
        setAccessibilityValue(nil)
    }

    @objc private func performAction() {
        switch footer {
        case .failed, .stopped:
            onRetry?()
        case .loadMore:
            onLoadMore?()
        case .loading, .end:
            break
        }
    }
}

extension NSProgressIndicator {
    /// 评论状态行与页脚共用的加载转圈：系统转圈样式，停止时不绘制，初始隐藏。
    ///
    /// 不作为读屏元素：所在行已经读出“评论加载中”或“后续评论加载中”，转圈再读会重复。
    fileprivate static func commentsLoadingSpinner(
        controlSize: NSControl.ControlSize
    ) -> NSProgressIndicator {
        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = controlSize
        spinner.isDisplayedWhenStopped = false
        spinner.isHidden = true
        spinner.setAccessibilityElement(false)
        return spinner
    }

    /// 加载中显示并转动，否则停止并隐藏。
    ///
    /// 条目离屏后被复用时由 `reset()` 走到停止分支，不留下仍在转的转圈。
    fileprivate func setCommentsLoading(_ isLoading: Bool) {
        isHidden = !isLoading
        if isLoading {
            startAnimation(nil)
        } else {
            stopAnimation(nil)
        }
    }

    /// 按系统给出的转圈尺寸居中在行内；行高由 `NativePlaybackCommentsItemMeasurement` 决定，
    /// 布局与测量因此用同一个高度。
    fileprivate func centeredFrame(in bounds: NSRect) -> NSRect {
        let size = intrinsicContentSize
        return NSRect(
            x: round((bounds.width - size.width) / 2),
            y: round((bounds.height - size.height) / 2),
            width: size.width,
            height: size.height
        )
    }
}
