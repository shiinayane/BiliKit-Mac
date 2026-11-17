import Foundation

extension CardGridGeometry {
    /// 视频卡片网格：BiliVideoCollectionUI 的原生网格（`NativeVideoGridView`）与 BiliUI 的加载骨架共用这一个实例。
    ///
    /// 至少 2 列：16:9 封面单列时在常见窗口宽度下过大。调大 `minimumCardWidth` 或调小最大列数，宽窗口里每屏的卡片
    /// 更少；调小则卡片变窄，两行标题放下的字更少。
    package static let video = CardGridGeometry(
        contentPadding: 24,
        horizontalSpacing: 20,
        verticalSpacing: 28,
        minimumCardWidth: 240,
        minimumColumnCount: 2,
        maximumColumnCount: 5,
        height: VideoCardGeometry.height(forWidth:)
    )
}

/// 相关推荐横排的唯一几何来源：BiliVideoDetailFeature 的原生横排（`NativeVideoShelfView`）、
/// 横排加载骨架与播放页布局共用。
public enum VideoCardShelfGeometry {
    public static let cardWidth: CGFloat = 224
    public static let cardHeight = VideoCardGeometry.height(forWidth: cardWidth)
    public static let spacing: CGFloat = 16
    public static let contentInset: CGFloat = 40
    /// 卡片下方仍在横排可视区内的留白；页面底边距要扣掉它，卡片到窗口底边才与设计值一致。
    public static let bottomInset: CGFloat = 22
    public static let viewportHeight = cardHeight + bottomInset
    /// 标题行固定高度：放得下分段控件，有无合集、切换分页时横排总高不变，视频尺寸不跳。
    public static let headerHeight: CGFloat = 28
}

/// 单张卡片的 16:9 封面与文字区；纵向偏移都从封面底边算起。
public enum VideoCardGeometry {
    public static let coverAspectWidth: CGFloat = 16
    public static let coverAspectHeight: CGFloat = 9
    public static let coverCornerRadius: CGFloat = 10
    public static let textTopSpacing: CGFloat = 10
    public static let avatarSize: CGFloat = 34
    public static let avatarTextSpacing: CGFloat = 10
    public static let titleHeight: CGFloat = 47
    public static let footerTopOffset: CGFloat = 63
    public static let footerHeight: CGFloat = 21
    public static let textAreaHeight = footerTopOffset + footerHeight

    public static func coverHeight(forWidth width: CGFloat) -> CGFloat {
        floor(width * coverAspectHeight / coverAspectWidth)
    }

    public static func height(forWidth width: CGFloat) -> CGFloat {
        coverHeight(forWidth: width) + textAreaHeight
    }

    public static func textLeadingInset(showsAvatar: Bool) -> CGFloat {
        showsAvatar ? avatarSize + avatarTextSpacing : 0
    }
}
