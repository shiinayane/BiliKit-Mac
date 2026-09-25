import CoreGraphics
import Testing

@testable import BiliKit

@Suite(.timeLimit(.minutes(1)))
struct NativeVideoImagePipelineTests {
    @Test
    func waiterDeliversTheFirstResultWhetherItFinishesBeforeOrAfterSuspension() async throws {
        let image = try #require(Self.makeImage())
        let result = NativeVideoImageLoadResult(image: image, origin: .network)

        let finishedFirst = NativeVideoImageWaiter()
        finishedFirst.finish(with: result)
        finishedFirst.finish(with: nil)
        #expect(await finishedFirst.value()?.image === image)

        let suspendedFirst = NativeVideoImageWaiter()
        async let value = suspendedFirst.value()
        // 两次 finish 都可能先于挂起到达；无论哪种顺序都只 resume 一次且保留第一个结果。
        suspendedFirst.finish(with: nil)
        suspendedFirst.finish(with: result)
        #expect(await value == nil)
    }

    private static func makeImage() -> CGImage? {
        let context = CGContext(
            data: nil,
            width: 2,
            height: 2,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        return context?.makeImage()
    }
}
