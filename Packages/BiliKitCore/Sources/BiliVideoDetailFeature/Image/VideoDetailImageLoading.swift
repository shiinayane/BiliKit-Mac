import CoreGraphics
import Foundation

/// 播放详情区、评论、评论图片预览与 UP 主空间取图的 port：先同步查缓存，未命中再异步加载。
///
/// 实现是 App 的窗口图片管线（`NativeVideoImagePipeline`）：下载、来源与响应校验、大小上限、首帧解码、
/// 动图播放门槛与有界缓存都只在那里（见 SECURITY-MODEL §4），用途到管线用途的映射也在 App；本 target 只对
/// 管线按门槛放行的 `NativeAnimatedImage` 数据逐帧解码播放。同步查缓存让复用的行在配置当帧就显示已缓存的图，
/// 不先闪一下占位。
///
/// 本 Feature 的所有取图（竖向视频行的封面、评论表情、评论图片与预览、原图数据）都走这个 Feature 自有的窄 port，
/// 不经 BiliVideoCollectionUI 的卡片 port。
///
/// 调用方契约：`cachedImage`／`cachedAnimation` 在主线程配置视图时同步调用，实现必须线程安全、只查内存
/// 缓存、不阻塞、不发请求；调用方取消 `image(for:purpose:)` 所在的 Task 时，实现撤掉这个等待者并返回 nil，
/// 同一地址没有其他等待者时取消下载。
public protocol VideoDetailImageLoading: Sendable {
    /// 已解码缓存里的图（动图为第一帧）；未命中或管线已关闭时为 nil。
    func cachedImage(for url: URL, purpose: VideoDetailImagePurpose) -> CGImage?
    /// 已缓存图片的动图数据；静态图、不保留动图的用途或没有缓存时为 nil。
    func cachedAnimation(for url: URL, purpose: VideoDetailImagePurpose) -> NativeAnimatedImage?
    /// 加载并解码首帧；失败、取消或管线已关闭时为 nil。
    func image(for url: URL, purpose: VideoDetailImagePurpose) async -> VideoDetailImage?
    /// 用户保存原图时取原始响应数据：不解码、不缓存，只返回 ImageIO 能识别的位图；失败、取消或管线已
    /// 关闭时为 nil。
    func originalData(for url: URL, purpose: VideoDetailImagePurpose) async -> Data?
}

/// 本 target 的图片用途；每种用途的解码尺寸、响应上限与是否保留动图由实现方决定。
public enum VideoDetailImagePurpose: Hashable, Sendable {
    /// 详情区 UP 主名片、评论作者与空间头部的头像。
    case avatar
    /// 空间投稿行的封面。
    case cover
    /// 评论正文里的表情与链接前置图标。
    case commentEmote
    /// 评论列表里的图片格子（图床缩小图，保留动图）。
    case commentPicture
    /// 评论图片预览的原图（保留动图）。
    case commentPicturePreview
}

/// 一次取图的结果：解码后的图、可播放的动图数据，以及它是否刚从网络到达、需要淡入。
public struct VideoDetailImage: Sendable {
    /// 第一帧（静态图就是整张图）。
    public let image: CGImage
    /// 只有保留动图的用途、且源图是可播放的多帧图时才有。
    public let animation: NativeAnimatedImage?
    /// 刚从网络到达的图片淡入；内存缓存命中直接显示。
    public let fadesIn: Bool

    public init(image: CGImage, animation: NativeAnimatedImage?, fadesIn: Bool) {
        self.image = image
        self.animation = animation
        self.fadesIn = fadesIn
    }
}
