import BiliModels
import CoreGraphics
import Foundation

/// 评论头像的加载：把评论资源引用经 resolver 换成按头像像素框缩小的地址，再经取图 port 取图。
///
/// 详情区控制器持有一个，供所有评论行共用；不缓存，缓存在 port 的实现（图片管线）里。
@MainActor
final class NativePlaybackCommentAvatarLoader {
    private let imagePipeline: any VideoDetailImageLoading
    private let resolveURL: CommentAssetURLResolver

    init(
        imagePipeline: any VideoDetailImageLoading,
        resolveURL: @escaping CommentAssetURLResolver
    ) {
        self.imagePipeline = imagePipeline
        self.resolveURL = resolveURL
    }

    func cachedImage(for reference: CommentAssetReference) -> CGImage? {
        guard let url = url(for: reference) else { return nil }
        return imagePipeline.cachedImage(for: url, purpose: .avatar)
    }

    func image(
        for reference: CommentAssetReference
    ) async -> VideoDetailImage? {
        guard let url = url(for: reference) else { return nil }
        return await imagePipeline.image(for: url, purpose: .avatar)
    }

    private func url(for reference: CommentAssetReference) -> URL? {
        resolveURL(reference, NativePlaybackCommentAssetSizing.pixelBox(for: .avatar))
    }
}
