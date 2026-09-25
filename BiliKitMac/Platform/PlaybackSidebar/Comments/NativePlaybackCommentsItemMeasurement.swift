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
            return NativePlaybackCommentRowGeometry(
                details: details,
                width: width,
                isReply: isReply,
                textRenderer: textRenderer,
                textScope: textScope
            ).height
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

/// 可用评论行的唯一几何来源；`NativePlaybackCommentsItemMeasurement.comment` 的高度与
/// 行视图 `layout()` 共用，缓存高度不会与实际布局漂移。
@MainActor
struct NativePlaybackCommentRowGeometry {
    static let lineHeight: CGFloat = 18
    static let wrappedBadgesY: CGFloat = 20
    static let authorToBodySpacing: CGFloat = 6
    static let bodyToPicturesSpacing: CGFloat = 8
    static let contentToFooterSpacing: CGFloat = 6
    static let footerToProvenanceSpacing: CGFloat = 6
    static let provenanceHeight: CGFloat = 20

    let avatarFrame: NSRect
    let contentX: CGFloat
    let contentWidth: CGFloat
    let authorFrame: NSRect
    let badgesFrame: NSRect
    let bodyFrame: NSRect
    /// 没有图片时为 `.zero`。
    let picturesFrame: NSRect
    /// 元数据与点赞行的顶部位置。
    let footerY: CGFloat
    /// 没有可见来源标记时为 `.zero`。
    let provenanceFrame: NSRect
    let height: CGFloat

    init(
        details: CommentDetails,
        width: CGFloat,
        isReply: Bool,
        textRenderer: NativePlaybackCommentTextRenderer?,
        textScope: NativePlaybackCommentTextScope?
    ) {
        typealias Measurement = NativePlaybackCommentsItemMeasurement
        let avatarSize = isReply ? Measurement.replyAvatarSize : Measurement.rootAvatarSize
        avatarFrame = NSRect(x: 0, y: 0, width: avatarSize, height: avatarSize)
        let contentX = avatarSize + Measurement.contentGap
        let contentWidth = max(60, width - contentX)
        self.contentX = contentX
        self.contentWidth = contentWidth

        let badgesWidth = min(
            NativePlaybackCommentAuthorBadgesView.preferredWidth(
                for: details.author,
                isReply: isReply
            ),
            contentWidth
        )
        let authorTextWidth = Measurement.authorNameTextWidth(
            details.author,
            maximumWidth: contentWidth
        )
        let wrapsBadges =
            badgesWidth > 0
            && authorTextWidth + Measurement.authorBadgeSpacing + badgesWidth > contentWidth
        authorFrame = NSRect(
            x: contentX,
            y: 0,
            width: Measurement.authorNameWidth(details.author, maximumWidth: contentWidth),
            height: Self.lineHeight
        )
        badgesFrame = NSRect(
            x: wrapsBadges
                ? contentX
                : contentX + authorTextWidth
                    + (badgesWidth > 0 ? Measurement.authorBadgeSpacing : 0),
            y: wrapsBadges ? Self.wrappedBadgesY : 0,
            width: badgesWidth,
            height: Self.lineHeight
        )

        var y = (wrapsBadges ? badgesFrame.maxY : Self.lineHeight) + Self.authorToBodySpacing
        let bodyHeight = max(
            Self.lineHeight,
            textRenderer.flatMap { renderer in
                textScope.map {
                    renderer.height(details.content, width: contentWidth, scope: $0)
                }
            }
                ?? NativePlaybackSidebarTextLayout.height(
                    details.content.message,
                    width: contentWidth,
                    font: .preferredFont(forTextStyle: .body)
                )
        )
        bodyFrame = NSRect(x: contentX, y: y, width: contentWidth, height: bodyHeight)
        y += bodyHeight
        if details.content.pictureCount > 0 {
            y += Self.bodyToPicturesSpacing
            let pictureSize = NativePlaybackCommentPictureLayout.make(
                images: details.content.pictures,
                count: details.content.pictureCount,
                availableWidth: contentWidth
            ).size
            picturesFrame = NSRect(
                x: contentX,
                y: y,
                width: pictureSize.width,
                height: pictureSize.height
            )
            y += pictureSize.height
        } else {
            picturesFrame = .zero
        }
        y += Self.contentToFooterSpacing
        footerY = y
        y += Self.lineHeight
        if Measurement.hasVisibleProvenance(details.provenance) {
            y += Self.footerToProvenanceSpacing
            provenanceFrame = NSRect(
                x: contentX,
                y: y,
                width: contentWidth,
                height: Self.provenanceHeight
            )
            y += Self.provenanceHeight
        } else {
            provenanceFrame = .zero
        }
        height = ceil(max(avatarSize, y))
    }
}

enum NativePlaybackCommentImageTransition {
    static let duration: CFTimeInterval = 0.15
}
