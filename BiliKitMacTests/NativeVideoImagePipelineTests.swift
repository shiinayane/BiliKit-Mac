import AppKit
import BiliUI
import BiliVideoDetailFeature
import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import BiliKit

/// 窗口图片管线的边界：只请求公开 HTTPS 地址（侧栏账号头像与卡片头像同样先缩略再校验），响应、解码尺寸与
/// 缓存都有上界，解码按 EXIF 方向转正、损坏数据失败不崩溃，各用途缓存互不覆盖，动图只在评论图片且不超限时
/// 保留，关闭后不再接受请求。
@Suite(.timeLimit(.minutes(1)))
struct NativeVideoImagePipelineTests {
    @Test(arguments: [
        ("https://i0.hdslb.com/bfs/archive/fixture.jpg", true),
        ("http://i0.hdslb.com/bfs/archive/fixture.jpg", false)
    ])
    func requestsOnlyPublicHTTPSImageAddresses(urlString: String, accepted: Bool) throws {
        let url = try #require(URL(string: urlString))
        #expect(NativeVideoImagePipeline.acceptsRequestURL(url) == accepted)
    }

    @Test
    func accountAvatarRequestsTheAvatarThumbnailLikeCardAvatars() throws {
        let face = try #require(URL(string: "https://i1.hdslb.com/bfs/face/fixture.jpg"))
        let elsewhere = try #require(URL(string: "https://images.example/face.jpg"))
        let insecure = try #require(URL(string: "http://i1.hdslb.com/bfs/face/fixture.jpg"))

        #expect(
            NativeVideoImagePipeline.accountAvatarRequestURL(for: face)?.absoluteString
                == "https://i1.hdslb.com/bfs/face/fixture.jpg@96w_96h_1c.webp"
        )
        #expect(NativeVideoImagePipeline.accountAvatarRequestURL(for: elsewhere) == elsewhere)
        #expect(NativeVideoImagePipeline.accountAvatarRequestURL(for: nil) == nil)
        // 管线不会请求的地址不给出请求地址。
        #expect(NativeVideoImagePipeline.accountAvatarRequestURL(for: insecure) == nil)
    }

    /// 只有评论图片的列表格子与预览保留动图数据；帧数与第一帧尺寸都要在播放门槛内。
    @Test
    func animationIsRetainedOnlyForCommentPicturesWithinThePolicy() throws {
        let animated = try #require(Self.makeGIF(frameCount: 3, width: 4, height: 4))
        let still = try #require(Self.makeGIF(frameCount: 1, width: 4, height: 4))

        let retained = NativeVideoImagePipeline.decodeAnimation(animated, variant: .commentPicture)
        #expect(retained?.data == animated)
        #expect(
            NativeVideoImagePipeline.decodeAnimation(animated, variant: .commentPicturePreview)
                != nil
        )
        for variant in [
            NativeVideoImageVariant.cover, .avatar, .commentEmote, .trendingSearchIcon
        ] {
            #expect(NativeVideoImagePipeline.decodeAnimation(animated, variant: variant) == nil)
        }
        #expect(NativeVideoImagePipeline.decodeAnimation(still, variant: .commentPicture) == nil)
        // 第一帧仍按原规则解码，动图与静态图共用同一个首帧路径。
        #expect(NativeVideoImagePipeline.decodeImage(animated, variant: .commentPicture) != nil)
    }

    @Test
    func animationsBeyondTheFrameOrPixelCapShowOnlyTheFirstFrame() throws {
        let tooManyFrames = try #require(
            Self.makeGIF(
                frameCount: NativeAnimatedImagePolicy.maximumFrameCount + 1,
                width: 1,
                height: 1
            )
        )
        let side = Int(Double(NativeAnimatedImagePolicy.maximumPixelCount).squareRoot()) + 1
        let tooLarge = try #require(Self.makeGIF(frameCount: 2, width: side, height: side))

        #expect(
            NativeVideoImagePipeline.decodeAnimation(tooManyFrames, variant: .commentPicture) == nil
        )
        #expect(
            NativeVideoImagePipeline.decodeAnimation(tooLarge, variant: .commentPicturePreview)
                == nil
        )
    }

    /// 缓存成本包括动图编码数据；缓存命中时动图数据随第一帧一起返回。
    @Test
    func cacheCostIncludesRetainedAnimationData() throws {
        let image = try #require(Self.makeImage())
        let url = try #require(URL(string: "https://i0.hdslb.com/bfs/new_dyn/a.gif"))
        let key = NativeVideoImageKey(url: url, variant: .commentPicture)
        let animation = NativeAnimatedImage(data: Data(count: 100))
        var cache = NativeVideoImageCache(limits: .init(countLimit: 4, costLimit: 1_024))

        cache.insert(image, animation: animation, for: key)

        #expect(cache.totalCost == image.bytesPerRow * image.height + 100)
        #expect(cache.animation(for: key) === animation)
    }

    /// 单项超过总成本上限的份额时不缓存，也不挤掉已缓存的图片。
    @Test
    func oversizedEntryNeitherCachesNorEvictsOthers() throws {
        let small = try #require(Self.makeImage())
        let smallCost = small.bytesPerRow * small.height
        let limits = NativeVideoImageCacheLimits(countLimit: 4, costLimit: smallCost * 8)
        var cache = NativeVideoImageCache(limits: limits)
        let smallKey = try Self.key("small.png", variant: .commentPicturePreview)
        let largeKey = try Self.key("large.png", variant: .commentPicturePreview)
        cache.insert(small, animation: nil, for: smallKey)

        let oversizedAnimation = NativeAnimatedImage(
            data: Data(count: limits.maximumEntryCost)
        )
        cache.insert(small, animation: oversizedAnimation, for: largeKey)

        #expect(cache.image(for: largeKey) == nil)
        #expect(cache.image(for: smallKey) != nil)
        #expect(cache.totalCost == smallCost)
    }

    /// Now Playing 只要一张封面：上界远小于窗口，但仍放得下解码上限内最大的封面。
    @Test
    func nowPlayingArtworkCacheIsSmallButHoldsTheLargestCover() {
        let artwork = NativeVideoImageCacheLimits.nowPlayingArtwork
        let window = NativeVideoImageCacheLimits.window
        let edge = NativeVideoImageVariant.cover.maximumDecodedPixelSize
        let largestCoverCost = edge * edge * 4

        #expect(artwork.countLimit < window.countLimit)
        #expect(artwork.costLimit < window.costLimit)
        #expect(largestCoverCost <= artwork.maximumEntryCost)
    }

    @Test
    func imagePipelineBoundsResponseAndDecodedCache() throws {
        #expect(NativeVideoImagePipeline.acceptsExpectedLength(-1, maximumBytes: 8))
        #expect(NativeVideoImagePipeline.acceptsExpectedLength(8, maximumBytes: 8))
        #expect(!NativeVideoImagePipeline.acceptsExpectedLength(9, maximumBytes: 8))

        var countBoundCache = NativeVideoImageCache(limits: .init(countLimit: 2, costLimit: 1_024))
        let image = try #require(Self.makeImage(width: 4, height: 4))
        try countBoundCache.insert(image, animation: nil, for: Self.key("1"))
        try countBoundCache.insert(image, animation: nil, for: Self.key("2"))
        try countBoundCache.insert(image, animation: nil, for: Self.key("3"))
        #expect(countBoundCache.count == 2)
        #expect(countBoundCache.totalCost <= 1_024)

        // 总上限恰好放下 4 张、单项上限恰好放下 1 张：第 5 张入缓存后按成本淘汰最久未用的那张。
        let imageCost = image.bytesPerRow * image.height
        var costBoundCache = NativeVideoImageCache(
            limits: .init(countLimit: 10, costLimit: imageCost * 4)
        )
        for name in ["a", "b", "c", "d", "e"] {
            try costBoundCache.insert(image, animation: nil, for: Self.key(name))
        }
        #expect(costBoundCache.totalCost == imageCost * 4)
        #expect(costBoundCache.count == 4)
        #expect(try costBoundCache.image(for: Self.key("a")) == nil)
        #expect(try costBoundCache.image(for: Self.key("b")) != nil)
    }

    @Test
    func imageVariantsUseDistinctCacheIdentities() throws {
        let url = try #require(URL(string: "https://i.example/shared.webp"))
        let coverKey = NativeVideoImageKey(url: url, variant: .cover)
        let avatarKey = NativeVideoImageKey(url: url, variant: .avatar)
        let commentPictureKey = NativeVideoImageKey(
            url: url,
            variant: .commentPicture
        )
        let commentPreviewKey = NativeVideoImageKey(
            url: url,
            variant: .commentPicturePreview
        )
        #expect(commentPictureKey != commentPreviewKey)
        let cover = try #require(Self.makeImage(width: 8, height: 4))
        let avatar = try #require(Self.makeImage(width: 4, height: 4))
        var cache = NativeVideoImageCache(limits: .init(countLimit: 2, costLimit: 1_024))

        cache.insert(cover, animation: nil, for: coverKey)
        cache.insert(avatar, animation: nil, for: avatarKey)

        #expect(cache.count == 2)
        #expect(cache.image(for: coverKey)?.width == 8)
        #expect(cache.image(for: avatarKey)?.width == 4)
    }

    @Test
    func largeImagesShrinkToEachVariantsBound() throws {
        let source = try #require(Self.makeSplitImage(width: 5_000, height: 2_500))
        let data = try #require(Self.encode(source, as: .png))

        for variant in [
            NativeVideoImageVariant.cover, .avatar, .commentEmote, .commentPicture,
            .commentPicturePreview, .trendingSearchIcon
        ] {
            let image = try #require(NativeVideoImagePipeline.decodeImage(data, variant: variant))
            #expect(image.width == variant.maximumDecodedPixelSize)
            #expect(image.height == variant.maximumDecodedPixelSize / 2)
        }
    }

    @Test
    func decodingAppliesEXIFOrientation() throws {
        // 存储为左红右蓝的横图，方向 6（顺时针转 90°）显示为上红下蓝的竖图。
        let source = try #require(Self.makeSplitImage(width: 2_000, height: 1_000))
        let data = try #require(
            Self.encode(source, as: .jpeg, properties: [kCGImagePropertyOrientation: 6])
        )

        let image = try #require(NativeVideoImagePipeline.decodeImage(data, variant: .cover))

        #expect(image.width == 320)
        #expect(image.height == 640)
        let top = try #require(Self.pixel(of: image, x: image.width / 2, y: 4))
        let bottom = try #require(Self.pixel(of: image, x: image.width / 2, y: image.height - 5))
        #expect(top.red > 200 && top.blue < 60)
        #expect(bottom.blue > 200 && bottom.red < 60)
    }

    @Test
    func cmykJPEGDecodesWithItsColors() throws {
        let cmyk = CGColorSpaceCreateDeviceCMYK()
        let context = try #require(
            CGContext(
                data: nil,
                width: 300,
                height: 200,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: cmyk,
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            )
        )
        context.setFillColor(try #require(CGColor(colorSpace: cmyk, components: [0, 1, 1, 0, 1])))
        context.fill(CGRect(x: 0, y: 0, width: 300, height: 200))
        let source = try #require(context.makeImage())
        let data = try #require(Self.encode(source, as: .jpeg))

        let image = try #require(
            NativeVideoImagePipeline.decodeImage(data, variant: .commentPicture)
        )

        #expect(image.width == 300)
        #expect(image.height == 200)
        let center = try #require(Self.pixel(of: image, x: 150, y: 100))
        #expect(center.red > 150 && center.green < 100 && center.blue < 100)
    }

    @Test
    func corruptOrHeaderTruncatedDataFailsToDecode() throws {
        // 管线只在 decodeImage 成功后写缓存，解码失败的数据因此不进缓存。
        let source = try #require(Self.makeSplitImage(width: 400, height: 300))
        let jpeg = try #require(Self.encode(source, as: .jpeg))
        let png = try #require(Self.encode(source, as: .png))
        let corrupt: [Data] = [
            Data(),
            jpeg.prefix(64),
            png.prefix(32),
            Data([0xFF, 0xD8, 0xFF, 0xE0]) + Data(repeating: 0x5A, count: 2_000),
            Data(repeating: 0xA5, count: 4_096)
        ]

        for data in corrupt {
            for variant in [NativeVideoImageVariant.cover, .commentPicturePreview] {
                #expect(NativeVideoImagePipeline.decodeImage(data, variant: variant) == nil)
            }
            let animation = NativeVideoImagePipeline.decodeAnimation(
                data,
                variant: .commentPicturePreview
            )
            #expect(animation == nil)
        }
    }

    @Test
    func imagePipelineShutdownRejectsFutureRequestsBeforeTouchingSession() async {
        let pipeline = NativeVideoImagePipeline(cacheLimits: .window)
        pipeline.shutdown()

        let result = await pipeline.image(
            for: URL(string: "https://i.example/after-shutdown.webp")!,
            variant: .cover
        )

        #expect(result == nil)
    }

    @Test
    func imageSessionGateSerializesRegistrationAndInvalidation() {
        let gate = NativeVideoImageSessionGate()
        let session = URLSession(configuration: .ephemeral)
        var registrationCount = 0

        #expect(gate.register { registrationCount += 1 })
        gate.invalidate(session)
        #expect(!gate.register { registrationCount += 1 })
        #expect(registrationCount == 1)
    }

    @Test
    func releasingImageOwnerSynchronouslyInvalidatesRetainedPipeline() async {
        var owner: NativeVideoImagePipelineOwner? = NativeVideoImagePipelineOwner(
            cacheLimits: .window
        )
        weak let weakOwner = owner
        let pipeline = owner!.pipeline

        owner = nil
        let result = await pipeline.image(
            for: URL(string: "https://i.example/after-owner-release.webp")!,
            variant: .cover
        )

        #expect(weakOwner == nil)
        #expect(result == nil)
    }

    @Test
    func imageResponseAccumulatorRejectsChunkBeforeExceedingBound() {
        var accumulator = NativeVideoImageResponseAccumulator(maximumBytes: 8)

        let acceptedFirst = accumulator.append(Data(repeating: 1, count: 6))
        let rejectedOverflow = accumulator.append(Data(repeating: 2, count: 3))
        #expect(accumulator.data.count == 6)
        let acceptedBoundary = accumulator.append(Data(repeating: 3, count: 2))

        #expect(acceptedFirst)
        #expect(!rejectedOverflow)
        #expect(acceptedBoundary)
        #expect(accumulator.data.count == 8)
    }

    /// 只写出 ImageIO 能识别的位图：SVG、HTML 与随机字节都拒绝。
    @Test
    func onlyBitmapImagesAreSaved() throws {
        let pixel = try #require(
            Data(
                base64Encoded:
                    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8/5+hHgAHggJ/PchI7wAAAABJRU5ErkJggg=="
            )
        )

        #expect(NativeVideoImagePipeline.isBitmapImage(pixel))
        #expect(
            !NativeVideoImagePipeline.isBitmapImage(
                Data(#"<svg xmlns="http://www.w3.org/2000/svg"><script>1</script></svg>"#.utf8)
            )
        )
        #expect(!NativeVideoImagePipeline.isBitmapImage(Data("<html></html>".utf8)))
        #expect(!NativeVideoImagePipeline.isBitmapImage(Data([0, 1, 2, 3])))
    }

    /// 取原图数据只走 HTTPS、不带用户信息；管线关闭后不再发请求。
    @Test
    func originalDataRejectsUnsafeAddressesAndClosedPipelines() async throws {
        let pipeline = NativeVideoImagePipeline(cacheLimits: .window)
        let insecure = try #require(URL(string: "http://i0.hdslb.com/bfs/a.png"))
        let withUser = try #require(URL(string: "https://user@i0.hdslb.com/bfs/a.png"))

        #expect(await pipeline.originalData(for: insecure, variant: .commentPicturePreview) == nil)
        #expect(await pipeline.originalData(for: withUser, variant: .commentPicturePreview) == nil)
        pipeline.shutdown()
        let afterShutdown = try #require(URL(string: "https://i0.hdslb.com/bfs/a.png"))
        #expect(
            await pipeline.originalData(for: afterShutdown, variant: .commentPicturePreview) == nil
        )
    }

    private static func key(
        _ name: String,
        variant: NativeVideoImageVariant = .cover
    ) throws -> NativeVideoImageKey {
        let url = try #require(URL(string: "https://i0.hdslb.com/bfs/new_dyn/\(name)"))
        return NativeVideoImageKey(url: url, variant: variant)
    }

    private static func makeGIF(frameCount: Int, width: Int, height: Int) -> Data? {
        let data = NSMutableData()
        guard
            let destination = CGImageDestinationCreateWithData(
                data,
                UTType.gif.identifier as CFString,
                frameCount,
                nil
            )
        else { return nil }
        for index in 0..<frameCount {
            let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
            context?.setFillColor(gray: CGFloat(index % 2), alpha: 1)
            context?.fill(CGRect(x: 0, y: 0, width: width, height: height))
            guard let frame = context?.makeImage() else { return nil }
            CGImageDestinationAddImage(
                destination,
                frame,
                [
                    kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.04]
                ] as CFDictionary
            )
        }
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    /// 左半纯红、右半纯蓝的 RGB 图，用来辨认解码后的方向。
    private static func makeSplitImage(width: Int, height: Int) -> CGImage? {
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        context?.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        context?.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
        context?.setFillColor(red: 0, green: 0, blue: 1, alpha: 1)
        context?.fill(CGRect(x: width / 2, y: 0, width: width - width / 2, height: height))
        return context?.makeImage()
    }

    private static func encode(
        _ image: CGImage,
        as type: UTType,
        properties: [CFString: Any] = [:]
    ) -> Data? {
        let data = NSMutableData()
        guard
            let destination = CGImageDestinationCreateWithData(
                data,
                type.identifier as CFString,
                1,
                nil
            )
        else { return nil }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    /// 把图画进 RGBA 位图后读一个像素；`y` 从上边起算。
    private static func pixel(
        of image: CGImage,
        x: Int,
        y: Int
    ) -> (red: UInt8, green: UInt8, blue: UInt8)? {
        let width = image.width
        let height = image.height
        guard
            let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let bytes = context.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        // 位图内存的第一行是图的上边。
        let offset = y * width * 4 + x * 4
        return (bytes[offset], bytes[offset + 1], bytes[offset + 2])
    }

    private static func makeImage(width: Int = 2, height: Int = 2) -> CGImage? {
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        return context?.makeImage()
    }
}
