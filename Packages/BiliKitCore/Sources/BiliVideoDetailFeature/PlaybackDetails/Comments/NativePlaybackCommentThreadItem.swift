import AppKit
import BiliApplication
import BiliModels

/// 一条根评论及其楼中楼的条目；身份是评论对象加根评论 ID，追加评论时已有的行不重建。
///
/// 各行的图片与正文附件加载由内容视图里的行拥有；复用前复位，控制器在条目离开显示时调用
/// `releaseOffscreenResources` 放下图片、取消在途加载。
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
        onShowPage: @escaping (Int) -> Void,
        onRetry: @escaping () -> Void,
        onShowDialog: @escaping (BiliModels.Comment) -> Void,
        onLoadMoreDialog: @escaping () -> Void,
        onCloseDialog: @escaping () -> Void,
        onOpenLink: @escaping (CommentLinkTarget) -> Void,
        onOpenPictures: @escaping (NativePlaybackCommentPictureGallery) -> Void,
        onOpenAuthorSpace: ((CommentAuthor) -> Void)?
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
            onShowPage: onShowPage,
            onRetry: onRetry,
            onShowDialog: onShowDialog,
            onLoadMoreDialog: onLoadMoreDialog,
            onCloseDialog: onCloseDialog,
            onOpenLink: onOpenLink,
            onOpenPictures: onOpenPictures,
            onOpenAuthorSpace: onOpenAuthorSpace
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

/// 根评论行加楼中楼面板；两者的高度都取自 `NativePlaybackCommentsItemMeasurement`，与行高测量一致。
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
        onShowPage: @escaping (Int) -> Void,
        onRetry: @escaping () -> Void,
        onShowDialog: @escaping (BiliModels.Comment) -> Void,
        onLoadMoreDialog: @escaping () -> Void,
        onCloseDialog: @escaping () -> Void,
        onOpenLink: @escaping (CommentLinkTarget) -> Void,
        onOpenPictures: @escaping (NativePlaybackCommentPictureGallery) -> Void,
        onOpenAuthorSpace: ((CommentAuthor) -> Void)?
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
            onOpenPictures: onOpenPictures,
            onOpenAuthorSpace: onOpenAuthorSpace
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
            onShowPage: onShowPage,
            onRetry: onRetry,
            onShowDialog: onShowDialog,
            onLoadMoreDialog: onLoadMoreDialog,
            onCloseDialog: onCloseDialog,
            onOpenLink: onOpenLink,
            onOpenPictures: onOpenPictures,
            onOpenAuthorSpace: onOpenAuthorSpace
        )
        needsLayout = true
    }

    override func layout() {
        super.layout()
        guard let presentation else { return }
        let rootTop = NativePlaybackCommentsItemMeasurement.rootVerticalInset
        rootRow.frame = NSRect(
            x: 0,
            y: rootTop,
            width: bounds.width,
            height: NativePlaybackCommentsItemMeasurement.rootRowBottom(
                presentation,
                width: bounds.width,
                textRenderer: textRenderer
            ) - rootTop
        )
        let panelWidth = NativePlaybackCommentsItemMeasurement.repliesPanelWidth(
            threadWidth: bounds.width
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
            y: rootRow.frame.maxY
                + (panelHeight > 0 ? NativePlaybackCommentsItemMeasurement.rootPanelGap : 0),
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
