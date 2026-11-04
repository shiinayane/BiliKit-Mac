import AppKit
import BiliApplication
import BiliModels
import BiliUI

/// 一条评论（根评论或回复）：头像、作者与标记、正文、图片、时间与属地、点赞与来源标记；评论不可见时只显示说明。
///
/// 楼中楼里回复别人的回复在点赞左侧多一个「查看对话」，由面板传入 `onViewDialog` 决定是否出现；它与时间同在一行，
/// 不改变行高。
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
    private let metadataLabel = NSTextField(labelWithString: "")
    private let likeImage = NSImageView()
    private let likeLabel = NSTextField(labelWithString: "")
    private let dialogButton = NSButton(
        title: VideoDetailFeatureStrings.localized("查看对话"),
        target: nil,
        action: nil
    )
    private var onViewDialog: (() -> Void)?
    private let provenanceBadges = NativePlaybackCommentProvenanceBadgesView()
    private let unavailableLabel = NSTextField(labelWithString: "")
    private var comment: BiliModels.Comment?
    private var isReply = false
    private var textRenderer: NativePlaybackCommentTextRenderer?
    private var textScope: NativePlaybackCommentTextScope?
    private let authorEntry = NativePlaybackCommentAuthorEntry()

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
            accessibilityDescription: VideoDetailFeatureStrings.localized("点赞")
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
        dialogButton.isBordered = false
        dialogButton.controlSize = .small
        dialogButton.font = .preferredFont(forTextStyle: .callout)
        dialogButton.contentTintColor = .controlAccentColor
        dialogButton.target = self
        dialogButton.action = #selector(viewDialog)
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
            likeImage,
            likeLabel,
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
        onViewDialog: (() -> Void)? = nil
    ) {
        self.comment = comment
        self.onViewDialog = onViewDialog
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
            likeImage.isHidden = false
            likeLabel.isHidden = false
            dialogButton.isHidden = onViewDialog == nil
            unavailableLabel.isHidden = true
            avatar.configure(
                author: details.author,
                isReply: isReply,
                loader: avatarLoader
            )
            authorLabel.stringValue = details.author.name
            authorLabel.textColor = NativeMemberNameColor.color(isVIP: details.author.isVIP)
            authorLabel.setAccessibilityLabel(
                Self.authorAccessibility(details.author)
            )
            authorEntry.configure(author: details.author, onOpen: onOpenAuthorSpace)
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
            var metadataTrailing = likeImage.frame.minX - 6
            if !dialogButton.isHidden {
                let dialogWidth = ceil(dialogButton.fittingSize.width)
                dialogButton.frame = NSRect(
                    x: max(geometry.contentX, metadataTrailing - dialogWidth),
                    y: y,
                    width: dialogWidth,
                    height: lineHeight
                )
                metadataTrailing = dialogButton.frame.minX - 6
            }
            metadataLabel.frame = NSRect(
                x: geometry.contentX,
                y: y,
                width: max(1, metadataTrailing - geometry.contentX),
                height: lineHeight
            )
            provenanceBadges.frame = geometry.provenanceFrame
        }
        authorEntry.updateLayout()
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
        onViewDialog = nil
        dialogButton.isHidden = true
        provenanceBadges.reset()
        pictures.reset()
        authorEntry.configure(author: nil, onOpen: nil)
    }

    @objc private func viewDialog() { onViewDialog?() }

    private static func metadataLeading(_ details: CommentDetails) -> String {
        let time = VideoMetadataFormatting.commentDate(details.createdAt)
        let location = details.location.flatMap { $0.isEmpty ? nil : $0 }
        return [time, location].compactMap { $0 }.joined(separator: "  ·  ")
    }

    private static func metadataAccessibility(_ details: CommentDetails) -> String {
        let time = VideoMetadataFormatting.commentDate(details.createdAt)
        let likes = CommentPresentationFormatting.compactCount(details.likeCount)
        let location = details.location.flatMap { $0.isEmpty ? nil : $0 }
            .map { VideoDetailFeatureStrings.localized("IP属地：\($0)") }
        return ListFormatter.localizedString(
            byJoining: [time, location, VideoDetailFeatureStrings.localized("获赞 \(likes)")]
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
