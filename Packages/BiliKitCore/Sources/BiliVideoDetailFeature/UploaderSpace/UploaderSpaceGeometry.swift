import CoreGraphics

/// UP 主空间层的唯一几何来源：原生列表与状态覆盖层共用；App 壳的上下文层动画读取其中的过渡时长。
public enum UploaderSpaceGeometry {
    static let listHorizontalInset: CGFloat = 8
    static let listTopInset: CGFloat = 8
    static let listBottomInset: CGFloat = 12

    static let headerHeight: CGFloat = 40
    static let headerBottomSpacing: CGFloat = 10
    static let headerHorizontalPadding: CGFloat = 8
    static let headerSpacing: CGFloat = 10
    /// 头部左侧为悬浮返回按钮留出的宽度；按钮在这一格里居中，所以在顶部时与头像、名字排成一行。
    static let backButtonSlotWidth: CGFloat = 36
    /// 那一格相对空间层左缘的位置：列表左边距加头部内边距，与头部里头像左侧的空位对齐。
    static let backButtonSlotLeading: CGFloat = listHorizontalInset + headerHorizontalPadding
    static let avatarSize: CGFloat = 28

    /// 用户在 spike 中对比 128／160／200 后选定 160。
    static let coverWidth: CGFloat = 160
    static let coverHeight: CGFloat = coverWidth * 9 / 16
    static let coverCornerRadius: CGFloat = 6
    static let coverTextSpacing: CGFloat = 10
    static let rowPadding: CGFloat = 8
    static let rowSpacing: CGFloat = 2
    static let rowCornerRadius: CGFloat = 8
    /// 正在播放那一行的强调色底色不透明度；比悬停底色明显，指针移开后仍能看出是哪一行。
    static let currentRowFillOpacity: CGFloat = 0.15
    static let rowHeight: CGFloat = coverHeight + rowPadding * 2

    /// 封面右下角的时长角标。
    static let durationBadgeTrailingInset: CGFloat = 8
    static let durationBadgeBottomInset: CGFloat = 5
    static let durationBadgePadding = CGSize(width: 4, height: 1)
    static let badgeCornerRadius: CGFloat = 3
    static let collaborationBorderWidth: CGFloat = 1
    /// “正在播放”图标与文字、各标记之间、标记与数据行之间的间距。
    static let playingIconSpacing: CGFloat = 3
    static let badgeSpacing: CGFloat = 6
    static let badgeToMetadataSpacing: CGFloat = 4

    /// 空间层滑入／滑出侧栏的动画时长。
    public static let layerTransitionDuration: Double = 0.28

    /// 列表底部加载下一批的转圈或失败说明那一行的高度，与说明和重试按钮之间的间距。
    static let footerHeight: CGFloat = 44
    static let footerSpacing: CGFloat = 8

    /// 头部下方状态提示（空、失败）的间距与左右留白。
    static let messageSpacing: CGFloat = 12
    static let messageHorizontalPadding: CGFloat = 24

    /// 加载、空、失败等状态覆盖层从头部下方开始，不盖住头像、名字与排序。
    static let stateContentTop: CGFloat = listTopInset + headerHeight + headerBottomSpacing
}
