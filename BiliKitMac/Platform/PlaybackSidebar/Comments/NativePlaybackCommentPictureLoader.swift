import BiliModels
import CoreGraphics

@MainActor
final class NativePlaybackCommentPictureLoader {
    private let imagePipeline: NativeVideoImagePipeline
    private let resolveURL: CommentAssetURLResolver

    init(
        imagePipeline: NativeVideoImagePipeline,
        resolveURL: @escaping CommentAssetURLResolver
    ) {
        self.imagePipeline = imagePipeline
        self.resolveURL = resolveURL
    }

    func cachedImage(for reference: CommentAssetReference) -> CGImage? {
        guard let url = resolveURL(reference) else { return nil }
        return imagePipeline.cachedImage(for: url, variant: .commentPicture)
    }

    func image(
        for reference: CommentAssetReference
    ) async -> NativeVideoImageLoadResult? {
        guard let url = resolveURL(reference) else { return nil }
        return await imagePipeline.image(for: url, variant: .commentPicture)
    }
}
