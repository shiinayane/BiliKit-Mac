import BiliBrowseFeature
import BiliDanmaku
import BiliVideoCollectionUI
import BiliVideoDetailFeature
import CoreGraphics
import Foundation

/// 卡片与网格经 `NativeVideoImageLoading` 取图：只用封面与头像两种用途，结果只带第一帧与是否淡入。
extension NativeVideoImagePipeline: NativeVideoImageLoading {
    func cachedImage(for url: URL, kind: NativeVideoCardImageKind) -> CGImage? {
        cachedImage(for: url, variant: NativeVideoImageVariant(kind))
    }

    func image(for url: URL, kind: NativeVideoCardImageKind) async -> NativeVideoCardImage? {
        guard let result = await image(for: url, variant: NativeVideoImageVariant(kind)) else {
            return nil
        }
        return NativeVideoCardImage(image: result.image, fadesIn: result.origin.shouldFadeIn)
    }
}

/// 搜索起始页经 Browse 的 `TrendingSearchIconLoading` 取热搜图标：固定用 `.trendingSearchIcon`，只给第一帧；
/// 请求地址与响应仍走本管线的校验（见 SECURITY-MODEL §4、§6）。
extension NativeVideoImagePipeline: TrendingSearchIconLoading {
    func cachedTrendingSearchIcon(for url: URL) -> CGImage? {
        cachedImage(for: url, variant: .trendingSearchIcon)
    }

    func trendingSearchIcon(for url: URL) async -> CGImage? {
        await image(for: url, variant: .trendingSearchIcon)?.image
    }
}

/// 弹幕关联视频卡片经 BiliDanmaku 的 `DanmakuCoverImageLoading` 取封面：用卡片封面用途，与网格共用缓存；
/// 请求地址与响应仍走本管线的校验（见 SECURITY-MODEL §4）。
extension NativeVideoImagePipeline: DanmakuCoverImageLoading {
    func cachedDanmakuCover(for url: URL) -> CGImage? {
        cachedImage(for: url, variant: .cover)
    }

    func danmakuCover(for url: URL) async -> CGImage? {
        await image(for: url, variant: .cover)?.image
    }
}

/// 播放详情区、评论、评论图片预览与 UP 主空间经 BiliVideoDetailFeature 的 `VideoDetailImageLoading` 取图；
/// 用途映射到本管线的用途，请求地址、响应校验、解码上限与缓存仍只在这里（见 SECURITY-MODEL §4）。
extension NativeVideoImagePipeline: VideoDetailImageLoading {
    func cachedImage(for url: URL, purpose: VideoDetailImagePurpose) -> CGImage? {
        cachedImage(for: url, variant: NativeVideoImageVariant(purpose))
    }

    func cachedAnimation(for url: URL, purpose: VideoDetailImagePurpose) -> NativeAnimatedImage? {
        cachedAnimation(for: url, variant: NativeVideoImageVariant(purpose))
    }

    func image(for url: URL, purpose: VideoDetailImagePurpose) async -> VideoDetailImage? {
        guard let result = await image(for: url, variant: NativeVideoImageVariant(purpose)) else {
            return nil
        }
        return VideoDetailImage(
            image: result.image,
            animation: result.animation,
            fadesIn: result.origin.shouldFadeIn
        )
    }

    func originalData(for url: URL, purpose: VideoDetailImagePurpose) async -> Data? {
        await originalData(for: url, variant: NativeVideoImageVariant(purpose))
    }
}

extension NativeVideoImageVariant {
    init(_ purpose: VideoDetailImagePurpose) {
        switch purpose {
        case .avatar: self = .avatar
        case .cover: self = .cover
        case .commentEmote: self = .commentEmote
        case .commentPicture: self = .commentPicture
        case .commentPicturePreview: self = .commentPicturePreview
        }
    }

    init(_ kind: NativeVideoCardImageKind) {
        switch kind {
        case .cover: self = .cover
        case .avatar: self = .avatar
        }
    }
}
