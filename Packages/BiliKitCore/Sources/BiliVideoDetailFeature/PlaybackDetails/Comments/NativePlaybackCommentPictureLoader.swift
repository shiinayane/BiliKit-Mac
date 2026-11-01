import BiliModels
import BiliUI
import CoreGraphics
import Foundation

/// 评论图片按用途请求的像素框，是唯一来源。
///
/// 列表格子按最大显示尺寸的 2 倍（Retina）请求缩小图，头像按 `BiliAvatarImageSize`（与图片管线的头像
/// 解码上限同源）请求；预览与表情请求原图。
/// 图床把图片按比例缩进框内、不放大，所以一个框覆盖所有格子尺寸。
enum NativePlaybackCommentAssetSizing {
    static let displayPixelScale: CGFloat = 2

    static func pixelBox(for purpose: VideoDetailImagePurpose) -> CommentAssetPixelBox? {
        switch purpose {
        case .commentPicture:
            CommentAssetPixelBox(
                width: Int(
                    NativePlaybackCommentPictureLayout.maximumContentWidth * displayPixelScale
                ),
                height: Int(
                    NativePlaybackCommentPictureLayout.maximumImageHeight * displayPixelScale
                )
            )
        case .avatar:
            CommentAssetPixelBox(
                width: BiliAvatarImageSize.pixelSide,
                height: BiliAvatarImageSize.pixelSide
            )
        case .cover, .commentEmote, .commentPicturePreview:
            nil
        }
    }
}

/// 评论图片的加载：按用途（列表格子或预览原图）解析地址并经取图 port 取图、取动图数据与原图数据。
///
/// 详情区控制器持有列表用的一个；评论图片预览各持有原图与缩小图占位两个。不缓存，缓存在 port 的实现里。
@MainActor
final class NativePlaybackCommentPictureLoader {
    private let imagePipeline: any VideoDetailImageLoading
    private let resolveURL: CommentAssetURLResolver
    private let purpose: VideoDetailImagePurpose

    init(
        imagePipeline: any VideoDetailImageLoading,
        resolveURL: @escaping CommentAssetURLResolver,
        purpose: VideoDetailImagePurpose = .commentPicture
    ) {
        self.imagePipeline = imagePipeline
        self.resolveURL = resolveURL
        self.purpose = purpose
    }

    func cachedImage(for reference: CommentAssetReference) -> CGImage? {
        guard let url = url(for: reference) else { return nil }
        return imagePipeline.cachedImage(for: url, purpose: purpose)
    }

    func cachedAnimation(for reference: CommentAssetReference) -> NativeAnimatedImage? {
        guard let url = url(for: reference) else { return nil }
        return imagePipeline.cachedAnimation(for: url, purpose: purpose)
    }

    func image(
        for reference: CommentAssetReference
    ) async -> VideoDetailImage? {
        guard let url = url(for: reference) else { return nil }
        return await imagePipeline.image(for: url, purpose: purpose)
    }

    /// 保存原图用的原始数据与默认文件名（图床上的原文件名）。
    func originalData(for reference: CommentAssetReference) async -> Data? {
        guard let url = url(for: reference) else { return nil }
        return await imagePipeline.originalData(for: url, purpose: purpose)
    }

    /// 去掉开头的点，避免默认存成隐藏文件。
    func suggestedFileName(for reference: CommentAssetReference) -> String? {
        guard let name = url(for: reference)?.lastPathComponent else { return nil }
        let visible = String(name.drop(while: { $0 == "." }))
        guard !visible.isEmpty, visible != "/" else { return nil }
        return visible
    }

    private func url(for reference: CommentAssetReference) -> URL? {
        resolveURL(reference, NativePlaybackCommentAssetSizing.pixelBox(for: purpose))
    }
}
