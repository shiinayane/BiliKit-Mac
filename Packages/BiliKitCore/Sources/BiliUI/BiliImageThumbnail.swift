import Foundation

/// 头像图片的像素边长，是头像请求的缩略框和图片管线头像解码上限的唯一来源。
public enum BiliAvatarImageSize {
    /// 卡片、评论、侧栏账号行、空间预览头部与播放侧栏 UP 主名片共用的头像边长。
    ///
    /// 按播放侧栏 UP 主名片的 48pt 取值，2x 屏为 96 像素；关注页人物卡片（40pt）、视频卡片（34pt）、侧栏账号行（32pt）、
    /// 评论（32／22pt）与空间预览头部（28pt）更小，同一尺寸都够用。调大会让每张头像卡片的下载与解码都变大，调小会让
    /// 侧栏名片头像模糊。
    public static let pixelSide = 96

    /// 整页空间页头部（`UploaderSpacePageGeometry.avatarSize`，72pt）的大头像边长，2x 屏为 144 像素。
    ///
    /// 那里一页只有一个头像，单独用大尺寸不影响网格与列表的下载量；调小会让空间页头部头像在 2x 屏上发软。
    public static let largePixelSide = 144
}

/// 远端封面与头像的 B 站图片缩略地址：视频卡片（推荐、热门、搜索、观看历史、稍后再看、收藏夹、播放页横排、整页空间页投稿）
/// 封面与作者头像，空间预览的投稿行封面，关注页人物卡片、空间头部（整页空间页用大头像）与播放侧栏 UP 主名片的头像，以及侧栏账号头像。
///
/// 只改写 `hdslb.com` 及其子域、没有 query／fragment、path 里还没有缩略参数的地址；其他来源原样返回，
/// 来源校验仍由图片管线负责（见 SECURITY-MODEL §4）。缩略参数写在 path 上（`@{宽}w_{高}h_1c.webp`），
/// 让 CDN 按显示尺寸裁剪并转成 WebP，减少下载与解码。头像尺寸与 `url(_:size:)` 为 `public`：App 的侧栏
/// 账号头像经图片管线请求前用它改写（`NativeVideoImagePipeline.accountAvatarRequestURL`）。
public enum BiliImageThumbnail {
    /// 请求像素与显示点数之比。
    ///
    /// Mac 的 backing scale 最大为 2，按 2 取值在 1x 屏上只多下载一些，在 2x 屏上不发虚；评论图片的缩略框也用它。
    package static let displayPixelScale: CGFloat = 2

    /// 请求的缩略尺寸（像素），按显示尺寸乘 `displayPixelScale` 取值。
    public struct Size: Equatable, Sendable {
        let width: Int
        let height: Int

        /// 视频卡片的 16:9 封面，按 320pt 宽取值。
        ///
        /// 网格卡片在常见窗口宽度下约 240–320pt，相关推荐横排的卡片是 224pt；再大只增加下载与解码，卡片放大到超过
        /// 320pt 时略有模糊。网格与横排用同一尺寸，同一视频在两处请求同一地址、共用窗口图片缓存。
        package static let videoCover = cover(pointWidth: 320)

        /// 显示宽度为 `pointWidth` 的 16:9 封面位；比视频卡片小得多的封面位（空间预览的投稿行）按自己的宽度取。
        package static func cover(pointWidth: CGFloat) -> Size {
            let width = Int((pointWidth * displayPixelScale).rounded(.up))
            return Size(width: width, height: width * 9 / 16)
        }

        /// 卡片头像显示为 `VideoCardGeometry.avatarSize`（34pt），与其他头像共用 `BiliAvatarImageSize`。
        public static let avatar = Size(
            width: BiliAvatarImageSize.pixelSide,
            height: BiliAvatarImageSize.pixelSide
        )

        /// 整页空间页头部的大头像。
        package static let largeAvatar = Size(
            width: BiliAvatarImageSize.largePixelSide,
            height: BiliAvatarImageSize.largePixelSide
        )
    }

    public static func url(_ url: URL?, size: Size) -> URL? {
        guard let url,
            let host = url.host?.lowercased(),
            host == "hdslb.com" || host.hasSuffix(".hdslb.com"),
            url.query == nil,
            url.fragment == nil,
            !url.path.contains("@")
        else {
            return url
        }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.path += "@\(size.width)w_\(size.height)h_1c.webp"
        return components?.url ?? url
    }
}
