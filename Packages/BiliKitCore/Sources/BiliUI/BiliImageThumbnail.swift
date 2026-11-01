import Foundation

/// 头像图片的像素边长，是卡片、评论与侧栏账号头像请求的缩略框和图片管线头像解码上限的唯一来源。
///
/// 最大的头像显示是播放详情区 UP 主名片的 48pt，2x 屏为 96 像素；卡片（34pt）、侧栏账号行（32pt）、
/// 评论（32／22pt）与 UP 主空间头部（28pt）更小，同一尺寸都够用。调大只增加下载与解码，调小会让侧栏名片
/// 头像模糊。
public enum BiliAvatarImageSize {
    public static let pixelSide = 96
}

/// 视频卡片（推荐、热门、搜索、观看历史、稍后再看、收藏夹）封面与作者头像，以及侧栏账号头像的 B 站图片缩略地址。
///
/// 只改写 `hdslb.com` 及其子域、没有 query／fragment、path 里还没有缩略参数的地址；其他来源原样返回，
/// 来源校验仍由图片管线负责（见 SECURITY-MODEL §4）。缩略参数写在 path 上（`@{宽}w_{高}h_1c.webp`），
/// 让 CDN 按显示尺寸裁剪并转成 WebP，减少下载与解码。头像尺寸与 `url(_:size:)` 为 `public`：App 的侧栏
/// 账号头像经图片管线请求前用它改写（`NativeVideoImagePipeline.accountAvatarRequestURL`）。
public enum BiliImageThumbnail {
    /// 请求的缩略尺寸（像素），按显示尺寸乘 2x 屏取值。
    public struct Size: Equatable, Sendable {
        let width: Int
        let height: Int

        /// 16:9 封面：网格卡片在常见窗口宽度下约 240–320pt，2x 屏需要约 640 像素宽；
        /// 再大只增加下载与解码，卡片放大到超过 320pt 时略有模糊。
        package static let videoCover = Size(width: 640, height: 360)
        /// 卡片头像显示为 `VideoCardGeometry.avatarSize`（34pt），与其他头像共用 `BiliAvatarImageSize`。
        public static let avatar = Size(
            width: BiliAvatarImageSize.pixelSide,
            height: BiliAvatarImageSize.pixelSide
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
