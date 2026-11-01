import CoreGraphics

/// 竖向视频行列表（UP 主空间投稿、相关推荐竖列）的唯一几何来源：行、封面、角标与列表边距。
enum VideoRowGeometry {
    static let listHorizontalInset: CGFloat = 8
    static let listTopInset: CGFloat = 8
    static let listBottomInset: CGFloat = 12

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
}
