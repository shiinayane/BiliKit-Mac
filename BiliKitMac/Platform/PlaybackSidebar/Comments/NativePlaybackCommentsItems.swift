import AppKit
import BiliBrowseFeature
import BiliModels

@MainActor
enum NativePlaybackCommentsItemMeasurement {
    static let headerHeight: CGFloat = 42
    static let rootAvatarSize: CGFloat = 32
    static let replyAvatarSize: CGFloat = 22
    static let contentGap: CGFloat = 10
    static let rootVerticalInset: CGFloat = 12
    static let replyPanelLeading: CGFloat = 42
    static let replyPanelPadding: CGFloat = 9

    static func state(
        _ kind: NativePlaybackCommentsStateKind,
        width _: CGFloat
    ) -> CGFloat {
        switch kind {
        case .loading: 244
        case .idle, .empty: 112
        case .failed: 48
        }
    }

    static func footer(_ footer: NativePlaybackCommentsFooter) -> CGFloat {
        switch footer {
        case .loading: 122
        case .retry, .stopped: 48
        case .end: 32
        case .loadMore: 40
        }
    }

    static func thread(
        _ presentation: NativePlaybackCommentThreadPresentation,
        width: CGFloat
    ) -> CGFloat {
        let rootHeight = comment(
            presentation.thread.root,
            width: width,
            isReply: false
        )
        let panelWidth = max(80, width - replyPanelLeading)
        let panelHeight = repliesPanel(
            thread: presentation.thread,
            replyState: presentation.replyState,
            width: panelWidth
        )
        return ceil(
            rootVerticalInset + rootHeight
                + (panelHeight > 0 ? 10 + panelHeight : 0)
                + rootVerticalInset
        )
    }

    static func comment(
        _ comment: BiliModels.Comment,
        width: CGFloat,
        isReply: Bool
    ) -> CGFloat {
        switch comment.payload {
        case .unavailable:
            return isReply ? 22 : 30
        case .available(let details):
            let avatar = isReply ? replyAvatarSize : rootAvatarSize
            let contentWidth = max(60, width - avatar - contentGap)
            let bodyHeight = max(
                18,
                NativePlaybackSidebarTextLayout.height(
                    details.content.message,
                    width: contentWidth,
                    font: .preferredFont(forTextStyle: .body)
                )
            )
            let authorHeight = authorLineHeight(
                details.author,
                width: contentWidth,
                isReply: isReply
            )
            var contentHeight: CGFloat = authorHeight + 6 + bodyHeight
            if details.content.pictureCount > 0 {
                contentHeight +=
                    8
                    + pictureGridHeight(
                        count: details.content.pictureCount,
                        width: contentWidth
                    )
            }
            contentHeight += 6 + 18
            if hasVisibleProvenance(details.provenance) {
                contentHeight += 6 + 20
            }
            return ceil(max(avatar, contentHeight))
        }
    }

    static func repliesPanel(
        thread: CommentThread,
        replyState: PlaybackCommentReplyState?,
        width: CGFloat
    ) -> CGFloat {
        guard case .available(let details) = thread.root.payload,
            details.replyCount > 0
        else { return 0 }
        let innerWidth = max(60, width - replyPanelPadding * 2)
        var height = replyPanelPadding
        if let replyState, replyState.isExpanded {
            height += 20 + 10
            for (index, reply) in replyState.replies.enumerated() {
                height += comment(reply, width: innerWidth, isReply: true)
                if index < replyState.replies.count - 1 { height += 8 }
            }
            if replyState.isLoading || replyState.error != nil {
                height += 32
            } else {
                if !replyState.replies.isEmpty { height += 10 }
                height += 26
            }
        } else {
            let replies = Array(thread.replyPreview.prefix(2))
            for (index, reply) in replies.enumerated() {
                height += comment(reply, width: innerWidth, isReply: true)
                if index < replies.count - 1 { height += 8 }
            }
            if replies.count < details.replyCount {
                if !replies.isEmpty { height += 9 }
                height += 24
            }
        }
        return ceil(height + replyPanelPadding)
    }

    static func pictureGridHeight(count: Int, width: CGFloat) -> CGFloat {
        let displayedCount = min(max(count, 0), 9)
        guard displayedCount > 0 else { return 0 }
        if displayedCount == 1 {
            return min(168, floor(width * 0.75))
        }
        let columns = displayedCount >= 5 ? 3 : 2
        let gap: CGFloat = 4
        let tile = floor(
            (width - CGFloat(columns - 1) * gap) / CGFloat(columns)
        )
        let rows = (displayedCount + columns - 1) / columns
        return CGFloat(rows) * tile + CGFloat(rows - 1) * gap
    }

    static func hasVisibleProvenance(_ values: [CommentProvenance]) -> Bool {
        values.contains(.adminPinned)
            || values.contains(.uploaderPinned)
            || values.contains(.uploaderLiked)
    }

    static func authorLineHeight(
        _ author: CommentAuthor,
        width: CGFloat,
        isReply: Bool
    ) -> CGFloat {
        let nameWidth = authorNameTextWidth(author, maximumWidth: width)
        let badgesWidth = NativePlaybackCommentAuthorBadgesView.preferredWidth(
            for: author,
            isReply: isReply
        )
        guard badgesWidth > 0,
            nameWidth + authorBadgeSpacing + badgesWidth > width
        else {
            return 18
        }
        return 38
    }

    static let authorBadgeSpacing: CGFloat = 4

    static func authorNameTextWidth(
        _ author: CommentAuthor,
        maximumWidth: CGFloat
    ) -> CGFloat {
        let font = NSFont.systemFont(
            ofSize: NSFont.preferredFont(forTextStyle: .body).pointSize,
            weight: .semibold
        )
        return min(
            maximumWidth,
            ceil((author.name as NSString).size(withAttributes: [.font: font]).width)
        )
    }

    static func authorNameWidth(
        _ author: CommentAuthor,
        maximumWidth: CGFloat
    ) -> CGFloat {
        min(
            maximumWidth,
            authorNameTextWidth(author, maximumWidth: maximumWidth) + 12
        )
    }
}

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
    private let titleLabel = NSTextField(labelWithString: "评论")
    private let countLabel = NSTextField(labelWithString: "")
    private let sortControl = NSSegmentedControl(
        labels: ["热门", "最新"],
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
        sortControl.setAccessibilityLabel("评论排序")
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
            countLabel.setAccessibilityLabel("共 \(count) 条评论")
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
    private let retryButton = NSButton(title: "重试", target: nil, action: nil)
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
            titleLabel.stringValue = "评论暂不可用"
            detailLabel.stringValue = "当前视频缺少可用的评论标识。"
            setAccessibilityLabel("评论暂不可用，当前视频缺少可用的评论标识")
        case .loading:
            titleLabel.stringValue = ""
            detailLabel.stringValue = ""
            setAccessibilityLabel("评论加载中")
        case .empty:
            titleLabel.stringValue = "暂无评论"
            detailLabel.stringValue = "这个视频还没有公开评论。"
            setAccessibilityLabel("暂无评论，这个视频还没有公开评论")
        case .failed:
            titleLabel.stringValue = "评论加载失败"
            detailLabel.stringValue = ""
            retryButton.isHidden = false
            setAccessibilityLabel("评论加载失败")
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
            NSColor.quinaryLabel.setFill()
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
    private let actionButton = NSButton(title: "重试", target: nil, action: nil)
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
            setAccessibilityLabel("后续评论加载中")
            setAccessibilityValue(nil)
        case .retry:
            label.stringValue = "后续评论加载失败"
            actionButton.title = "重试"
            actionButton.isHidden = false
            setAccessibilityElement(false)
            setAccessibilityValue(nil)
        case .stopped:
            label.stringValue = "后续评论暂不可用"
            actionButton.title = "重试"
            actionButton.isHidden = false
            setAccessibilityElement(false)
            setAccessibilityValue(nil)
        case .end(let memoryLimited):
            label.stringValue =
                memoryLimited
                ? "已显示本次上限 1,000 条评论"
                : "已显示全部评论"
            setAccessibilityElement(false)
            setAccessibilityValue(nil)
        case .loadMore:
            label.stringValue = ""
            actionButton.title = "加载更多"
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
            NSColor.quinaryLabel.setFill()
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

@MainActor
final class NativePlaybackCommentThreadItem: NSCollectionViewItem {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier(
        "NativePlaybackCommentThreadItem"
    )
    private let contentView = NativePlaybackCommentThreadView()

    override func loadView() { view = contentView }

    func configure(
        presentation: NativePlaybackCommentThreadPresentation,
        onExpand: @escaping () -> Void,
        onCollapse: @escaping () -> Void,
        onPrevious: @escaping () -> Void,
        onNext: @escaping () -> Void,
        onRetry: @escaping () -> Void,
        onOpenVideo: @escaping (String) -> Void
    ) {
        representedObject = presentation
        contentView.configure(
            presentation: presentation,
            onExpand: onExpand,
            onCollapse: onCollapse,
            onPrevious: onPrevious,
            onNext: onNext,
            onRetry: onRetry,
            onOpenVideo: onOpenVideo
        )
    }

    func releaseOffscreenResources() {
        contentView.releaseOffscreenResources()
    }

    override func prepareForReuse() {
        contentView.reset()
        representedObject = nil
        super.prepareForReuse()
    }
}

@MainActor
private final class NativePlaybackCommentThreadView: NSView {
    override var isFlipped: Bool { true }
    private let rootRow = NativePlaybackCommentRowView()
    private let repliesPanel = NativePlaybackCommentRepliesPanelView()
    private let separator = NSBox()
    private var presentation: NativePlaybackCommentThreadPresentation?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        separator.boxType = .separator
        addSubview(rootRow)
        addSubview(repliesPanel)
        addSubview(separator)
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func configure(
        presentation: NativePlaybackCommentThreadPresentation,
        onExpand: @escaping () -> Void,
        onCollapse: @escaping () -> Void,
        onPrevious: @escaping () -> Void,
        onNext: @escaping () -> Void,
        onRetry: @escaping () -> Void,
        onOpenVideo: @escaping (String) -> Void
    ) {
        self.presentation = presentation
        rootRow.configure(
            comment: presentation.thread.root,
            isReply: false,
            onOpenVideo: onOpenVideo
        )
        repliesPanel.configure(
            thread: presentation.thread,
            replyState: presentation.replyState,
            onExpand: onExpand,
            onCollapse: onCollapse,
            onPrevious: onPrevious,
            onNext: onNext,
            onRetry: onRetry,
            onOpenVideo: onOpenVideo
        )
        needsLayout = true
    }

    override func layout() {
        super.layout()
        guard let presentation else { return }
        let rootHeight = NativePlaybackCommentsItemMeasurement.comment(
            presentation.thread.root,
            width: bounds.width,
            isReply: false
        )
        rootRow.frame = NSRect(
            x: 0,
            y: NativePlaybackCommentsItemMeasurement.rootVerticalInset,
            width: bounds.width,
            height: rootHeight
        )
        let panelWidth = max(
            80,
            bounds.width - NativePlaybackCommentsItemMeasurement.replyPanelLeading
        )
        let panelHeight = NativePlaybackCommentsItemMeasurement.repliesPanel(
            thread: presentation.thread,
            replyState: presentation.replyState,
            width: panelWidth
        )
        repliesPanel.isHidden = panelHeight <= 0
        repliesPanel.frame = NSRect(
            x: NativePlaybackCommentsItemMeasurement.replyPanelLeading,
            y: rootRow.frame.maxY + (panelHeight > 0 ? 10 : 0),
            width: panelWidth,
            height: panelHeight
        )
        separator.frame = NSRect(
            x: NativePlaybackCommentsItemMeasurement.replyPanelLeading,
            y: max(0, bounds.height - 1),
            width: panelWidth,
            height: 1
        )
    }

    func releaseOffscreenResources() {
        rootRow.releaseTextStorage()
        repliesPanel.releaseTextStorage()
    }

    func reset() {
        presentation = nil
        rootRow.reset()
        repliesPanel.reset()
    }
}

@MainActor
private final class NativePlaybackCommentRowView: NSView {
    override var isFlipped: Bool { true }
    private let avatar = NativePlaybackCommentAvatarView()
    private let authorLabel = NSTextField(labelWithString: "")
    private let authorBadges = NativePlaybackCommentAuthorBadgesView()
    private let bodyText = NativePlaybackCommentTextView()
    private let pictures = NativePlaybackCommentPicturesView()
    private let metadataLabel = NSTextField(labelWithString: "")
    private let likeImage = NSImageView()
    private let likeLabel = NSTextField(labelWithString: "")
    private let provenanceBadges = NativePlaybackCommentProvenanceBadgesView()
    private let unavailableLabel = NSTextField(labelWithString: "")
    private var comment: BiliModels.Comment?
    private var isReply = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        authorLabel.font = .systemFont(
            ofSize: NSFont.preferredFont(forTextStyle: .body).pointSize,
            weight: .semibold
        )
        authorLabel.maximumNumberOfLines = 1
        authorLabel.lineBreakMode = .byTruncatingTail
        metadataLabel.font = .preferredFont(forTextStyle: .callout)
        metadataLabel.textColor = .tertiaryLabelColor
        metadataLabel.lineBreakMode = .byTruncatingTail
        likeImage.image = NSImage(
            systemSymbolName: "hand.thumbsup",
            accessibilityDescription: "点赞"
        )
        likeImage.symbolConfiguration = NSImage.SymbolConfiguration(
            pointSize: 12,
            weight: .regular
        )
        likeImage.contentTintColor = .tertiaryLabelColor
        likeImage.imageScaling = .scaleProportionallyDown
        likeImage.setAccessibilityElement(false)
        likeLabel.font = .preferredFont(forTextStyle: .callout)
        likeLabel.textColor = .tertiaryLabelColor
        likeLabel.alignment = .right
        likeLabel.setAccessibilityElement(false)
        unavailableLabel.font = .preferredFont(forTextStyle: .body)
        unavailableLabel.textColor = .secondaryLabelColor
        for subview in [
            avatar,
            authorLabel,
            authorBadges,
            bodyText,
            pictures,
            metadataLabel,
            likeImage,
            likeLabel,
            provenanceBadges,
            unavailableLabel,
        ] {
            addSubview(subview)
        }
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func configure(
        comment: BiliModels.Comment,
        isReply: Bool,
        onOpenVideo: @escaping (String) -> Void
    ) {
        self.comment = comment
        self.isReply = isReply
        bodyText.onOpenVideo = onOpenVideo
        switch comment.payload {
        case .unavailable(let reason):
            avatar.isHidden = true
            authorLabel.isHidden = true
            authorBadges.isHidden = true
            bodyText.isHidden = true
            pictures.isHidden = true
            metadataLabel.isHidden = true
            likeImage.isHidden = true
            likeLabel.isHidden = true
            provenanceBadges.isHidden = true
            unavailableLabel.isHidden = false
            unavailableLabel.stringValue = Self.unavailableText(reason)
            unavailableLabel.setAccessibilityLabel(unavailableLabel.stringValue)
        case .available(let details):
            avatar.isHidden = false
            authorLabel.isHidden = false
            authorBadges.isHidden = false
            bodyText.isHidden = false
            metadataLabel.isHidden = false
            likeImage.isHidden = false
            likeLabel.isHidden = false
            unavailableLabel.isHidden = true
            avatar.configure(author: details.author, isReply: isReply)
            authorLabel.stringValue = details.author.name
            authorLabel.textColor = Self.authorColor(details.author)
            authorLabel.setAccessibilityLabel(
                Self.authorAccessibility(details.author)
            )
            authorBadges.configure(author: details.author, isReply: isReply)
            bodyText.setContent(details.content)
            pictures.count = details.content.pictureCount
            pictures.isHidden = details.content.pictureCount == 0
            metadataLabel.stringValue = Self.metadataLeading(details)
            metadataLabel.setAccessibilityLabel(Self.metadataAccessibility(details))
            likeLabel.stringValue = CommentPresentationFormatting.compactCount(
                details.likeCount
            )
            provenanceBadges.configure(details.provenance)
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        guard let comment else { return }
        switch comment.payload {
        case .unavailable:
            unavailableLabel.frame = bounds
        case .available(let details):
            let avatarSize =
                isReply
                ? NativePlaybackCommentsItemMeasurement.replyAvatarSize
                : NativePlaybackCommentsItemMeasurement.rootAvatarSize
            avatar.frame = NSRect(x: 0, y: 0, width: avatarSize, height: avatarSize)
            let contentX = avatarSize + NativePlaybackCommentsItemMeasurement.contentGap
            let contentWidth = max(60, bounds.width - contentX)
            let badgesWidth = min(authorBadges.preferredWidth, contentWidth)
            let authorWidth = NativePlaybackCommentsItemMeasurement.authorNameWidth(
                details.author,
                maximumWidth: contentWidth
            )
            let authorTextWidth =
                NativePlaybackCommentsItemMeasurement.authorNameTextWidth(
                    details.author,
                    maximumWidth: contentWidth
                )
            let wrapsBadges =
                badgesWidth > 0
                && authorTextWidth
                    + NativePlaybackCommentsItemMeasurement.authorBadgeSpacing
                    + badgesWidth > contentWidth
            authorLabel.frame = NSRect(
                x: contentX,
                y: 0,
                width: authorWidth,
                height: 18
            )
            authorBadges.frame = NSRect(
                x: wrapsBadges
                    ? contentX
                    : contentX + authorTextWidth
                        + (badgesWidth > 0
                            ? NativePlaybackCommentsItemMeasurement.authorBadgeSpacing
                            : 0),
                y: wrapsBadges ? 20 : 0,
                width: badgesWidth,
                height: 18
            )
            var y =
                NativePlaybackCommentsItemMeasurement.authorLineHeight(
                    details.author,
                    width: contentWidth,
                    isReply: isReply
                ) + 6
            let bodyHeight = max(
                18,
                NativePlaybackSidebarTextLayout.height(
                    details.content.message,
                    width: contentWidth,
                    font: .preferredFont(forTextStyle: .body)
                )
            )
            bodyText.frame = NSRect(x: contentX, y: y, width: contentWidth, height: bodyHeight)
            y += bodyHeight
            if details.content.pictureCount > 0 {
                y += 8
                let picturesHeight = NativePlaybackCommentsItemMeasurement.pictureGridHeight(
                    count: details.content.pictureCount,
                    width: contentWidth
                )
                pictures.frame = NSRect(
                    x: contentX,
                    y: y,
                    width: contentWidth,
                    height: picturesHeight
                )
                y += picturesHeight
            } else {
                pictures.frame = .zero
            }
            y += 6
            let likeWidth = ceil(likeLabel.intrinsicContentSize.width) + 3
            let trailingInset: CGFloat = 2
            likeLabel.frame = NSRect(
                x: max(contentX, bounds.width - trailingInset - likeWidth),
                y: y,
                width: likeWidth,
                height: 18
            )
            likeImage.frame = NSRect(
                x: max(contentX, likeLabel.frame.minX - 18),
                y: y + 2,
                width: 14,
                height: 14
            )
            metadataLabel.frame = NSRect(
                x: contentX,
                y: y,
                width: max(1, likeImage.frame.minX - contentX - 6),
                height: 18
            )
            y += 18
            if NativePlaybackCommentsItemMeasurement.hasVisibleProvenance(
                details.provenance
            ) {
                y += 6
                provenanceBadges.frame = NSRect(
                    x: contentX,
                    y: y,
                    width: contentWidth,
                    height: 20
                )
            } else {
                provenanceBadges.frame = .zero
            }
        }
    }

    func releaseTextStorage() {
        bodyText.releaseTextStorage()
    }

    func reset() {
        comment = nil
        bodyText.reset()
        unavailableLabel.stringValue = ""
        authorLabel.stringValue = ""
        authorBadges.reset()
        metadataLabel.stringValue = ""
        likeLabel.stringValue = ""
        provenanceBadges.reset()
        pictures.count = 0
    }

    private static func authorColor(_ author: CommentAuthor) -> NSColor {
        author.isVIP ? .systemPink : .labelColor
    }

    private static func metadataLeading(_ details: CommentDetails) -> String {
        let time = CommentTimeFormatter.string(for: details.createdAt)
        let location = details.location.flatMap { $0.isEmpty ? nil : $0 }
        return [time, location].compactMap { $0 }.joined(separator: "  ·  ")
    }

    private static func metadataAccessibility(_ details: CommentDetails) -> String {
        let time = CommentTimeFormatter.string(for: details.createdAt)
        let likes = CommentPresentationFormatting.compactCount(details.likeCount)
        let location = details.location.flatMap { $0.isEmpty ? nil : $0 }
            .map { "IP属地：\($0)" }
        return [time, location, "获赞 \(likes)"]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: "，")
    }

    private static func authorAccessibility(_ author: CommentAuthor) -> String {
        var values = ["评论者，\(author.name)"]
        switch author.sex {
        case .male: values.append("男性")
        case .female: values.append("女性")
        case .unspecified: break
        }
        if let level = author.level { values.append("等级 \(level)") }
        if author.isHardcoreMember { values.append("硬核会员") }
        if author.isVIP { values.append("大会员") }
        if author.isUploader { values.append("UP 主") }
        switch author.verification {
        case .personal: values.append("个人认证")
        case .organization: values.append("机构认证")
        case nil: break
        }
        return values.joined(separator: "，")
    }

    private static func unavailableText(_ reason: CommentUnavailableReason) -> String {
        switch reason {
        case .deleted: "该评论已删除"
        case .folded: "该评论已折叠"
        case .unavailable, .unknown: "该评论暂不可见"
        }
    }
}

@MainActor
final class NativePlaybackCommentAuthorBadgesView: NSView {
    override var isFlipped: Bool { true }

    private struct Segment {
        let text: String
        let foreground: NSColor
        let background: NSColor?
        let stroke: NSColor?
        let horizontalPadding: CGFloat
    }

    private var segments: [Segment] = []
    private var font = NSFont.systemFont(ofSize: 10, weight: .bold)
    private(set) var displayedTexts: [String] = []

    var preferredWidth: CGFloat {
        Self.preferredWidth(segments: segments, font: font)
    }

    static func preferredWidth(for author: CommentAuthor, isReply: Bool) -> CGFloat {
        let font = NSFont.systemFont(ofSize: isReply ? 9 : 10, weight: .bold)
        return preferredWidth(segments: segments(for: author), font: font)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func configure(author: CommentAuthor, isReply: Bool) {
        font = .systemFont(ofSize: isReply ? 9 : 10, weight: .bold)
        segments = Self.segments(for: author)
        displayedTexts = segments.map(\.text)
        isHidden = segments.isEmpty
        needsDisplay = true
    }

    private static func segments(for author: CommentAuthor) -> [Segment] {
        var result: [Segment] = []
        switch author.sex {
        case .male:
            result.append(
                Segment(
                    text: "♂",
                    foreground: .systemBlue,
                    background: nil,
                    stroke: nil,
                    horizontalPadding: 0
                )
            )
        case .female:
            result.append(
                Segment(
                    text: "♀",
                    foreground: .systemPink,
                    background: nil,
                    stroke: nil,
                    horizontalPadding: 0
                )
            )
        case .unspecified:
            break
        }
        if let level = author.level {
            let color = Self.levelColor(level)
            result.append(
                Segment(
                    text: author.isHardcoreMember ? "LV\(level)⚡︎" : "LV\(level)",
                    foreground: .labelColor,
                    background: color.withAlphaComponent(0.16),
                    stroke: color.withAlphaComponent(0.55),
                    horizontalPadding: 3
                )
            )
        } else if author.isHardcoreMember {
            result.append(
                Segment(
                    text: "⚡︎",
                    foreground: .systemOrange,
                    background: NSColor.systemOrange.withAlphaComponent(0.12),
                    stroke: NSColor.systemOrange.withAlphaComponent(0.45),
                    horizontalPadding: 3
                )
            )
        }
        if author.isUploader {
            result.append(
                Segment(
                    text: "UP",
                    foreground: .white,
                    background: NSColor(
                        srgbRed: 142 / 255,
                        green: 18 / 255,
                        blue: 75 / 255,
                        alpha: 1
                    ),
                    stroke: nil,
                    horizontalPadding: 4
                )
            )
        }
        return result
    }

    func reset() {
        segments.removeAll(keepingCapacity: true)
        displayedTexts.removeAll(keepingCapacity: true)
        isHidden = true
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        var x: CGFloat = 0
        let badgeHeight = min(14, bounds.height)
        let y = floor((bounds.height - badgeHeight) / 2)
        for segment in segments {
            let width = segmentWidth(segment)
            let rect = NSRect(x: x, y: y, width: width, height: badgeHeight)
            if let background = segment.background {
                background.setFill()
                NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2).fill()
            }
            if let stroke = segment.stroke {
                stroke.setStroke()
                let strokeRect = rect.insetBy(dx: 0.5, dy: 0.5)
                NSBezierPath(roundedRect: strokeRect, xRadius: 2, yRadius: 2)
                    .stroke()
            }
            let text = segment.text as NSString
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: segment.foreground,
            ]
            let size = text.size(withAttributes: attributes)
            text.draw(
                at: NSPoint(
                    x: rect.midX - size.width / 2,
                    y: rect.midY - size.height / 2
                ),
                withAttributes: attributes
            )
            x += width + 5
        }
    }

    private func segmentWidth(_ segment: Segment) -> CGFloat {
        Self.segmentWidth(segment, font: font)
    }

    private static func preferredWidth(
        segments: [Segment],
        font: NSFont
    ) -> CGFloat {
        guard !segments.isEmpty else { return 0 }
        return segments.reduce(CGFloat.zero) { width, segment in
            width + segmentWidth(segment, font: font)
        } + CGFloat(max(0, segments.count - 1)) * 5
    }

    private static func segmentWidth(_ segment: Segment, font: NSFont) -> CGFloat {
        ceil(
            (segment.text as NSString).size(withAttributes: [.font: font]).width
                + segment.horizontalPadding * 2
        )
    }

    private static func levelColor(_ level: Int) -> NSColor {
        switch level {
        case ...1: NSColor(srgbRed: 192 / 255, green: 192 / 255, blue: 192 / 255, alpha: 1)
        case 2: NSColor(srgbRed: 139 / 255, green: 210 / 255, blue: 155 / 255, alpha: 1)
        case 3: NSColor(srgbRed: 123 / 255, green: 205 / 255, blue: 239 / 255, alpha: 1)
        case 4: NSColor(srgbRed: 254 / 255, green: 187 / 255, blue: 139 / 255, alpha: 1)
        case 5: NSColor(srgbRed: 238 / 255, green: 103 / 255, blue: 42 / 255, alpha: 1)
        default: NSColor(srgbRed: 240 / 255, green: 76 / 255, blue: 73 / 255, alpha: 1)
        }
    }
}

@MainActor
final class NativePlaybackCommentProvenanceBadgesView: NSView {
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    private struct Segment {
        let text: String
        let foreground: NSColor
        let background: NSColor
    }

    private let font = NSFont.systemFont(
        ofSize: NSFont.preferredFont(forTextStyle: .caption2).pointSize,
        weight: .semibold
    )
    private var segments: [Segment] = []
    private(set) var displayedTexts: [String] = []

    func configure(_ provenance: [CommentProvenance]) {
        var result: [Segment] = []
        if provenance.contains(.adminPinned) || provenance.contains(.uploaderPinned) {
            result.append(
                Segment(
                    text: "置顶",
                    foreground: .systemPink,
                    background: NSColor.systemPink.withAlphaComponent(0.14)
                )
            )
        }
        if provenance.contains(.uploaderLiked) {
            result.append(
                Segment(
                    text: "UP 主觉得很赞",
                    foreground: .secondaryLabelColor,
                    background: NSColor.secondaryLabelColor.withAlphaComponent(0.12)
                )
            )
        }
        segments = result
        displayedTexts = result.map(\.text)
        isHidden = result.isEmpty
        setAccessibilityElement(!result.isEmpty)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(
            result.isEmpty ? nil : displayedTexts.joined(separator: "，")
        )
        needsDisplay = true
    }

    func reset() {
        segments.removeAll(keepingCapacity: true)
        displayedTexts.removeAll(keepingCapacity: true)
        isHidden = true
        setAccessibilityElement(false)
        setAccessibilityLabel(nil)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        var x: CGFloat = 0
        let height = min(18, bounds.height)
        let y = floor((bounds.height - height) / 2)
        for segment in segments {
            let textSize = (segment.text as NSString).size(withAttributes: [.font: font])
            let width = ceil(textSize.width) + 14
            let rect = NSRect(x: x, y: y, width: width, height: height)
            segment.background.setFill()
            NSBezierPath(
                roundedRect: rect,
                xRadius: height / 2,
                yRadius: height / 2
            ).fill()
            (segment.text as NSString).draw(
                at: NSPoint(
                    x: rect.midX - textSize.width / 2,
                    y: rect.midY - textSize.height / 2
                ),
                withAttributes: [
                    .font: font,
                    .foregroundColor: segment.foreground,
                ]
            )
            x += width + 6
        }
    }
}

@MainActor
private final class NativePlaybackCommentTextView: NSTextView, NSTextViewDelegate {
    var onOpenVideo: ((String) -> Void)?

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
            .foregroundColor: NSColor.linkColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
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

    func setContent(_ content: CommentContent) {
        let previousSelections = selectedRanges
        let attributed = NSMutableAttributedString(
            string: content.message,
            attributes: [
                .font: NSFont.preferredFont(forTextStyle: .body),
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: NativePlaybackSidebarTextLayout.paragraphStyle,
            ]
        )
        let fullLength = attributed.length
        for link in content.links {
            let range = NSRange(location: link.range.location, length: link.range.length)
            guard range.location >= 0, range.length >= 0,
                NSMaxRange(range) <= fullLength
            else { continue }
            guard case .video(let bvid) = link.target,
                let escaped = bvid.addingPercentEncoding(
                    withAllowedCharacters: .urlPathAllowed
                ),
                let url = URL(string: "bilikit-comment://video/\(escaped)")
            else { continue }
            attributed.addAttribute(.link, value: url, range: range)
        }
        textStorage?.setAttributedString(attributed)
        selectedRanges = NativePlaybackSidebarReadOnlyTextView.clampedSelections(
            previousSelections,
            textLength: fullLength
        )
        setAccessibilityLabel(content.message)
    }

    func releaseTextStorage() {
        textStorage?.setAttributedString(NSAttributedString(string: ""))
    }

    func reset() {
        onOpenVideo = nil
        releaseTextStorage()
    }

    func textView(
        _ textView: NSTextView,
        clickedOnLink link: Any,
        at charIndex: Int
    ) -> Bool {
        guard let url = link as? URL,
            url.scheme == "bilikit-comment",
            url.host == "video"
        else { return false }
        let bvid = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !bvid.isEmpty else { return false }
        onOpenVideo?(bvid)
        return true
    }
}

@MainActor
private final class NativePlaybackCommentAvatarView: NSView {
    override var isFlipped: Bool { true }
    private let initialLabel = NSTextField(labelWithString: "")
    private let badgeImage = NSImageView()
    private var author: CommentAuthor?
    private var isReply = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        initialLabel.alignment = .center
        initialLabel.textColor = .white
        badgeImage.contentTintColor = .white
        badgeImage.imageScaling = .scaleProportionallyDown
        badgeImage.setAccessibilityElement(false)
        addSubview(initialLabel)
        addSubview(badgeImage)
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func configure(author: CommentAuthor, isReply: Bool) {
        self.author = author
        self.isReply = isReply
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
        needsLayout = true
        needsDisplay = true
    }

    override func layout() {
        super.layout()
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
        let path = NSBezierPath(ovalIn: bounds)
        path.addClip()
        NSGradient(
            starting: .systemPink,
            ending: .systemBlue
        )?.draw(in: bounds, angle: -45)
    }
}

@MainActor
private final class NativePlaybackCommentPicturesView: NSView {
    override var isFlipped: Bool { true }
    var count = 0 {
        didSet {
            setAccessibilityElement(count > 0)
            setAccessibilityLabel("图片内容暂不可用，共 \(count) 张")
            needsDisplay = true
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let displayedCount = min(max(count, 0), 9)
        guard displayedCount > 0 else { return }
        let columns = displayedCount == 1 ? 1 : (displayedCount >= 5 ? 3 : 2)
        let gap: CGFloat = 4
        let tileWidth =
            displayedCount == 1
            ? bounds.width
            : floor((bounds.width - CGFloat(columns - 1) * gap) / CGFloat(columns))
        let tileHeight =
            displayedCount == 1
            ? bounds.height
            : tileWidth
        for index in 0..<displayedCount {
            let column = index % columns
            let row = index / columns
            let rect = NSRect(
                x: CGFloat(column) * (tileWidth + gap),
                y: CGFloat(row) * (tileHeight + gap),
                width: tileWidth,
                height: tileHeight
            )
            NSColor.secondaryLabelColor.withAlphaComponent(0.10).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7).fill()
            NSColor.separatorColor.setStroke()
            NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7).stroke()
            let text = "暂不可用" as NSString
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.preferredFont(forTextStyle: .caption2),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
            let size = text.size(withAttributes: attributes)
            text.draw(
                at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2),
                withAttributes: attributes
            )
        }
    }
}

@MainActor
private final class NativePlaybackCommentRepliesPanelView: NSView {
    override var isFlipped: Bool { true }
    private let headerLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let expandButton = NSButton(title: "", target: nil, action: nil)
    private let collapseButton = NSButton(title: "收起", target: nil, action: nil)
    private let retryButton = NSButton(title: "重试", target: nil, action: nil)
    private let previousButton = NSButton(title: "上一页", target: nil, action: nil)
    private let pageLabel = NSTextField(labelWithString: "")
    private let nextButton = NSButton(title: "下一页", target: nil, action: nil)
    private var replyRows: [NativePlaybackCommentRowView] = []
    private var thread: CommentThread?
    private var replyState: PlaybackCommentReplyState?
    private var onExpand: (() -> Void)?
    private var onCollapse: (() -> Void)?
    private var onPrevious: (() -> Void)?
    private var onNext: (() -> Void)?
    private var onRetry: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 9
        headerLabel.font = .preferredFont(forTextStyle: .callout)
        headerLabel.textColor = .secondaryLabelColor
        statusLabel.font = .preferredFont(forTextStyle: .callout)
        statusLabel.textColor = .secondaryLabelColor
        pageLabel.font = .monospacedDigitSystemFont(
            ofSize: NSFont.preferredFont(forTextStyle: .callout).pointSize,
            weight: .regular
        )
        pageLabel.textColor = .secondaryLabelColor
        pageLabel.alignment = .center
        for button in [
            expandButton,
            collapseButton,
            retryButton,
            previousButton,
            nextButton,
        ] {
            button.bezelStyle = .rounded
            button.controlSize = .small
        }
        expandButton.isBordered = false
        expandButton.contentTintColor = .controlAccentColor
        expandButton.alignment = .left
        expandButton.image = NSImage(
            systemSymbolName: "chevron.down",
            accessibilityDescription: "展开"
        )
        expandButton.imagePosition = .imageLeading
        expandButton.imageScaling = .scaleProportionallyDown
        collapseButton.isBordered = false
        collapseButton.contentTintColor = .controlAccentColor
        expandButton.target = self
        expandButton.action = #selector(expand)
        collapseButton.target = self
        collapseButton.action = #selector(collapse)
        retryButton.target = self
        retryButton.action = #selector(retry)
        previousButton.target = self
        previousButton.action = #selector(previous)
        nextButton.target = self
        nextButton.action = #selector(next)
        for subview in [
            headerLabel,
            statusLabel,
            expandButton,
            collapseButton,
            retryButton,
            previousButton,
            pageLabel,
            nextButton,
        ] {
            addSubview(subview)
        }
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func updateLayer() {
        super.updateLayer()
        layer?.backgroundColor =
            NSColor.quaternaryLabelColor
            .withAlphaComponent(0.12).cgColor
    }

    func configure(
        thread: CommentThread,
        replyState: PlaybackCommentReplyState?,
        onExpand: @escaping () -> Void,
        onCollapse: @escaping () -> Void,
        onPrevious: @escaping () -> Void,
        onNext: @escaping () -> Void,
        onRetry: @escaping () -> Void,
        onOpenVideo: @escaping (String) -> Void
    ) {
        resetRows()
        self.thread = thread
        self.replyState = replyState
        self.onExpand = onExpand
        self.onCollapse = onCollapse
        self.onPrevious = onPrevious
        self.onNext = onNext
        self.onRetry = onRetry
        guard case .available(let details) = thread.root.payload,
            details.replyCount > 0
        else {
            isHidden = true
            return
        }
        isHidden = false
        let expanded = replyState?.isExpanded == true
        let replies =
            expanded
            ? (replyState?.replies ?? [])
            : Array(thread.replyPreview.prefix(2))
        for reply in replies {
            let row = NativePlaybackCommentRowView()
            row.configure(
                comment: reply,
                isReply: true,
                onOpenVideo: onOpenVideo
            )
            addSubview(row)
            replyRows.append(row)
        }
        let effectiveTotal =
            (replyState?.totalCount ?? 0) > 0
            ? (replyState?.totalCount ?? 0) : details.replyCount
        headerLabel.isHidden = !expanded || replies.count >= effectiveTotal
        collapseButton.isHidden = !expanded
        expandButton.isHidden = expanded || replies.count >= details.replyCount
        retryButton.isHidden = true
        statusLabel.isHidden = true
        previousButton.isHidden = true
        pageLabel.isHidden = true
        nextButton.isHidden = true
        if expanded {
            let total = replyState?.totalCount ?? 0
            headerLabel.stringValue =
                "共 \(CommentPresentationFormatting.compactCount(total > 0 ? total : details.replyCount)) 条回复"
            if replyState?.isLoading == true {
                statusLabel.stringValue = "回复加载中…"
                statusLabel.isHidden = false
            } else if replyState?.error != nil {
                statusLabel.stringValue = "回复加载失败"
                statusLabel.isHidden = false
                retryButton.isHidden = false
            } else if let replyState {
                previousButton.isHidden = false
                pageLabel.isHidden = false
                nextButton.isHidden = false
                previousButton.isEnabled = replyState.pageNumber > 1
                nextButton.isEnabled = !replyState.isEnd
                let pageCount = CommentPresentationFormatting.pageCount(
                    totalCount: replyState.totalCount > 0
                        ? replyState.totalCount : details.replyCount,
                    pageSize: 10
                )
                pageLabel.stringValue = "\(replyState.pageNumber) / \(pageCount)"
                pageLabel.setAccessibilityLabel(
                    "第 \(replyState.pageNumber) 页，共 \(pageCount) 页"
                )
            }
        } else {
            if expandButton.isHidden {
                expandButton.title = ""
                expandButton.setAccessibilityHelp(nil)
            } else {
                let count = CommentPresentationFormatting.compactCount(details.replyCount)
                expandButton.title = "共 \(count) 条回复"
                expandButton.setAccessibilityHelp("展开楼中楼，每页显示十条回复")
            }
        }
        needsLayout = true
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        guard let thread,
            case .available(let details) = thread.root.payload
        else { return }
        let padding = NativePlaybackCommentsItemMeasurement.replyPanelPadding
        let width = max(60, bounds.width - padding * 2)
        var y = padding
        let expanded = replyState?.isExpanded == true
        if expanded {
            headerLabel.frame = NSRect(x: padding, y: y, width: max(1, width - 62), height: 20)
            collapseButton.frame = NSRect(
                x: max(padding, bounds.width - padding - 54),
                y: y - 2,
                width: 54,
                height: 24
            )
            y += 30
        }
        for row in replyRows {
            guard let reply = row.commentForLayout else { continue }
            let height = NativePlaybackCommentsItemMeasurement.comment(
                reply,
                width: width,
                isReply: true
            )
            row.frame = NSRect(x: padding, y: y, width: width, height: height)
            y += height + 8
        }
        if !replyRows.isEmpty { y -= 8 }
        if expanded {
            if replyState?.isLoading == true {
                statusLabel.frame = NSRect(x: padding, y: y, width: width, height: 32)
            } else if replyState?.error != nil {
                statusLabel.frame = NSRect(
                    x: padding,
                    y: y + 5,
                    width: max(1, width - 72),
                    height: 22
                )
                retryButton.frame = NSRect(
                    x: max(padding, bounds.width - padding - 64),
                    y: y + 1,
                    width: 64,
                    height: 28
                )
            } else {
                if !replyRows.isEmpty { y += 10 }
                let third = width / 3
                previousButton.frame = NSRect(x: padding, y: y, width: third, height: 26)
                pageLabel.frame = NSRect(x: padding + third, y: y + 3, width: third, height: 20)
                nextButton.frame = NSRect(x: padding + third * 2, y: y, width: third, height: 26)
            }
        } else {
            if expandButton.isHidden {
                expandButton.frame = .zero
            } else {
                if !replyRows.isEmpty { y += 9 }
                expandButton.frame = NSRect(
                    x: padding,
                    y: y,
                    width: min(width, ceil(expandButton.fittingSize.width)),
                    height: 24
                )
            }
        }
        _ = details
    }

    func releaseTextStorage() {
        for row in replyRows { row.releaseTextStorage() }
    }

    func reset() {
        resetRows()
        thread = nil
        replyState = nil
        onExpand = nil
        onCollapse = nil
        onPrevious = nil
        onNext = nil
        onRetry = nil
        headerLabel.stringValue = ""
        statusLabel.stringValue = ""
    }

    private func resetRows() {
        for row in replyRows {
            row.releaseTextStorage()
            row.removeFromSuperview()
        }
        replyRows.removeAll(keepingCapacity: true)
    }

    @objc private func expand() { onExpand?() }
    @objc private func collapse() { onCollapse?() }
    @objc private func retry() { onRetry?() }
    @objc private func previous() { onPrevious?() }
    @objc private func next() { onNext?() }
}

extension NativePlaybackCommentRowView {
    fileprivate var commentForLayout: BiliModels.Comment? { comment }
}
