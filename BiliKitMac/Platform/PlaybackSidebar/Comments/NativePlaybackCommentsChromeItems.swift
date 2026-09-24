import AppKit
import BiliBrowseFeature
import BiliModels

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

@MainActor
private final class NativePlaybackCommentsHeaderView: NSView {
    override var isFlipped: Bool { true }
    private let titleLabel = NSTextField(labelWithString: AppStrings.localized("评论"))
    private let countLabel = NSTextField(labelWithString: "")
    private let sortControl = NSSegmentedControl(
        labels: [AppStrings.localized("热门"), AppStrings.localized("最新")],
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
        sortControl.setAccessibilityLabel(AppStrings.localized("评论排序"))
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
            countLabel.setAccessibilityLabel(AppStrings.localized("共 \(count) 条评论"))
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

@MainActor
private final class NativePlaybackCommentsStateView: NSView {
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(wrappingLabelWithString: "")
    private let retryButton = NSButton(title: AppStrings.localized("重试"), target: nil, action: nil)
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
            titleLabel.stringValue = AppStrings.localized("评论暂不可用")
            detailLabel.stringValue = AppStrings.localized("当前视频缺少可用的评论标识。")
            setAccessibilityLabel(AppStrings.localized("评论暂不可用，当前视频缺少可用的评论标识"))
        case .loading:
            titleLabel.stringValue = ""
            detailLabel.stringValue = ""
            setAccessibilityLabel(AppStrings.localized("评论加载中"))
        case .empty:
            titleLabel.stringValue = AppStrings.localized("暂无评论")
            detailLabel.stringValue = AppStrings.localized("这个视频还没有公开评论。")
            setAccessibilityLabel(AppStrings.localized("暂无评论，这个视频还没有公开评论"))
        case .failed:
            titleLabel.stringValue = AppStrings.localized("评论加载失败")
            detailLabel.stringValue = ""
            retryButton.isHidden = false
            setAccessibilityLabel(AppStrings.localized("评论加载失败"))
        }
        setAccessibilityElement(true)
        needsLayout = true
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        guard kind != .loading else { return }
        let contentWidth = max(120, bounds.width - 24)
        if kind == .failed {
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

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard kind == .loading else { return }
        let contentWidth = max(80, bounds.width - 42)
        var y: CGFloat = 8
        for _ in 0..<4 {
            NSColor.quaternaryLabelColor.setFill()
            NSBezierPath(
                roundedRect: NSRect(x: 0, y: y, width: 32, height: 32),
                xRadius: 16,
                yRadius: 16
            ).fill()
            NSBezierPath(
                roundedRect: NSRect(x: 42, y: y + 1, width: min(100, contentWidth), height: 12),
                xRadius: 4,
                yRadius: 4
            ).fill()
            NativePlaybackSkeletonColor.detailFill.setFill()
            NSBezierPath(
                roundedRect: NSRect(x: 42, y: y + 20, width: contentWidth, height: 30),
                xRadius: 4,
                yRadius: 4
            ).fill()
            y += 58
        }
    }

    func reset() {
        onRetry = nil
        titleLabel.stringValue = ""
        detailLabel.stringValue = ""
        retryButton.isHidden = true
    }

    @objc private func retry() { onRetry?() }
}

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

@MainActor
private final class NativePlaybackCommentsFooterView: NSView {
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    private let label = NSTextField(labelWithString: "")
    private let actionButton = NSButton(title: AppStrings.localized("重试"), target: nil, action: nil)
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
            setAccessibilityLabel(AppStrings.localized("后续评论加载中"))
            setAccessibilityValue(nil)
        case .retry:
            label.stringValue = AppStrings.localized("后续评论加载失败")
            actionButton.title = AppStrings.localized("重试")
            actionButton.isHidden = false
            setAccessibilityElement(false)
            setAccessibilityValue(nil)
        case .stopped:
            label.stringValue = AppStrings.localized("后续评论暂不可用")
            actionButton.title = AppStrings.localized("重试")
            actionButton.isHidden = false
            setAccessibilityElement(false)
            setAccessibilityValue(nil)
        case .end(let memoryLimited):
            label.stringValue =
                memoryLimited
                ? AppStrings.localized("已显示本次上限 1,000 条评论")
                : AppStrings.localized("已显示全部评论")
            setAccessibilityElement(false)
            setAccessibilityValue(nil)
        case .loadMore:
            label.stringValue = ""
            actionButton.title = AppStrings.localized("加载更多")
            actionButton.isHidden = false
            setAccessibilityElement(false)
            setAccessibilityValue(nil)
        }
        needsLayout = true
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        if footer == .retry || footer == .stopped {
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

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard footer == .loading else { return }
        let contentWidth = max(80, bounds.width - 42)
        var y: CGFloat = 4
        for _ in 0..<2 {
            NSColor.quaternaryLabelColor.setFill()
            NSBezierPath(
                roundedRect: NSRect(x: 0, y: y, width: 32, height: 32),
                xRadius: 16,
                yRadius: 16
            ).fill()
            NSBezierPath(
                roundedRect: NSRect(x: 42, y: y + 1, width: min(100, contentWidth), height: 12),
                xRadius: 4,
                yRadius: 4
            ).fill()
            NativePlaybackSkeletonColor.detailFill.setFill()
            NSBezierPath(
                roundedRect: NSRect(x: 42, y: y + 20, width: contentWidth, height: 30),
                xRadius: 4,
                yRadius: 4
            ).fill()
            y += 58
        }
    }

    func reset() {
        onRetry = nil
        onLoadMore = nil
        label.stringValue = ""
        actionButton.isHidden = true
        setAccessibilityElement(false)
        setAccessibilityValue(nil)
    }

    @objc private func performAction() {
        switch footer {
        case .retry, .stopped:
            onRetry?()
        case .loadMore:
            onLoadMore?()
        case .loading, .end:
            break
        }
    }
}
