import Accelerate
import AppKit
import BiliModels
import CoreText
import Foundation

struct DanmakuTextureCacheKey: Hashable, Sendable {
    static let algorithmVersion = 1

    let text: String
    let fontSize: Double
    let colorRGB: UInt32
    let fontDescriptor: String
    let fontWeight: CoreAnimationDanmakuFontWeight
    let fontScale: Double
    let backingScale: Double
    let outlineWidthPoints: Double
    let shadowRadiusPoints: Double
    let algorithmVersion: Int
}

struct DanmakuTexturePayload: Sendable, Equatable {
    let pixels: Data
    let widthPixels: Int
    let heightPixels: Int
    let bytesPerRow: Int
    let backingScale: Double

    var byteCost: Int { bytesPerRow * heightPixels }

    var metrics: DanmakuTextMetrics {
        DanmakuTextMetrics(
            width: Double(widthPixels) / backingScale,
            height: Double(heightPixels) / backingScale
        )
    }
}

enum DanmakuTextureRasterizer {
    // Core Text keeps color-glyph RGBA in the fill. Outline/shadow polarity is intentionally
    // selected once from the event's declared RGB for the complete union mask; per-glyph adaptive
    // decoration is not attempted, so mixed emoji/text never gets flattened to one fill color.
    static let maximumTextUTF16Length = 512
    static let maximumWidthPixels = 8_192
    static let maximumHeightPixels = 512
    static let maximumTextureByteCost = 8 * 1_024 * 1_024
    static let maximumBackingScale = 4.0
    static let outlineWidthPoints = 0.5
    static let lightInkRelativeLuminanceThreshold = 0.179

    static func key(
        event: DanmakuEvent,
        style: CoreAnimationDanmakuStyle,
        backingScale: Double
    ) -> DanmakuTextureCacheKey? {
        guard !event.text.isEmpty,
            event.text.utf16.count <= maximumTextUTF16Length,
            event.fontSize.isFinite,
            backingScale.isFinite,
            backingScale >= 1,
            backingScale <= maximumBackingScale
        else {
            return nil
        }
        let fontSize =
            [18.0, 25.0, 36.0].contains(event.fontSize)
            ? event.fontSize : 25
        return DanmakuTextureCacheKey(
            text: event.text,
            fontSize: fontSize,
            colorRGB: event.colorRGB & 0x00FF_FFFF,
            fontDescriptor: "system-\(style.fontWeight.rawValue)",
            fontWeight: style.fontWeight,
            fontScale: style.fontScale,
            backingScale: backingScale,
            outlineWidthPoints: outlineWidthPoints,
            shadowRadiusPoints: style.shadowBlurRadius,
            algorithmVersion: DanmakuTextureCacheKey.algorithmVersion
        )
    }

    static func rasterize(
        key: DanmakuTextureCacheKey
    ) -> DanmakuTexturePayload? {
        let scale = CGFloat(key.backingScale)
        let colorSpace =
            CGColorSpace(name: CGColorSpace.sRGB)
            ?? CGColorSpaceCreateDeviceRGB()
        let font = NSFont.systemFont(
            ofSize: CGFloat(key.fontSize * key.fontScale),
            weight: fontWeight(key.fontWeight)
        )
        let components = rgbComponents(key.colorRGB)
        let foreground = CGColor(
            srgbRed: components.red,
            green: components.green,
            blue: components.blue,
            alpha: 1
        )
        let attributed = NSAttributedString(
            string: key.text,
            attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String):
                    foreground,
            ]
        )
        let line = CTLineCreateWithAttributedString(attributed)
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        let width = CGFloat(
            CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
        )
        let height = ascent + descent + leading
        guard width.isFinite, height.isFinite, width > 0, height > 0 else {
            return nil
        }

        let outlineRadiusPixels = key.outlineWidthPoints * key.backingScale
        let shadowRadiusPixels =
            key.shadowRadiusPoints > 0
            ? max(
                1,
                Int((key.shadowRadiusPoints * key.backingScale).rounded())
            ) : 0
        let paddingPixels = max(
            4,
            Int(ceil(outlineRadiusPixels)) + shadowRadiusPixels + 2
        )
        let widthPixels = Int(ceil(width * scale)) + paddingPixels * 2
        let heightPixels = Int(ceil(height * scale)) + paddingPixels * 2
        let bytesPerRow = widthPixels * 4
        guard widthPixels > 0,
            heightPixels > 0,
            widthPixels <= maximumWidthPixels,
            heightPixels <= maximumHeightPixels,
            bytesPerRow <= Int.max / heightPixels,
            bytesPerRow * heightPixels <= maximumTextureByteCost
        else {
            return nil
        }

        var fill = [UInt8](repeating: 0, count: bytesPerRow * heightPixels)
        let drewLine = fill.withUnsafeMutableBytes { buffer -> Bool in
            guard
                let context = CGContext(
                    data: buffer.baseAddress,
                    width: widthPixels,
                    height: heightPixels,
                    bitsPerComponent: 8,
                    bytesPerRow: bytesPerRow,
                    space: colorSpace,
                    bitmapInfo: bitmapInfo.rawValue
                )
            else {
                return false
            }
            context.scaleBy(x: scale, y: scale)
            let padding = CGFloat(paddingPixels) / scale
            context.textPosition = CGPoint(x: padding, y: padding + descent)
            CTLineDraw(line, context)
            return true
        }
        guard drewLine else { return nil }

        let fillAlpha = alpha(from: fill)
        let ringAlpha = outerRing(
            alpha: fillAlpha,
            width: widthPixels,
            height: heightPixels,
            radiusPixels: outlineRadiusPixels
        )
        let decorationIsLight =
            relativeLuminance(components)
            < lightInkRelativeLuminanceThreshold
        let ring = monochromePixels(
            alpha: ringAlpha,
            isLight: decorationIsLight
        )
        let decorated = sourceOver(foreground: fill, background: ring)
        guard shadowRadiusPixels > 0 else {
            return DanmakuTexturePayload(
                pixels: Data(decorated),
                widthPixels: widthPixels,
                heightPixels: heightPixels,
                bytesPerRow: bytesPerRow,
                backingScale: key.backingScale
            )
        }
        let blurredAlpha = tentBlur(
            alpha: alpha(from: decorated),
            width: widthPixels,
            height: heightPixels,
            radius: shadowRadiusPixels
        )
        let shadow = monochromePixels(
            alpha: blurredAlpha,
            isLight: decorationIsLight
        )
        let baked = sourceOver(foreground: decorated, background: shadow)
        return DanmakuTexturePayload(
            pixels: Data(baked),
            widthPixels: widthPixels,
            heightPixels: heightPixels,
            bytesPerRow: bytesPerRow,
            backingScale: key.backingScale
        )
    }

    static func outerRing(
        alpha: [UInt8],
        width: Int,
        height: Int,
        radiusPixels: Double
    ) -> [UInt8] {
        precondition(alpha.count == width * height)
        guard !alpha.isEmpty, radiusPixels > 0 else {
            return [UInt8](repeating: 0, count: alpha.count)
        }
        let radius = max(1, Int(ceil(radiusPixels)))
        var source = alpha
        var dilated = [UInt8](repeating: 0, count: alpha.count)
        let kernelSize = vImagePixelCount(radius * 2 + 1)
        let error = source.withUnsafeMutableBytes { sourceBuffer in
            dilated.withUnsafeMutableBytes { destinationBuffer in
                var sourceImage = vImage_Buffer(
                    data: sourceBuffer.baseAddress,
                    height: vImagePixelCount(height),
                    width: vImagePixelCount(width),
                    rowBytes: width
                )
                var destinationImage = vImage_Buffer(
                    data: destinationBuffer.baseAddress,
                    height: vImagePixelCount(height),
                    width: vImagePixelCount(width),
                    rowBytes: width
                )
                return vImageMax_Planar8(
                    &sourceImage,
                    &destinationImage,
                    nil,
                    0,
                    0,
                    kernelSize,
                    kernelSize,
                    vImage_Flags(kvImageEdgeExtend)
                )
            }
        }
        guard error == kvImageNoError else {
            return [UInt8](repeating: 0, count: alpha.count)
        }
        let edgeCoverage = min(radiusPixels / Double(radius), 1)
        return zip(dilated, alpha).map { expanded, original in
            guard expanded > original else { return 0 }
            return UInt8(
                min(
                    255,
                    Int((Double(expanded - original) * edgeCoverage).rounded())
                )
            )
        }
    }

    static func tentBlur(
        alpha: [UInt8],
        width: Int,
        height: Int,
        radius: Int
    ) -> [UInt8] {
        precondition(alpha.count == width * height)
        guard !alpha.isEmpty, radius > 0 else { return alpha }
        var source = alpha
        var result = [UInt8](repeating: 0, count: alpha.count)
        let kernelSize = UInt32(radius * 2 + 1)
        let error = source.withUnsafeMutableBytes { sourceBuffer in
            result.withUnsafeMutableBytes { destinationBuffer in
                var sourceImage = vImage_Buffer(
                    data: sourceBuffer.baseAddress,
                    height: vImagePixelCount(height),
                    width: vImagePixelCount(width),
                    rowBytes: width
                )
                var destinationImage = vImage_Buffer(
                    data: destinationBuffer.baseAddress,
                    height: vImagePixelCount(height),
                    width: vImagePixelCount(width),
                    rowBytes: width
                )
                return vImageTentConvolve_Planar8(
                    &sourceImage,
                    &destinationImage,
                    nil,
                    0,
                    0,
                    kernelSize,
                    kernelSize,
                    0,
                    vImage_Flags(kvImageEdgeExtend)
                )
            }
        }
        return error == kvImageNoError ? result : alpha
    }

    static func alpha(from pixels: [UInt8]) -> [UInt8] {
        stride(from: 3, to: pixels.count, by: 4).map { pixels[$0] }
    }

    static func monochromePixels(
        alpha: [UInt8],
        isLight: Bool
    ) -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: alpha.count * 4)
        for index in alpha.indices {
            let value = alpha[index]
            let offset = index * 4
            let channel = isLight ? value : 0
            pixels[offset] = channel
            pixels[offset + 1] = channel
            pixels[offset + 2] = channel
            pixels[offset + 3] = value
        }
        return pixels
    }

    static func sourceOver(
        foreground: [UInt8],
        background: [UInt8]
    ) -> [UInt8] {
        precondition(foreground.count == background.count)
        var result = background
        for offset in stride(from: 0, to: result.count, by: 4) {
            let foregroundAlpha = Int(foreground[offset + 3])
            let inverseAlpha = 255 - foregroundAlpha
            for channel in 0..<3 {
                result[offset + channel] = UInt8(
                    min(
                        255,
                        Int(foreground[offset + channel])
                            + (Int(background[offset + channel])
                                * inverseAlpha + 127) / 255
                    )
                )
            }
            result[offset + 3] = UInt8(
                min(
                    255,
                    foregroundAlpha
                        + (Int(background[offset + 3]) * inverseAlpha + 127)
                        / 255
                )
            )
        }
        return result
    }

    static func decorationIsLight(colorRGB: UInt32) -> Bool {
        relativeLuminance(rgbComponents(colorRGB))
            < lightInkRelativeLuminanceThreshold
    }

    private static func rgbComponents(
        _ colorRGB: UInt32
    ) -> (red: CGFloat, green: CGFloat, blue: CGFloat) {
        let rgb = colorRGB & 0x00FF_FFFF
        return (
            CGFloat((rgb >> 16) & 0xFF) / 255,
            CGFloat((rgb >> 8) & 0xFF) / 255,
            CGFloat(rgb & 0xFF) / 255
        )
    }

    private static func relativeLuminance(
        _ components: (red: CGFloat, green: CGFloat, blue: CGFloat)
    ) -> CGFloat {
        0.2126 * linearized(components.red)
            + 0.7152 * linearized(components.green)
            + 0.0722 * linearized(components.blue)
    }

    private static func linearized(_ component: CGFloat) -> CGFloat {
        component <= 0.04045
            ? component / 12.92
            : pow((component + 0.055) / 1.055, 2.4)
    }

    private static func fontWeight(
        _ weight: CoreAnimationDanmakuFontWeight
    ) -> NSFont.Weight {
        switch weight {
        case .regular: .regular
        case .medium: .medium
        case .semibold: .semibold
        case .bold: .bold
        }
    }

    private static let bitmapInfo = CGBitmapInfo(
        rawValue: CGImageAlphaInfo.premultipliedLast.rawValue
    ).union(.byteOrder32Big)
}
