import AppKit
import BiliBrowseFeature
import BiliModels

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
        metadataLabel.textColor = .secondaryLabelColor
        metadataLabel.lineBreakMode = .byTruncatingTail
        likeImage.image = NSImage(
            systemSymbolName: "hand.thumbsup",
            accessibilityDescription: AppStrings.localized("点赞")
        )
        likeImage.symbolConfiguration = NSImage.SymbolConfiguration(
            pointSize: 12,
            weight: .regular
        )
        likeImage.contentTintColor = .secondaryLabelColor
        likeImage.imageScaling = .scaleProportionallyDown
        likeImage.setAccessibilityElement(false)
        likeLabel.font = .preferredFont(forTextStyle: .callout)
        likeLabel.textColor = .secondaryLabelColor
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
            unavailableLabel
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
            let geometry = NativePlaybackCommentRowGeometry(
                details: details,
                width: bounds.width,
                isReply: isReply,
                textRenderer: textRenderer,
                textScope: textScope
            )
            avatar.frame = geometry.avatarFrame
            authorLabel.frame = geometry.authorFrame
            authorBadges.frame = geometry.badgesFrame
            bodyText.frame = geometry.bodyFrame
            pictures.frame = geometry.picturesFrame
            let y = geometry.footerY
            let lineHeight = NativePlaybackCommentRowGeometry.lineHeight
            let likeWidth = ceil(likeLabel.intrinsicContentSize.width) + 3
            let trailingInset: CGFloat = 2
            likeLabel.frame = NSRect(
                x: max(geometry.contentX, bounds.width - trailingInset - likeWidth),
                y: y,
                width: likeWidth,
                height: lineHeight
            )
            likeImage.frame = NSRect(
                x: max(geometry.contentX, likeLabel.frame.minX - 18),
                y: y + 2,
                width: 14,
                height: 14
            )
            metadataLabel.frame = NSRect(
                x: geometry.contentX,
                y: y,
                width: max(1, likeImage.frame.minX - geometry.contentX - 6),
                height: lineHeight
            )
            provenanceBadges.frame = geometry.provenanceFrame
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
            nextButton
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
            nextButton
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
            case .available = thread.root.payload
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
