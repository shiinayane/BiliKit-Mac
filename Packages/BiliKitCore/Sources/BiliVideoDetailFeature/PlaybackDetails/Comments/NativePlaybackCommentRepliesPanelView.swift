import AppKit
import BiliApplication
import BiliModels

/// 楼中楼面板：未展开时显示最多两条预览回复与“共 N 条回复”，展开后显示当前页回复与页码条、加载与重试。
///
/// 看对话时原地换成那串对话：顶部「返回全部回复」，底部「加载更多」，回复行不再提供「查看对话」。
///
/// 每次配置都按回复重建行视图（`resetRows` 先移除旧行）；回复状态与动作回调由条目传入，分页请求归 ViewModel。
/// 同一楼原地重配时，之前没显示过的回复行淡入（见 `newlyShownReplyIDs`），展开、翻页、进出对话与加载更多因此
/// 都有过渡；收起后显示的预览不在原页里时同样淡入。行高不做动画，变化即时完成。控制器只对可见的楼原地重配，
/// 复用前的 `reset` 清掉记录，滚动进来的行不淡入。
/// 属于播放详情区的原生 item，用 AppKit 的理由见 ARCHITECTURE「原生 AppKit 集合视图」的播放详情区一条。
@MainActor
final class NativePlaybackCommentRepliesPanelView: NSView {
    nonisolated override var isFlipped: Bool { true }
    private let headerLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let expandButton = NSButton(title: "", target: nil, action: nil)
    private let collapseButton = NSButton(
        title: VideoDetailFeatureStrings.localized("收起"),
        target: nil,
        action: nil
    )
    private let retryButton = NSButton(
        title: VideoDetailFeatureStrings.localized("重试"),
        target: nil,
        action: nil
    )
    private let pager = NativePlaybackCommentReplyPager()
    private let backButton = NSButton(
        title: VideoDetailFeatureStrings.localized("返回全部回复"),
        target: nil,
        action: nil
    )
    private let loadMoreButton = NSButton(
        title: VideoDetailFeatureStrings.localized("加载更多"),
        target: nil,
        action: nil
    )
    private var replyRows: [NativePlaybackCommentRowView] = []
    /// 上一次配置显示的是哪一楼的哪些回复；只用来判断这次哪些行是新出现的。
    private var shownRootID: CommentID?
    private var shownReplyIDs: Set<CommentID> = []
    private var thread: CommentThread?
    private var replyState: PlaybackCommentReplyState?
    private var textRenderer: NativePlaybackCommentTextRenderer?
    private var textScope: NativePlaybackCommentTextScope?
    private var onExpand: (() -> Void)?
    private var onCollapse: (() -> Void)?
    private var onShowPage: ((Int) -> Void)?
    private var onShowDialog: ((BiliModels.Comment) -> Void)?
    private var onLoadMoreDialog: (() -> Void)?
    private var onCloseDialog: (() -> Void)?
    private var onRetry: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 9
        headerLabel.font = .preferredFont(forTextStyle: .callout)
        headerLabel.textColor = .secondaryLabelColor
        statusLabel.font = .preferredFont(forTextStyle: .callout)
        statusLabel.textColor = .secondaryLabelColor
        for button in [expandButton, collapseButton, retryButton, backButton, loadMoreButton] {
            button.bezelStyle = .rounded
            button.controlSize = .small
        }
        expandButton.isBordered = false
        expandButton.contentTintColor = .controlAccentColor
        expandButton.alignment = .left
        expandButton.image = NSImage(
            systemSymbolName: "chevron.down",
            accessibilityDescription: VideoDetailFeatureStrings.localized("展开")
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
        for button in [backButton, loadMoreButton] {
            button.isBordered = false
            button.contentTintColor = .controlAccentColor
            button.alignment = .left
        }
        backButton.image = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: nil)
        backButton.imagePosition = .imageLeading
        backButton.imageScaling = .scaleProportionallyDown
        backButton.target = self
        backButton.action = #selector(closeDialog)
        loadMoreButton.target = self
        loadMoreButton.action = #selector(loadMoreDialog)
        for subview in [
            headerLabel,
            statusLabel,
            expandButton,
            collapseButton,
            retryButton,
            pager,
            backButton,
            loadMoreButton
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
        onShowPage: @escaping (Int) -> Void,
        onRetry: @escaping () -> Void,
        onShowDialog: @escaping (BiliModels.Comment) -> Void,
        onLoadMoreDialog: @escaping () -> Void,
        onCloseDialog: @escaping () -> Void,
        onOpenLink: @escaping (CommentLinkTarget) -> Void,
        onOpenPictures: @escaping (NativePlaybackCommentPictureGallery) -> Void,
        onOpenAuthorSpace: ((CommentAuthor) -> Void)?
    ) {
        resetRows()
        self.thread = thread
        self.replyState = replyState
        self.textRenderer = textRenderer
        self.textScope = textScope
        self.onExpand = onExpand
        self.onCollapse = onCollapse
        self.onShowPage = onShowPage
        self.onRetry = onRetry
        self.onShowDialog = onShowDialog
        self.onLoadMoreDialog = onLoadMoreDialog
        self.onCloseDialog = onCloseDialog
        guard case .available(let details) = thread.root.payload,
            details.replyCount > 0
        else {
            isHidden = true
            shownRootID = thread.id
            shownReplyIDs = []
            return
        }
        isHidden = false
        let expanded = replyState?.isExpanded == true
        let dialog = expanded ? replyState?.dialog : nil
        let replies =
            expanded
            ? replyState?.shownReplies ?? []
            : Array(thread.replyPreview.prefix(2))
        // 「查看对话」只在翻页列表里提供，预览与对话里不再进入另一串对话。翻页加载中原页的回复还在，入口也保留，
        // 不随点下一页先消失；这时点它会放弃那次翻页（见 `PlaybackCommentsViewModel.showDialog`）。
        let offersDialog = expanded && dialog == nil
        let fadingReplyIDs = Self.newlyShownReplyIDs(
            previousRootID: shownRootID,
            previousReplyIDs: shownReplyIDs,
            rootID: thread.id,
            replyIDs: replies.map(\.id)
        )
        shownRootID = thread.id
        shownReplyIDs = Set(replies.map(\.id))
        for reply in replies {
            let row = NativePlaybackCommentRowView()
            // 面板虽是 layer-backed，子视图的图层要到上屏绘制时才建；淡入要在加入时就挂上动画，所以行自己要图层。
            row.wantsLayer = true
            row.configure(
                comment: reply,
                isReply: true,
                textRenderer: textRenderer,
                avatarLoader: avatarLoader,
                pictureLoader: pictureLoader,
                textScope: textScope,
                onTextLayoutChange: onTextLayoutChange,
                onOpenLink: onOpenLink,
                onOpenPictures: onOpenPictures,
                onOpenAuthorSpace: onOpenAuthorSpace,
                onViewDialog: offersDialog && reply.isReplyInDialog
                    ? { [weak self] in self?.onShowDialog?(reply) }
                    : nil
            )
            addSubview(row)
            replyRows.append(row)
            if fadingReplyIDs.contains(reply.id) {
                NativePlaybackDetailsFade.fadeIn(row)
            }
        }
        headerLabel.isHidden = !expanded || dialog != nil
        backButton.isHidden = dialog == nil
        collapseButton.isHidden = !expanded
        expandButton.isHidden = expanded
        retryButton.isHidden = true
        statusLabel.isHidden = true
        pager.isHidden = true
        loadMoreButton.isHidden = true
        if expanded, let replyState {
            let total = replyState.totalCount
            headerLabel.stringValue =
                VideoDetailFeatureStrings.localized(
                    "共 \(CommentPresentationFormatting.compactCount(total > 0 ? total : details.replyCount)) 条回复"
                )
            switch NativePlaybackCommentRepliesFooter(replyState) {
            case .loading:
                statusLabel.stringValue = VideoDetailFeatureStrings.localized("回复加载中…")
                statusLabel.isHidden = false
            case .emptyDialog:
                statusLabel.stringValue = VideoDetailFeatureStrings.localized(
                    "这串对话暂时没有可显示的回复"
                )
                statusLabel.isHidden = false
            case .failed(let error):
                statusLabel.stringValue =
                    error.isRetryable
                    ? VideoDetailFeatureStrings.localized("回复加载失败") : error.nonRetryableDescription
                statusLabel.isHidden = false
                retryButton.isHidden = !error.isRetryable
            case .loadMoreDialog:
                loadMoreButton.isHidden = false
            case .none:
                break
            case .pager:
                pager.isHidden = false
                pager.configure(
                    currentPage: replyState.pageNumber,
                    pageCount: NativePlaybackCommentReplyPager.pageCount(
                        for: replyState,
                        replyCount: details.replyCount
                    ),
                    onShowPage: { [weak self] in self?.onShowPage?($0) }
                )
            }
        } else {
            if expandButton.isHidden {
                expandButton.title = ""
                expandButton.setAccessibilityHelp(nil)
            } else {
                let count = CommentPresentationFormatting.compactCount(details.replyCount)
                expandButton.title = VideoDetailFeatureStrings.localized("共 \(count) 条回复")
                expandButton.setAccessibilityHelp(
                    VideoDetailFeatureStrings.localized("展开楼中楼，每页显示十条回复")
                )
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
            backButton.frame = NSRect(
                x: padding,
                y: y - 2,
                width: min(max(1, width - 62), ceil(backButton.fittingSize.width)),
                height: 24
            )
            collapseButton.frame = NSRect(
                x: max(padding, bounds.width - padding - 54),
                y: y - 2,
                width: 54,
                height: 24
            )
            y += NativePlaybackCommentsItemMeasurement.replyHeaderRowHeight
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
            y += height + NativePlaybackCommentsItemMeasurement.replyRowSpacing
        }
        if !replyRows.isEmpty { y -= NativePlaybackCommentsItemMeasurement.replyRowSpacing }
        if expanded, let replyState {
            switch NativePlaybackCommentRepliesFooter(replyState) {
            case .loading, .emptyDialog:
                statusLabel.frame = NSRect(
                    x: padding,
                    y: y,
                    width: width,
                    height: NativePlaybackCommentsItemMeasurement.replyStatusHeight
                )
            case .failed:
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
            case .pager:
                if !replyRows.isEmpty { y += NativePlaybackCommentsItemMeasurement.replyFooterGap }
                pager.frame = NSRect(
                    x: padding,
                    y: y,
                    width: width,
                    height: NativePlaybackCommentsItemMeasurement.replyPagerHeight
                )
            case .loadMoreDialog:
                if !replyRows.isEmpty { y += NativePlaybackCommentsItemMeasurement.replyFooterGap }
                loadMoreButton.frame = NSRect(
                    x: padding,
                    y: y,
                    width: min(width, ceil(loadMoreButton.fittingSize.width)),
                    height: NativePlaybackCommentsItemMeasurement.dialogLoadMoreHeight
                )
            case .none:
                break
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
        // 复用后的下一次配置按首次显示处理，不淡入。
        shownRootID = nil
        shownReplyIDs = []
        thread = nil
        replyState = nil
        textRenderer = nil
        textScope = nil
        onExpand = nil
        onCollapse = nil
        onShowPage = nil
        pager.reset()
        onRetry = nil
        onShowDialog = nil
        onLoadMoreDialog = nil
        onCloseDialog = nil
        headerLabel.stringValue = ""
        statusLabel.stringValue = ""
    }

    /// 同一楼原地重配时之前没显示过的回复；换了一楼或刚复用（`previousRootID` 为 nil）时为空，不淡入。
    ///
    /// 只看回复身份：表情、头像到达引起的重配不换回复，不会淡入；加载更多只淡入新接上的几条。
    nonisolated static func newlyShownReplyIDs(
        previousRootID: CommentID?,
        previousReplyIDs: Set<CommentID>,
        rootID: CommentID,
        replyIDs: [CommentID]
    ) -> Set<CommentID> {
        guard previousRootID == rootID else { return [] }
        return Set(replyIDs).subtracting(previousReplyIDs)
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
    /// 看对话时重试的是对话的这一页，否则是楼中楼的这一页。
    @objc private func retry() {
        if replyState?.dialog != nil {
            onLoadMoreDialog?()
        } else {
            onRetry?()
        }
    }
    @objc private func loadMoreDialog() { onLoadMoreDialog?() }
    @objc private func closeDialog() { onCloseDialog?() }
}
