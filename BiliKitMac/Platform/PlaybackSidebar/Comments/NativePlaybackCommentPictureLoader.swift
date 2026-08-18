import BiliModels
import CoreGraphics

@MainActor
final class NativePlaybackCommentPictureLoader {
    private let imagePipeline: NativeVideoImagePipeline
    private let resolveURL: CommentAssetURLResolver
    private let variant: NativeVideoImageVariant

    init(
        imagePipeline: NativeVideoImagePipeline,
        resolveURL: @escaping CommentAssetURLResolver,
        variant: NativeVideoImageVariant = .commentPicture
    ) {
        self.imagePipeline = imagePipeline
        self.resolveURL = resolveURL
        self.variant = variant
    }

    func cachedImage(for reference: CommentAssetReference) -> CGImage? {
        guard let url = resolveURL(reference) else { return nil }
        return imagePipeline.cachedImage(for: url, variant: variant)
    }

    func image(
        for reference: CommentAssetReference
    ) async -> NativeVideoImageLoadResult? {
        guard let url = resolveURL(reference) else { return nil }
        return await imagePipeline.image(for: url, variant: variant)
    }
}
