import AppKit
import BiliApplication
import BiliModels
import BiliUI

/// 评论行上的写入操作：赞、踩与回复，由侧栏控制器接到评论写入模型。
///
/// 不可用的操作仍显示但禁用、计数照常，与播放页的点赞按钮一致（`NativePlaybackCommentWriteAvailability`）。
struct NativePlaybackCommentRowActions {
    let availability: NativePlaybackCommentWriteAvailability
    let react: (CommentID, CommentReaction) -> Void
    let reply: (BiliModels.Comment) -> Void
}

/// 一条评论（根评论或回复）：头像、作者与标记、正文、图片、时间与属地、赞（带数字）／踩／回复与来源标记；评论不可见时只
/// 显示说明。
///
/// 时间、属地与三个操作排在同一行，参照网页评论区；楼中楼里回复别人的回复在「回复」后面多一个「查看对话」，由面板传入
/// `onViewDialog` 决定是否出现。这一行的节奏与窄行的退让见 `layoutFooter`，不改变行高。
///
/// 正文渲染器与作用域由条目传入，头像与图片的加载由各自的子视图拥有。属于播放侧栏的原生 item，
/// 用 AppKit 的理由见 ARCHITECTURE「原生 AppKit 集合视图」的播放侧栏一条。
@MainActor
final class NativePlaybackCommentRowView: NSView {
    nonisolated override var isFlipped: Bool { true }
    private let avatar = NativePlaybackCommentAvatarView()
    private let authorLabel = NSTextField(labelWithString: "")
    private let authorBadges = NativePlaybackCommentAuthorBadgesView()
    private let bodyText = NativePlaybackCommentTextView()
    private let pictures = NativePlaybackCommentPicturesView()
    /// 时间；与属地分成两个标签，一行放不下时只截断时间，属地始终完整。
    private let metadataLabel = NSTextField(labelWithString: "")
    private let locationLabel = NSTextField(labelWithString: "")
    private let likeButton = NativePlaybackCommentFooterAction(
        font: NativePlaybackCommentRowView.footerFont
    )
    private let dislikeButton = NativePlaybackCommentFooterAction(
        font: NativePlaybackCommentRowView.footerFont
    )
    private let replyButton = NativePlaybackCommentFooterAction(
        font: NativePlaybackCommentRowView.footerFont
    )
    private var actions: NativePlaybackCommentRowActions?
    private let dialogButton = NativePlaybackCommentFooterAction(
        font: NativePlaybackCommentRowView.footerFont
    )
    private var onViewDialog: (() -> Void)?
    private let provenanceBadges = NativePlaybackCommentProvenanceBadgesView()
    private let unavailableLabel = NSTextField(labelWithString: "")
    private var comment: BiliModels.Comment?
    private var isReply = false
    private var textRenderer: NativePlaybackCommentTextRenderer?
    private var textScope: NativePlaybackCommentTextScope?
    /// 正文此刻按哪条评论、哪个渲染作用域排好；同一条、同一作用域再次配置（只有点赞数或赞踩变了，见
    /// `NativePlaybackCommentThreadPresentation.reactionRevision`）时不重新渲染正文。
    ///
    /// 放下离屏资源与复用时清空。
    private var renderedBody: (commentID: CommentID, scope: NativePlaybackCommentTextScope)?
    private let authorEntry = NativePlaybackCommentAuthorEntry()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        authorLabel.font = NativePlaybackCommentsItemMeasurement.authorFont
        authorLabel.maximumNumberOfLines = 1
        authorLabel.lineBreakMode = .byTruncatingTail
        // 元信息比正文小两号，与正文拉开层级。
        let footerFont = Self.footerFont
        metadataLabel.font = footerFont
        metadataLabel.textColor = .secondaryLabelColor
        metadataLabel.lineBreakMode = .byTruncatingTail
        locationLabel.font = footerFont
        locationLabel.textColor = .secondaryLabelColor
        locationLabel.lineBreakMode = .byTruncatingTail
        // 读屏从时间标签读到「时间，IP 属地」，属地标签本身不再单独读一遍。
        locationLabel.setAccessibilityElement(false)
        configureActionCallbacks()
        dialogButton.isHidden = true
        unavailableLabel.font = .preferredFont(forTextStyle: .body)
        unavailableLabel.textColor = .secondaryLabelColor
        for subview in [
            avatar,
            authorLabel,
            authorBadges,
            bodyText,
            pictures,
            metadataLabel,
            locationLabel,
            likeButton,
            dislikeButton,
            replyButton,
            dialogButton,
            provenanceBadges,
            unavailableLabel
        ] {
            addSubview(subview)
        }
        authorEntry.attach(to: self, avatar: avatar, nameLabel: authorLabel)
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// 元信息一行的字体：比正文小两号，时间、属地与各个操作共用。
    private static var footerFont: NSFont { .preferredFont(forTextStyle: .callout) }

    /// 各个操作的固定内容与点按回调；回调读当时的评论与动作，复用行时不必重设。
    private func configureActionCallbacks() {
        replyButton.configure(symbolName: nil, title: VideoDetailFeatureStrings.localized("回复"))
        replyButton.setAccessibilityLabel(VideoDetailFeatureStrings.localized("回复"))
        dialogButton.configure(
            symbolName: nil,
            title: VideoDetailFeatureStrings.localized("查看对话")
        )
        dialogButton.setAccessibilityLabel(VideoDetailFeatureStrings.localized("查看对话"))
        dialogButton.restingColor = .controlAccentColor
        likeButton.onPress = { [weak self] in
            guard let self, let comment = self.comment else { return }
            self.actions?.react(comment.id, .liked)
        }
        dislikeButton.onPress = { [weak self] in
            guard let self, let comment = self.comment else { return }
            self.actions?.react(comment.id, .disliked)
        }
        replyButton.onPress = { [weak self] in
            guard let self, let comment = self.comment else { return }
            self.actions?.reply(comment)
        }
        dialogButton.onPress = { [weak self] in self?.onViewDialog?() }
    }

    func configure(
        comment: BiliModels.Comment,
        isReply: Bool,
        textRenderer: NativePlaybackCommentTextRenderer,
        avatarLoader: NativePlaybackCommentAvatarLoader,
        pictureLoader: NativePlaybackCommentPictureLoader,
        textScope: NativePlaybackCommentTextScope,
        onTextLayoutChange: @escaping () -> Void,
        onOpenLink: @escaping (CommentLinkTarget) -> Void,
        onOpenPictures: @escaping (NativePlaybackCommentPictureGallery) -> Void,
        onOpenAuthorSpace: ((CommentAuthor) -> Void)?,
        onViewDialog: (() -> Void)? = nil,
        actions: NativePlaybackCommentRowActions? = nil
    ) {
        self.comment = comment
        self.onViewDialog = onViewDialog
        self.actions = actions
        self.isReply = isReply
        self.textRenderer = textRenderer
        self.textScope = textScope
        bodyText.onOpenLink = onOpenLink
        switch comment.payload {
        case .unavailable(let reason):
            renderedBody = nil
            avatar.releaseImage()
            pictures.releaseImages()
            avatar.isHidden = true
            authorLabel.isHidden = true
            authorBadges.isHidden = true
            bodyText.isHidden = true
            pictures.isHidden = true
            metadataLabel.isHidden = true
            locationLabel.isHidden = true
            likeButton.isHidden = true
            dislikeButton.isHidden = true
            replyButton.isHidden = true
            provenanceBadges.isHidden = true
            dialogButton.isHidden = true
            unavailableLabel.isHidden = false
            unavailableLabel.stringValue = Self.unavailableText(reason)
            unavailableLabel.setAccessibilityLabel(unavailableLabel.stringValue)
            authorEntry.configure(author: nil, onOpen: nil)
        case .available(let details):
            avatar.isHidden = false
            authorLabel.isHidden = false
            authorBadges.isHidden = false
            bodyText.isHidden = false
            metadataLabel.isHidden = false
            likeButton.isHidden = false
            dislikeButton.isHidden = false
            replyButton.isHidden = actions == nil
            dialogButton.isHidden = onViewDialog == nil
            unavailableLabel.isHidden = true
            avatar.configure(
                author: details.author,
                isReply: isReply,
                loader: avatarLoader
            )
            authorLabel.stringValue = details.author.name
            authorLabel.textColor = NativeMemberNameColor.color(
                isVIP: details.author.isVIP,
                regular: .secondaryLabelColor
            )
            authorLabel.setAccessibilityLabel(
                Self.authorAccessibility(details.author)
            )
            authorEntry.configure(author: details.author, onOpen: onOpenAuthorSpace)
            authorBadges.configure(author: details.author, isReply: isReply)
            if renderedBody?.commentID != comment.id || renderedBody?.scope != textScope {
                bodyText.setContent(
                    details.content,
                    renderer: textRenderer,
                    scope: textScope,
                    onLayoutChange: onTextLayoutChange
                )
                renderedBody = (comment.id, textScope)
            }
            pictures.configure(
                images: details.content.pictures,
                count: details.content.pictureCount,
                loader: pictureLoader,
                onOpen: onOpenPictures
            )
            pictures.isHidden = details.content.pictureCount == 0
            metadataLabel.stringValue = VideoMetadataFormatting.commentDate(details.createdAt)
            let location = details.location.flatMap { $0.isEmpty ? nil : $0 }
            locationLabel.stringValue = location ?? ""
            locationLabel.isHidden = location == nil
            metadataLabel.setAccessibilityLabel(Self.metadataAccessibility(details))
            configureReactions(details)
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
                commentID: comment.id,
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
            layoutFooter(y: geometry.footerY, contentX: geometry.contentX)
            provenanceBadges.frame = geometry.provenanceFrame
        }
        authorEntry.updateLayout()
    }

    func releaseOffscreenResources() {
        renderedBody = nil
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
        renderedBody = nil
        unavailableLabel.stringValue = ""
        authorLabel.stringValue = ""
        authorBadges.reset()
        metadataLabel.stringValue = ""
        locationLabel.stringValue = ""
        likeButton.configure(symbolName: nil, title: "")
        actions = nil
        onViewDialog = nil
        dialogButton.isHidden = true
        provenanceBadges.reset()
        pictures.reset()
        authorEntry.configure(author: nil, onOpen: nil)
    }

    /// 赞（带数字）与踩的图标、颜色与读屏标签；做过的实心并用强调色，与播放页的点赞按钮一致。
    private func configureReactions(_ details: CommentDetails) {
        let liked = details.viewerReaction == .liked
        let disliked = details.viewerReaction == .disliked
        likeButton.configure(
            symbolName: liked ? "hand.thumbsup.fill" : "hand.thumbsup",
            title: details.likeCount > 0
                ? CommentPresentationFormatting.compactCount(details.likeCount) : ""
        )
        likeButton.isActive = liked
        likeButton.setAccessibilityLabel(
            VideoDetailFeatureStrings.localized(
                "点赞，\(CommentPresentationFormatting.compactCount(details.likeCount))"
            )
        )
        likeButton.setAccessibilityValue(
            liked ? VideoDetailFeatureStrings.localized("已点赞") : nil
        )
        dislikeButton.configure(
            symbolName: disliked ? "hand.thumbsdown.fill" : "hand.thumbsdown",
            title: ""
        )
        dislikeButton.isActive = disliked
        dislikeButton.setAccessibilityLabel(VideoDetailFeatureStrings.localized("点踩"))
        dislikeButton.setAccessibilityValue(
            disliked ? VideoDetailFeatureStrings.localized("已点踩") : nil
        )
        let availability = actions?.availability ?? .unavailable
        likeButton.isEnabled = availability.canReact
        dislikeButton.isEnabled = availability.canReact
        replyButton.isEnabled = availability.canReply
    }

    /// 元信息一行：信息组（时间、属地）与操作组（赞、踩、回复、查看对话），不用分隔符，靠留白分出层次。
    ///
    /// 组内间距小于组间距：时间与属地相隔 `footerInfoSpacing`，操作之间 `footerActionSpacing`，两组之间
    /// `footerGroupSpacing`，眼睛先看出两块、再看块里的项。操作的点击区左右各外延操作间距的一半，相邻操作正好相接。
    /// 放不下时依次退让：先把组间距与操作间距缩到各自的最小值，再截断时间，剩不到 `minimumFooterTimeWidth` 时整个不显示
    /// 时间，还放不下才截断属地；各个操作始终完整，最后一个操作的点击区不越出这一行（越出的部分点不到）。标签宽度取
    /// `fittingSize`（`intrinsicContentSize` 不含文本框两侧约 2pt 的内边距，按它排会把日期截掉）；标签与操作的内容都在
    /// 行框里垂直居中，落在同一条中线上。
    private func layoutFooter(y: CGFloat, contentX: CGFloat) {
        typealias Geometry = NativePlaybackCommentRowGeometry
        let height = Geometry.footerHeight
        let buttons = [likeButton, dislikeButton, replyButton, dialogButton].filter { !$0.isHidden }
        let buttonWidths = buttons.map(\.contentWidth)
        let locationWidth = locationLabel.isHidden ? 0 : ceil(locationLabel.fittingSize.width)
        let fullTimeWidth = ceil(metadataLabel.fittingSize.width)
        let available = bounds.width - contentX
        func trailingWidth(group: CGFloat, action: CGFloat) -> CGFloat {
            (locationLabel.isHidden ? 0 : Geometry.footerInfoSpacing + locationWidth)
                + (buttons.isEmpty
                    ? 0
                    : group + buttonWidths.reduce(0, +)
                        + action * CGFloat(buttons.count - 1))
        }
        let fitsRelaxed =
            fullTimeWidth
            + trailingWidth(
                group: Geometry.footerGroupSpacing,
                action: Geometry.footerActionSpacing
            )
            <= available
        let groupSpacing =
            fitsRelaxed ? Geometry.footerGroupSpacing : Geometry.minimumFooterGroupSpacing
        let actionSpacing =
            fitsRelaxed ? Geometry.footerActionSpacing : Geometry.minimumFooterActionSpacing
        let remainingTimeWidth = min(
            fullTimeWidth,
            max(0, available - trailingWidth(group: groupSpacing, action: actionSpacing))
        )
        // 只剩一个省略号的日期没有信息，整个让出来，属地顶到行首。
        let showsTime = remainingTimeWidth >= Geometry.minimumFooterTimeWidth
        let timeWidth = showsTime ? remainingTimeWidth : 0
        // 日期让出来之后仍放不下（很窄的楼中楼里，「查看对话」的译文又长）：最后截断属地，操作始终完整、不越出这一行。
        let actionsWidth =
            buttons.isEmpty
            ? 0
            : groupSpacing + buttonWidths.reduce(0, +) + actionSpacing * CGFloat(buttons.count - 1)
        let shownLocationWidth = min(
            locationWidth,
            max(
                0,
                available - actionsWidth
                    - (showsTime ? timeWidth + Geometry.footerInfoSpacing : 0)
            )
        )
        func centered(_ label: NSTextField, x: CGFloat, width: CGFloat) -> NSRect {
            let labelHeight = min(height, ceil(label.intrinsicContentSize.height))
            return NSRect(
                x: x,
                y: y + floor((height - labelHeight) / 2),
                width: width,
                height: labelHeight
            )
        }
        metadataLabel.frame = centered(metadataLabel, x: contentX, width: timeWidth)
        var x = metadataLabel.frame.maxX
        if !locationLabel.isHidden {
            locationLabel.frame = centered(
                locationLabel,
                x: showsTime ? x + Geometry.footerInfoSpacing : contentX,
                width: shownLocationWidth
            )
            x = locationLabel.frame.maxX
        }
        x += groupSpacing
        let hitPadding = actionSpacing / 2
        for (button, width) in zip(buttons, buttonWidths) {
            button.hitPadding = hitPadding
            // 点击区外延到行外的部分收不到点击，截在行内（内容不受影响）。
            let frameWidth = min(width + hitPadding * 2, bounds.width - (x - hitPadding))
            button.frame = NSRect(
                x: x - hitPadding,
                y: y,
                width: max(width + hitPadding, frameWidth),
                height: height
            )
            x += width + actionSpacing
        }
    }

    private static func metadataAccessibility(_ details: CommentDetails) -> String {
        let time = VideoMetadataFormatting.commentDate(details.createdAt)
        let location = details.location.flatMap { $0.isEmpty ? nil : $0 }
            .map { VideoDetailFeatureStrings.localized("IP属地：\($0)") }
        return ListFormatter.localizedString(
            byJoining: [time, location]
                .compactMap { $0 }
                .filter { !$0.isEmpty }
        )
    }

    private static func authorAccessibility(_ author: CommentAuthor) -> String {
        var values = [VideoDetailFeatureStrings.localized("评论者，\(author.name)")]
        switch author.sex {
        case .male: values.append(VideoDetailFeatureStrings.localized("男性"))
        case .female: values.append(VideoDetailFeatureStrings.localized("女性"))
        case .unspecified: break
        }
        if let level = author.level {
            values.append(VideoDetailFeatureStrings.localized("等级 \(level)"))
        }
        if author.isHardcoreMember { values.append(VideoDetailFeatureStrings.localized("硬核会员")) }
        if author.isVIP { values.append(VideoDetailFeatureStrings.localized("大会员")) }
        if author.isUploader { values.append(VideoDetailFeatureStrings.localized("UP 主")) }
        switch author.verification {
        case .personal: values.append(VideoDetailFeatureStrings.localized("个人认证"))
        case .organization: values.append(VideoDetailFeatureStrings.localized("机构认证"))
        case nil: break
        }
        return ListFormatter.localizedString(byJoining: values)
    }

    private static func unavailableText(_ reason: CommentUnavailableReason) -> String {
        switch reason {
        case .folded: VideoDetailFeatureStrings.localized("该评论已折叠")
        case .unavailable, .unknown: VideoDetailFeatureStrings.localized("该评论暂不可见")
        }
    }
}

extension NativePlaybackCommentRowView {
    /// 楼中楼面板按行里当前的回复测量行高；只读，不暴露可变状态。
    var commentForLayout: BiliModels.Comment? { comment }
}
