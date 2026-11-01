import AppKit
import BiliApplication
import BiliModels

/// 评论条目的尺寸常量与高度测量，是评论行布局的唯一几何来源：条目的 `layout()` 与控制器的行高测量都经它计算。
@MainActor
enum NativePlaybackCommentsItemMeasurement {
    static let headerHeight: CGFloat = 42
    static let rootAvatarSize: CGFloat = 32
    static let replyAvatarSize: CGFloat = 22
    static let contentGap: CGFloat = 10
    static let rootVerticalInset: CGFloat = 12
    static let replyPanelLeading: CGFloat = 42
    static let replyPanelPadding: CGFloat = 9
    /// 根评论行与楼中楼面板之间的间距。
    static let rootPanelGap: CGFloat = 10
    /// 展开后底部页码条的行高，容得下 `NativePlaybackCommentReplyPager.itemSize` 的按钮。
    static let replyPagerHeight: CGFloat = 26
    /// 展开后顶部一行（“共 N 条回复”与收起）连同它下面的间距。
    static let replyHeaderRowHeight: CGFloat = 30
    /// 楼中楼里相邻两条回复之间的间距。
    static let replyRowSpacing: CGFloat = 8
    /// 最后一条回复与底部页码条之间的间距。
    static let replyFooterGap: CGFloat = 10
    /// 看对话时底部「加载更多」按钮的行高。
    static let dialogLoadMoreHeight: CGFloat = 24
    /// 加载中或失败说明一行的高度。
    static let replyStatusHeight: CGFloat = 32
    /// 状态行放标题与两行说明（暂无评论、已关闭、缺少评论标识）的高度。
    ///
    /// 加载中的转圈居中在同样高的行里，加载结束切到这些说明时行高不变、内容不位移。
    static let stateMessageHeight: CGFloat = 112
    /// 页脚“加载更多”按钮行的高度。
    ///
    /// 追加加载中的转圈居中在同样高的行里：点按钮到下一页到达之间文档高度不变，阅读位置不跳。
    static let footerLoadMoreHeight: CGFloat = 40

    static func state(
        _ kind: NativePlaybackCommentsStateKind,
        width _: CGFloat
    ) -> CGFloat {
        switch kind {
        case .loading, .idle, .empty, .closed: stateMessageHeight
        case .failed: 48
        }
    }

    static func footer(_ footer: NativePlaybackCommentsFooter) -> CGFloat {
        switch footer {
        case .loading, .loadMore: footerLoadMoreHeight
        case .failed, .stopped: 48
        case .end: 32
        }
    }

    static func thread(
        _ presentation: NativePlaybackCommentThreadPresentation,
        width: CGFloat,
        textRenderer: NativePlaybackCommentTextRenderer? = nil
    ) -> CGFloat {
        let panelHeight = repliesPanel(
            thread: presentation.thread,
            replyState: presentation.replyState,
            width: repliesPanelWidth(threadWidth: width),
            textRenderer: textRenderer,
            textScope: presentation.textScope
        )
        let rootBottom = rootRowBottom(presentation, width: width, textRenderer: textRenderer)
        return ceil(
            rootBottom + (panelHeight > 0 ? rootPanelGap + panelHeight : 0) + rootVerticalInset
        )
    }

    /// 根评论行底边在条目里的纵坐标。
    static func rootRowBottom(
        _ presentation: NativePlaybackCommentThreadPresentation,
        width: CGFloat,
        textRenderer: NativePlaybackCommentTextRenderer? = nil
    ) -> CGFloat {
        rootVerticalInset
            + comment(
                presentation.thread.root,
                width: width,
                isReply: false,
                textRenderer: textRenderer,
                textScope: presentation.textScope
            )
    }

    /// 楼中楼面板顶边在条目里的纵坐标；条目布局与详情区翻页后的定位共用。
    static func repliesPanelTop(
        _ presentation: NativePlaybackCommentThreadPresentation,
        width: CGFloat,
        textRenderer: NativePlaybackCommentTextRenderer? = nil
    ) -> CGFloat {
        rootRowBottom(presentation, width: width, textRenderer: textRenderer) + rootPanelGap
    }

    static func repliesPanelWidth(threadWidth: CGFloat) -> CGFloat {
        max(80, threadWidth - replyPanelLeading)
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
            height += replyHeaderRowHeight
            let replies = replyState.shownReplies
            for (index, reply) in replies.enumerated() {
                height += comment(
                    reply,
                    width: innerWidth,
                    isReply: true,
                    textRenderer: textRenderer,
                    textScope: textScope
                )
                if index < replies.count - 1 { height += replyRowSpacing }
            }
            switch NativePlaybackCommentRepliesFooter(replyState) {
            case .loading, .failed, .emptyDialog:
                height += replyStatusHeight
            case .pager:
                if !replies.isEmpty { height += replyFooterGap }
                height += replyPagerHeight
            case .loadMoreDialog:
                if !replies.isEmpty { height += replyFooterGap }
                height += dialogLoadMoreHeight
            case .none:
                break
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
                if index < replies.count - 1 { height += replyRowSpacing }
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
        /// 只为缩短本初始化里的常量引用。
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
                ?? NativePlaybackDetailsTextLayout.height(
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

/// 评论图片在列表格子与预览中的共同外观。
enum NativePlaybackCommentImageStyle {
    static let cornerRadius: CGFloat = 6
    /// 动图角标：距格子右上角的边距、左右内边距、字号与圆角。
    static let animationBadgeInset: CGFloat = 4
    static let animationBadgePadding: CGFloat = 4
    static let animationBadgeFontSize: CGFloat = 9
    static let animationBadgeCornerRadius: CGFloat = 3
}

/// 楼中楼面板展开后底部一行显示什么；面板配置、布局与行高测量共用这一份判断。
enum NativePlaybackCommentRepliesFooter: Equatable {
    /// 这一页或对话的这一页正在加载，且提示已经露出（见 `PlaybackCommentReplyState.isLoadingStatusVisible`）；
    /// 露出之前保留原来的页码条或「加载更多」。
    case loading
    /// 加载失败；可重试时带「重试」。
    case failed(CommentReadError)
    /// 楼中楼页码条。
    case pager
    /// 正在看的对话还有下一页。
    case loadMoreDialog
    /// 对话已到底却没有一条可显示的回复：给一句说明，面板不留空白。
    case emptyDialog
    /// 对话已到底，底部不留行。
    case none

    init(_ state: PlaybackCommentReplyState) {
        if let dialog = state.dialog {
            if dialog.isLoading, state.isLoadingStatusVisible {
                self = .loading
            } else if dialog.isLoading {
                self = .loadMoreDialog
            } else if let error = dialog.error {
                self = .failed(error)
            } else if dialog.isEnd {
                self = dialog.replies.isEmpty ? .emptyDialog : .none
            } else {
                self = .loadMoreDialog
            }
        } else if state.isLoading, state.isLoadingStatusVisible {
            self = .loading
        } else if let error = state.error {
            self = .failed(error)
        } else {
            self = .pager
        }
    }
}
