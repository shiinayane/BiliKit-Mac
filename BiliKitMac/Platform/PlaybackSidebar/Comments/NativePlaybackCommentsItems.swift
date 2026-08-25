import AppKit
import BiliBrowseFeature
import BiliModels
import CoreText

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
        width: CGFloat,
        textRenderer: NativePlaybackCommentTextRenderer? = nil
    ) -> CGFloat {
        let textScope = presentation.textScope
        let rootHeight = comment(
            presentation.thread.root,
            width: width,
            isReply: false,
            textRenderer: textRenderer,
            textScope: textScope
        )
        let panelWidth = max(80, width - replyPanelLeading)
        let panelHeight = repliesPanel(
            thread: presentation.thread,
            replyState: presentation.replyState,
            width: panelWidth,
            textRenderer: textRenderer,
            textScope: textScope
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
        isReply: Bool,
        textRenderer: NativePlaybackCommentTextRenderer? = nil,
        textScope: NativePlaybackCommentTextScope? = nil
    ) -> CGFloat {
        switch comment.payload {
        case .unavailable:
            return isReply ? 22 : 30
        case .available(let details):
            let avatar = isReply ? replyAvatarSize : rootAvatarSize
            let contentWidth = max(60, width - avatar - contentGap)
            let bodyHeight = max(
                18,
                textRenderer.flatMap { renderer in
                    textScope.map {
                        renderer.height(
                            details.content,
                            width: contentWidth,
                            scope: $0
                        )
                    }
                }
                    ?? NativePlaybackSidebarTextLayout.height(
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
                let pictureLayout = NativePlaybackCommentPictureLayout.make(
                    images: details.content.pictures,
                    count: details.content.pictureCount,
                    availableWidth: contentWidth
                )
                contentHeight +=
                    8
                    + pictureLayout.size.height
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
        width: CGFloat,
        textRenderer: NativePlaybackCommentTextRenderer? = nil,
        textScope: NativePlaybackCommentTextScope? = nil
    ) -> CGFloat {
        guard case .available(let details) = thread.root.payload,
            details.replyCount > 0
        else { return 0 }
        let innerWidth = max(60, width - replyPanelPadding * 2)
        var height = replyPanelPadding
        if let replyState, replyState.isExpanded {
            height += 20 + 10
            for (index, reply) in replyState.replies.enumerated() {
                height += comment(
                    reply,
                    width: innerWidth,
                    isReply: true,
                    textRenderer: textRenderer,
                    textScope: textScope
                )
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
                height += comment(
                    reply,
                    width: innerWidth,
                    isReply: true,
                    textRenderer: textRenderer,
                    textScope: textScope
                )
                if index < replies.count - 1 { height += 8 }
            }
            if !replies.isEmpty { height += 9 }
            height += 24
        }
        return ceil(height + replyPanelPadding)
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
        textRenderer: NativePlaybackCommentTextRenderer,
        avatarLoader: NativePlaybackCommentAvatarLoader,
        pictureLoader: NativePlaybackCommentPictureLoader,
        onTextLayoutChange: @escaping () -> Void,
        onExpand: @escaping () -> Void,
        onCollapse: @escaping () -> Void,
        onPrevious: @escaping () -> Void,
        onNext: @escaping () -> Void,
        onRetry: @escaping () -> Void,
        onOpenLink: @escaping (CommentLinkTarget) -> Void,
        onOpenPictures: @escaping (NativePlaybackCommentPictureGallery) -> Void
    ) {
        representedObject = presentation
        contentView.configure(
            presentation: presentation,
            textRenderer: textRenderer,
            avatarLoader: avatarLoader,
            pictureLoader: pictureLoader,
            onTextLayoutChange: onTextLayoutChange,
            onExpand: onExpand,
            onCollapse: onCollapse,
            onPrevious: onPrevious,
            onNext: onNext,
            onRetry: onRetry,
            onOpenLink: onOpenLink,
            onOpenPictures: onOpenPictures
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
    nonisolated override var isFlipped: Bool { true }
    private let rootRow = NativePlaybackCommentRowView()
    private let repliesPanel = NativePlaybackCommentRepliesPanelView()
    private let separator = NSBox()
    private var presentation: NativePlaybackCommentThreadPresentation?
    private var textRenderer: NativePlaybackCommentTextRenderer?

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
        textRenderer: NativePlaybackCommentTextRenderer,
        avatarLoader: NativePlaybackCommentAvatarLoader,
        pictureLoader: NativePlaybackCommentPictureLoader,
        onTextLayoutChange: @escaping () -> Void,
        onExpand: @escaping () -> Void,
        onCollapse: @escaping () -> Void,
        onPrevious: @escaping () -> Void,
        onNext: @escaping () -> Void,
        onRetry: @escaping () -> Void,
        onOpenLink: @escaping (CommentLinkTarget) -> Void,
        onOpenPictures: @escaping (NativePlaybackCommentPictureGallery) -> Void
    ) {
        self.presentation = presentation
        self.textRenderer = textRenderer
        let textScope = presentation.textScope
        rootRow.configure(
            comment: presentation.thread.root,
            isReply: false,
            textRenderer: textRenderer,
            avatarLoader: avatarLoader,
            pictureLoader: pictureLoader,
            textScope: textScope,
            onTextLayoutChange: onTextLayoutChange,
            onOpenLink: onOpenLink,
            onOpenPictures: onOpenPictures
        )
        repliesPanel.configure(
            thread: presentation.thread,
            replyState: presentation.replyState,
            textRenderer: textRenderer,
            avatarLoader: avatarLoader,
            pictureLoader: pictureLoader,
            textScope: textScope,
            onTextLayoutChange: onTextLayoutChange,
            onExpand: onExpand,
            onCollapse: onCollapse,
            onPrevious: onPrevious,
            onNext: onNext,
            onRetry: onRetry,
            onOpenLink: onOpenLink,
            onOpenPictures: onOpenPictures
        )
        needsLayout = true
    }

    override func layout() {
        super.layout()
        guard let presentation else { return }
        let rootHeight = NativePlaybackCommentsItemMeasurement.comment(
            presentation.thread.root,
            width: bounds.width,
            isReply: false,
            textRenderer: textRenderer,
            textScope: presentation.textScope
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
            width: panelWidth,
            textRenderer: textRenderer,
            textScope: presentation.textScope
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
        rootRow.releaseOffscreenResources()
        repliesPanel.releaseOffscreenResources()
    }

    func reset() {
        presentation = nil
        textRenderer = nil
        rootRow.reset()
        repliesPanel.reset()
    }
}

@MainActor
private final class NativePlaybackCommentRowView: NSView {
    nonisolated override var isFlipped: Bool { true }
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
    private var textRenderer: NativePlaybackCommentTextRenderer?
    private var textScope: NativePlaybackCommentTextScope?

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
            accessibilityDescription: AppStrings.localized("点赞")
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
        textRenderer: NativePlaybackCommentTextRenderer,
        avatarLoader: NativePlaybackCommentAvatarLoader,
        pictureLoader: NativePlaybackCommentPictureLoader,
        textScope: NativePlaybackCommentTextScope,
        onTextLayoutChange: @escaping () -> Void,
        onOpenLink: @escaping (CommentLinkTarget) -> Void,
        onOpenPictures: @escaping (NativePlaybackCommentPictureGallery) -> Void
    ) {
        self.comment = comment
        self.isReply = isReply
        self.textRenderer = textRenderer
        self.textScope = textScope
        bodyText.onOpenLink = onOpenLink
        switch comment.payload {
        case .unavailable(let reason):
            avatar.releaseImage()
            pictures.releaseImages()
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
            avatar.configure(
                author: details.author,
                isReply: isReply,
                loader: avatarLoader
            )
            authorLabel.stringValue = details.author.name
            authorLabel.textColor = Self.authorColor(details.author)
            authorLabel.setAccessibilityLabel(
                Self.authorAccessibility(details.author)
            )
            authorBadges.configure(author: details.author, isReply: isReply)
            bodyText.setContent(
                details.content,
                renderer: textRenderer,
                scope: textScope,
                onLayoutChange: onTextLayoutChange
            )
            pictures.configure(
                images: details.content.pictures,
                count: details.content.pictureCount,
                loader: pictureLoader,
                onOpen: onOpenPictures
            )
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
                textRenderer.flatMap { renderer in
                    textScope.map {
                        renderer.height(
                            details.content,
                            width: contentWidth,
                            scope: $0
                        )
                    }
                }
                    ?? NativePlaybackSidebarTextLayout.height(
                        details.content.message,
                        width: contentWidth,
                        font: .preferredFont(forTextStyle: .body)
                    )
            )
            bodyText.frame = NSRect(x: contentX, y: y, width: contentWidth, height: bodyHeight)
            y += bodyHeight
            if details.content.pictureCount > 0 {
                y += 8
                let pictureLayout = NativePlaybackCommentPictureLayout.make(
                    images: details.content.pictures,
                    count: details.content.pictureCount,
                    availableWidth: contentWidth
                )
                pictures.frame = NSRect(
                    x: contentX,
                    y: y,
                    width: pictureLayout.size.width,
                    height: pictureLayout.size.height
                )
                y += pictureLayout.size.height
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

    func releaseOffscreenResources() {
        bodyText.releaseTextStorage()
        avatar.releaseImage()
        pictures.releaseImages()
    }

    func reset() {
        comment = nil
        textRenderer = nil
        textScope = nil
        avatar.reset()
        bodyText.reset()
        unavailableLabel.stringValue = ""
        authorLabel.stringValue = ""
        authorBadges.reset()
        metadataLabel.stringValue = ""
        likeLabel.stringValue = ""
        provenanceBadges.reset()
        pictures.reset()
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
            .map { AppStrings.localized("IP属地：\($0)") }
        return ListFormatter.localizedString(
            byJoining: [time, location, AppStrings.localized("获赞 \(likes)")]
                .compactMap { $0 }
                .filter { !$0.isEmpty }
        )
    }

    private static func authorAccessibility(_ author: CommentAuthor) -> String {
        var values = [AppStrings.localized("评论者，\(author.name)")]
        switch author.sex {
        case .male: values.append(AppStrings.localized("男性"))
        case .female: values.append(AppStrings.localized("女性"))
        case .unspecified: break
        }
        if let level = author.level { values.append(AppStrings.localized("等级 \(level)")) }
        if author.isHardcoreMember { values.append(AppStrings.localized("硬核会员")) }
        if author.isVIP { values.append(AppStrings.localized("大会员")) }
        if author.isUploader { values.append(AppStrings.localized("UP 主")) }
        switch author.verification {
        case .personal: values.append(AppStrings.localized("个人认证"))
        case .organization: values.append(AppStrings.localized("机构认证"))
        case nil: break
        }
        return ListFormatter.localizedString(byJoining: values)
    }

    private static func unavailableText(_ reason: CommentUnavailableReason) -> String {
        switch reason {
        case .deleted: AppStrings.localized("该评论已删除")
        case .folded: AppStrings.localized("该评论已折叠")
        case .unavailable, .unknown: AppStrings.localized("该评论暂不可见")
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

    @MainActor
    private struct RenderedSegment {
        let text: String
        let background: NSColor?
        let stroke: NSColor?
        let textLine: CTLine
        let textSize: NSSize
        let baselineFromTop: CGFloat
        let width: CGFloat

        init(_ segment: Segment, font: NSFont) {
            text = segment.text
            background = segment.background
            stroke = segment.stroke
            let attributedText = NSAttributedString(
                string: segment.text,
                attributes: [
                    .font: font,
                    .foregroundColor: segment.foreground,
                ]
            )
            textLine = CTLineCreateWithAttributedString(attributedText)
            textSize = attributedText.size()
            var ascent: CGFloat = 0
            CTLineGetTypographicBounds(textLine, &ascent, nil, nil)
            baselineFromTop = ascent
            width = ceil(textSize.width + segment.horizontalPadding * 2)
        }
    }

    private var segments: [RenderedSegment] = []
    private var cachedPreferredWidth: CGFloat = 0
    private(set) var displayedTexts: [String] = []

    var preferredWidth: CGFloat { cachedPreferredWidth }

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
        let font = NSFont.systemFont(ofSize: isReply ? 9 : 10, weight: .bold)
        segments = Self.segments(for: author).map {
            RenderedSegment($0, font: font)
        }
        cachedPreferredWidth = Self.preferredWidth(segments: segments)
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
        cachedPreferredWidth = 0
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
            let rect = NSRect(
                x: x,
                y: y,
                width: segment.width,
                height: badgeHeight
            )
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
            if let context = NSGraphicsContext.current?.cgContext {
                context.saveGState()
                context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
                context.textPosition = NSPoint(
                    x: rect.midX - segment.textSize.width / 2,
                    y: rect.midY - segment.textSize.height / 2
                        + segment.baselineFromTop
                )
                CTLineDraw(segment.textLine, context)
                context.restoreGState()
            }
            x += segment.width + 5
        }
    }

    private static func preferredWidth(segments: [RenderedSegment]) -> CGFloat {
        guard !segments.isEmpty else { return 0 }
        return segments.reduce(CGFloat.zero) { $0 + $1.width }
            + CGFloat(max(0, segments.count - 1)) * 5
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

    @MainActor
    private struct RenderedSegment {
        let text: String
        let background: NSColor
        let attributedText: NSAttributedString
        let textSize: NSSize
        let width: CGFloat

        init(text: String, foreground: NSColor, background: NSColor) {
            self.text = text
            self.background = background
            attributedText = NSAttributedString(
                string: text,
                attributes: [
                    .font: NativePlaybackCommentProvenanceBadgesView.font,
                    .foregroundColor: foreground,
                ]
            )
            textSize = attributedText.size()
            width = ceil(textSize.width) + 14
        }
    }

    private static let font = NSFont.systemFont(
        ofSize: NSFont.preferredFont(forTextStyle: .caption2).pointSize,
        weight: .semibold
    )
    private static let pinnedSegment = RenderedSegment(
        text: AppStrings.localized("置顶"),
        foreground: .systemPink,
        background: NSColor.systemPink.withAlphaComponent(0.14)
    )
    private static let uploaderLikedSegment = RenderedSegment(
        text: AppStrings.localized("UP 主觉得很赞"),
        foreground: .secondaryLabelColor,
        background: NSColor.secondaryLabelColor.withAlphaComponent(0.12)
    )
    private var segments: [RenderedSegment] = []
    private(set) var displayedTexts: [String] = []

    func configure(_ provenance: [CommentProvenance]) {
        var result: [RenderedSegment] = []
        if provenance.contains(.adminPinned) || provenance.contains(.uploaderPinned) {
            result.append(Self.pinnedSegment)
        }
        if provenance.contains(.uploaderLiked) {
            result.append(Self.uploaderLikedSegment)
        }
        segments = result
        displayedTexts = result.map(\.text)
        isHidden = result.isEmpty
        setAccessibilityElement(!result.isEmpty)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(
            result.isEmpty
                ? nil : ListFormatter.localizedString(byJoining: displayedTexts)
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
            let rect = NSRect(
                x: x,
                y: y,
                width: segment.width,
                height: height
            )
            segment.background.setFill()
            NSBezierPath(
                roundedRect: rect,
                xRadius: height / 2,
                yRadius: height / 2
            ).fill()
            segment.attributedText.draw(
                at: NSPoint(
                    x: rect.midX - segment.textSize.width / 2,
                    y: rect.midY - segment.textSize.height / 2
                )
            )
            x += segment.width + 6
        }
    }
}

@MainActor
private final class NativePlaybackCommentTextView: NSTextView, NSTextViewDelegate {
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

enum NativePlaybackCommentImageTransition {
    static let duration: CFTimeInterval = 0.15

    static func shouldAnimate(loadOrigin: NativeVideoImageLoadOrigin) -> Bool {
        loadOrigin.shouldAnimate
    }
}

@MainActor
private final class NativePlaybackCommentAvatarView: NSView {
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
                        animated: NativePlaybackCommentImageTransition.shouldAnimate(
                            loadOrigin: result.origin
                        )
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
private final class NativePlaybackCommentPicturesView: NSView {
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
                animated: NativePlaybackCommentImageTransition.shouldAnimate(
                    loadOrigin: result.origin
                )
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

@MainActor
private final class NativePlaybackCommentRepliesPanelView: NSView {
    nonisolated override var isFlipped: Bool { true }
    private let headerLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let expandButton = NSButton(title: "", target: nil, action: nil)
    private let collapseButton = NSButton(
        title: AppStrings.localized("收起"),
        target: nil,
        action: nil
    )
    private let retryButton = NSButton(title: AppStrings.localized("重试"), target: nil, action: nil)
    private let previousButton = NSButton(
        title: AppStrings.localized("上一页"),
        target: nil,
        action: nil
    )
    private let pageLabel = NSTextField(labelWithString: "")
    private let nextButton = NSButton(title: AppStrings.localized("下一页"), target: nil, action: nil)
    private var replyRows: [NativePlaybackCommentRowView] = []
    private var thread: CommentThread?
    private var replyState: PlaybackCommentReplyState?
    private var textRenderer: NativePlaybackCommentTextRenderer?
    private var textScope: NativePlaybackCommentTextScope?
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
            accessibilityDescription: AppStrings.localized("展开")
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
        textRenderer: NativePlaybackCommentTextRenderer,
        avatarLoader: NativePlaybackCommentAvatarLoader,
        pictureLoader: NativePlaybackCommentPictureLoader,
        textScope: NativePlaybackCommentTextScope,
        onTextLayoutChange: @escaping () -> Void,
        onExpand: @escaping () -> Void,
        onCollapse: @escaping () -> Void,
        onPrevious: @escaping () -> Void,
        onNext: @escaping () -> Void,
        onRetry: @escaping () -> Void,
        onOpenLink: @escaping (CommentLinkTarget) -> Void,
        onOpenPictures: @escaping (NativePlaybackCommentPictureGallery) -> Void
    ) {
        resetRows()
        self.thread = thread
        self.replyState = replyState
        self.textRenderer = textRenderer
        self.textScope = textScope
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
                textRenderer: textRenderer,
                avatarLoader: avatarLoader,
                pictureLoader: pictureLoader,
                textScope: textScope,
                onTextLayoutChange: onTextLayoutChange,
                onOpenLink: onOpenLink,
                onOpenPictures: onOpenPictures
            )
            addSubview(row)
            replyRows.append(row)
        }
        headerLabel.isHidden = !expanded
        collapseButton.isHidden = !expanded
        expandButton.isHidden = expanded
        retryButton.isHidden = true
        statusLabel.isHidden = true
        previousButton.isHidden = true
        pageLabel.isHidden = true
        nextButton.isHidden = true
        if expanded {
            let total = replyState?.totalCount ?? 0
            headerLabel.stringValue =
                AppStrings.localized(
                    "共 \(CommentPresentationFormatting.compactCount(total > 0 ? total : details.replyCount)) 条回复"
                )
            if replyState?.isLoading == true {
                statusLabel.stringValue = AppStrings.localized("回复加载中…")
                statusLabel.isHidden = false
            } else if replyState?.error != nil {
                statusLabel.stringValue = AppStrings.localized("回复加载失败")
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
                    AppStrings.localized("第 \(replyState.pageNumber) 页，共 \(pageCount) 页")
                )
            }
        } else {
            if expandButton.isHidden {
                expandButton.title = ""
                expandButton.setAccessibilityHelp(nil)
            } else {
                let count = CommentPresentationFormatting.compactCount(details.replyCount)
                expandButton.title = AppStrings.localized("共 \(count) 条回复")
                expandButton.setAccessibilityHelp(AppStrings.localized("展开楼中楼，每页显示十条回复"))
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
                isReply: true,
                textRenderer: textRenderer,
                textScope: textScope
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

    func releaseOffscreenResources() {
        for row in replyRows { row.releaseOffscreenResources() }
    }

    func reset() {
        resetRows()
        thread = nil
        replyState = nil
        textRenderer = nil
        textScope = nil
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
            row.releaseOffscreenResources()
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
