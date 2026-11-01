import CoreGraphics

/// UP 主空间层头部与状态覆盖层的唯一几何来源；App 壳的上下文层动画读取其中的过渡时长。
///
/// 投稿行与列表边距在 `VideoRowGeometry`（相关推荐竖列共用），页码条的几何与列表为它留出的高度在 BiliUI 的
/// `PageNumberPagerGeometry`。
public enum UploaderSpaceGeometry {
    static let headerHeight: CGFloat = 40
    static let headerBottomSpacing: CGFloat = 10
    static let headerHorizontalPadding: CGFloat = 8
    static let headerSpacing: CGFloat = 10
    static let backButtonSize: CGFloat = 24
    static let avatarSize: CGFloat = 28

    /// 空间层滑入／滑出右栏的动画时长。
    public static let layerTransitionDuration: Double = 0.28

    /// 头部下方状态提示（空、失败、登录）的间距与左右留白。
    static let messageSpacing: CGFloat = 12
    static let messageHorizontalPadding: CGFloat = 24

    /// 加载、空、失败等状态覆盖层从头部下方开始，返回按钮始终可点。
    static let stateContentTop: CGFloat =
        VideoRowGeometry.listTopInset + headerHeight + headerBottomSpacing
}
