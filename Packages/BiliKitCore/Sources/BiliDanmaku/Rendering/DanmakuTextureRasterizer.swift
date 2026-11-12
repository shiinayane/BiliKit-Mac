import Accelerate
import AppKit
import BiliModels
import CoreText
import Foundation

/// 决定纹理像素的全部输入，也是纹理缓存的 key；由 `DanmakuTextureRasterizer.key` 归一化后生成。
struct DanmakuTextureCacheKey: Hashable, Sendable {
    let text: String
    let fontSize: Double
    let isHighLike: Bool
    let isUploader: Bool
    let colorRGB: UInt32
    let colorStyle: DanmakuColorStyle
    let backingScale: Double
    /// 本窗口自己发出的弹幕：加边框（`DanmakuOwnBorder`），不改尺寸。
    var isOwn = false
}

/// 栅格化好的不可变纹理：sRGB、预乘 alpha、按字节 RGBA 排列的像素，在后台栅格化时就包成 `CGImage`。
///
/// 同一缓存项挂到多少个 layer 上都共用这一个 `CGImage`：Core Animation 提交时按 `CGImage` 对象把像素
/// 拷一份并常驻，不同对象各拷一份，同一对象只拷一次。`CGImage` 不可变、线程安全，可以从后台队列交给
/// MainActor。`byteCost` 计入缓存与在屏纹理的字节上限；`metrics` 是含留白的 point 尺寸。
struct DanmakuTexturePayload: Sendable, Equatable {
    /// 像素格式约定只在这里，栅格化器建 `CGContext`、这里建 `CGImage` 都用这几项。
    ///
    /// 两边不一致时通道顺序、预乘或色彩空间会错位，弹幕颜色随之变掉。
    static let bitsPerComponent = 8
    static let bitmapInfo = CGBitmapInfo(
        rawValue: CGImageAlphaInfo.premultipliedLast.rawValue
    ).union(.byteOrder32Big)
    static let colorSpace =
        CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    let image: CGImage
    let backingScale: Double

    /// 用 `pixels`（`heightPixels` 行、每行 `bytesPerRow` 字节）建 `CGImage`，像素交给它持有、不拷贝。
    init?(
        pixels: Data,
        widthPixels: Int,
        heightPixels: Int,
        bytesPerRow: Int,
        backingScale: Double
    ) {
        guard let provider = CGDataProvider(data: pixels as CFData),
            let image = CGImage(
                width: widthPixels,
                height: heightPixels,
                bitsPerComponent: Self.bitsPerComponent,
                bitsPerPixel: Self.bitsPerComponent * 4,
                bytesPerRow: bytesPerRow,
                space: Self.colorSpace,
                bitmapInfo: Self.bitmapInfo,
                provider: provider,
                decode: nil,
                shouldInterpolate: true,
                intent: .defaultIntent
            )
        else {
            return nil
        }
        self.image = image
        self.backingScale = backingScale
    }

    var widthPixels: Int { image.width }
    var heightPixels: Int { image.height }
    var bytesPerRow: Int { image.bytesPerRow }
    var byteCost: Int { bytesPerRow * heightPixels }
    /// `image` 持有的像素字节；两张纹理按字节判等，不看是否同一个 `CGImage` 对象。
    var pixels: Data { image.dataProvider?.data as Data? ?? Data() }

    var metrics: DanmakuTextMetrics {
        DanmakuTextMetrics(
            width: Double(widthPixels) / backingScale,
            height: Double(heightPixels) / backingScale
        )
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.backingScale == rhs.backingScale
            && lhs.widthPixels == rhs.widthPixels
            && lhs.heightPixels == rhs.heightPixels
            && lhs.bytesPerRow == rhs.bytesPerRow
            && lhs.pixels == rhs.pixels
    }
}

/// 把一条弹幕栅格化为带描边与阴影的纹理：Core Text 排版，描边、阴影的生成与预乘 alpha 合成都交给
/// vImage。
///
/// 在纹理准备 owner 的后台队列调用，不读写共享状态。彩色字形（emoji）保留 Core Text 填充的 RGBA；
/// 描边与阴影的深浅只按弹幕声明的颜色、对整行字形的并集 mask 决定一次，不逐字形自适应，所以 emoji
/// 与文字混排时不会被压成同一种填充色。
enum DanmakuTextureRasterizer {
    /// 文本长度上限（UTF-16 单元）；更长的弹幕按 `invalidInput` 拒绝，不截断。
    static let maximumTextUTF16Length = 512
    /// 纹理像素宽度上限；超出的弹幕按 `oversized` 拒绝，不缩小显示。
    static let maximumWidthPixels = 8_192
    /// 纹理像素高度上限；超出时同样按 `oversized` 拒绝。
    static let maximumHeightPixels = 512
    /// 单个纹理的字节上限，也是纹理缓存的单项上限；宽度接近像素上限的长文本主要受它约束。
    static let maximumTextureByteCost = 8 * 1_024 * 1_024
    /// 支持的最大 backing scale；呈现控制器归一时把更大的值夹到这里。
    static let maximumBackingScale = 4.0
    /// 宿主还没报告窗口 backing scale 时的初值，也是非有限值的回退：Retina 屏是 2。
    static let defaultBackingScale = 2.0

    /// 窗口报告的 backing scale 归一到 1...`maximumBackingScale`，非有限值回退到 `defaultBackingScale`。
    ///
    /// 只由呈现控制器在 surface 更新时调用一次，再把结果交给 renderer 与 materializer；两边不再各自
    /// 归一，否则一边认为 scale 没变、另一边已经换了栅格倍率。
    static func normalizedBackingScale(_ scale: Double) -> Double {
        scale.isFinite ? min(max(scale, 1), maximumBackingScale) : defaultBackingScale
    }
    /// 描边宽度（point），由字形 alpha 向外膨胀得到。
    static let outlineWidthPoints = 0.5
    /// 字重与阴影是产品固定视觉，不随设置变化；阴影是预烘焙 tent convolution 的 point 半径。
    static let fontWeight = NSFont.Weight.semibold
    static let shadowRadiusPoints = 1.0
    /// 描边与阴影取浅色的判定阈值：文字颜色的相对亮度低于它时用浅色，否则用深色。
    ///
    /// 0.179 是与黑色、白色对比度相等的亮度分界（WCAG 相对亮度与对比度公式）。
    static let lightInkRelativeLuminanceThreshold = 0.179
    /// 大会员彩色弹幕的填充色；描边是 `vipGradientStops`。
    static let vipGradientFillRGB: UInt32 = 0xFF_FFFF
    /// 大会员渐变描边的色标：B 站 60001 描边贴图横向五等分采样，从文字左缘到右缘线性插值。
    static let vipGradientStops: [(red: UInt8, green: UInt8, blue: UInt8)] = [
        (0xF2, 0x50, 0x9E),
        (0xD4, 0x59, 0xA6),
        (0x90, 0x6E, 0xB6),
        (0x51, 0x81, 0xC5),
        (0x30, 0x8B, 0xCD)
    ]

    static func key(
        event: DanmakuEvent,
        backingScale: Double
    ) -> DanmakuTextureCacheKey? {
        guard let measureKey = measureKey(event: event, backingScale: backingScale) else {
            return nil
        }
        return DanmakuTextureCacheKey(
            text: measureKey.text,
            fontSize: measureKey.fontSize,
            isHighLike: measureKey.isHighLike,
            isUploader: measureKey.isUploader,
            colorRGB: event.colorStyle == .vipGradient
                ? vipGradientFillRGB : event.colorRGB & 0x00FF_FFFF,
            colorStyle: event.colorStyle,
            backingScale: measureKey.backingScale,
            isOwn: event.isOwn
        )
    }

    static func rasterize(
        key: DanmakuTextureCacheKey
    ) -> DanmakuTexturePayload? {
        let rgb = rgbComponents(key.colorRGB)
        let foreground = CGColor(srgbRed: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1)
        guard
            let layout = lineLayout(
                DanmakuTextMeasureKey(
                    text: key.text,
                    fontSize: key.fontSize,
                    isHighLike: key.isHighLike,
                    isUploader: key.isUploader,
                    backingScale: key.backingScale
                ),
                foreground: foreground
            ),
            let fill = calloc(layout.bytesPerRow * layout.heightPixels, 1)
        else {
            return nil
        }
        guard
            draw(layout, foreground: foreground, scale: CGFloat(key.backingScale), into: fill)
        else {
            free(fill)
            return nil
        }
        guard
            let pixels = composite(
                fill: fill,
                width: layout.widthPixels,
                height: layout.heightPixels,
                outlineRadiusPixels: layout.outlineRadiusPixels,
                shadowRadiusPixels: layout.shadowRadiusPixels,
                isLightDecoration: decorationIsLight(colorRGB: key.colorRGB),
                gradientColumns: key.colorStyle == .vipGradient
                    ? layout.paddingPixels..<(layout.widthPixels - layout.paddingPixels)
                    : nil
            )
        else {
            return nil
        }
        let scale = CGFloat(key.backingScale)
        guard
            let pixels = layout.uploaderStyle.map({ style in
                style.compose(
                    textPixels: pixels,
                    layout: layout,
                    scale: scale,
                    textLeft: CGFloat(layout.paddingPixels) / scale + style.leadingWidth
                )
            }) ?? pixels
        else {
            return nil
        }
        guard
            let pixels = key.isOwn
                ? DanmakuOwnBorder.compose(
                    pixels: pixels,
                    layout: layout,
                    scale: scale,
                    color: foreground
                ) : pixels
        else {
            return nil
        }
        return DanmakuTexturePayload(
            pixels: pixels,
            widthPixels: layout.widthPixels,
            heightPixels: layout.heightPixels,
            bytesPerRow: layout.bytesPerRow,
            backingScale: key.backingScale
        )
    }

    /// 在 Core Text 画好的字形填充上合成描边环与阴影，返回最终的预乘 RGBA 像素；任一步 vImage 失败时为 nil。
    ///
    /// `fill` 是 `width × height`、每行 `width × 4` 字节的预乘 RGBA，必须由 `malloc`／`calloc` 分配，所有权交给
    /// 这里：成功时由返回的 `Data` 接管、释放时 `free`，失败时在这里释放；调用方之后不得再访问。中间只另用一块
    /// RGBA 与两块 Planar8，结果直接交给 `Data` 不再拷贝：`fill` 先放字形，最后被阴影与结果覆盖；另一块 RGBA
    /// 先放描边环，叠上字形后是带描边的文字。`gradientColumns` 是文字所在的列，非 nil 时描边着大会员渐变，
    /// 否则描边与阴影同为 `isLightDecoration` 决定的单色。
    static func composite(
        fill: UnsafeMutableRawPointer,
        width: Int,
        height: Int,
        outlineRadiusPixels: Double,
        shadowRadiusPixels: Int,
        isLightDecoration: Bool,
        gradientColumns: Range<Int>?
    ) -> Data? {
        let rgbaByteCount = width * 4 * height
        let decoratedBytes = calloc(rgbaByteCount, 1)
        let alphaBytes = calloc(width * height, 1)
        let workBytes = calloc(width * height, 1)
        var output: UnsafeMutableRawPointer?
        defer {
            for buffer in [fill, decoratedBytes, alphaBytes, workBytes] where buffer != output {
                free(buffer)
            }
        }
        guard let decoratedBytes, let alphaBytes, let workBytes else { return nil }
        func image(_ data: UnsafeMutableRawPointer, bytesPerPixel: Int) -> vImage_Buffer {
            vImage_Buffer(
                data: data,
                height: vImagePixelCount(height),
                width: vImagePixelCount(width),
                rowBytes: width * bytesPerPixel
            )
        }
        let fillImage = image(fill, bytesPerPixel: 4)
        let decorated = image(decoratedBytes, bytesPerPixel: 4)
        let alpha = image(alphaBytes, bytesPerPixel: 1)
        let work = image(workBytes, bytesPerPixel: 1)

        // `decorated` 由 calloc 清零，深色单色描边只需写 alpha。
        guard extractAlpha(of: fillImage, into: alpha),
            outerRing(alpha: alpha, into: work, radiusPixels: outlineRadiusPixels),
            gradientColumns.map({ paintGradient(alpha: work, into: decorated, columns: $0) })
                ?? paintMonochrome(alpha: work, into: decorated, isLight: isLightDecoration),
            sourceOver(fillImage, onto: decorated)
        else {
            return nil
        }
        guard shadowRadiusPixels > 0 else {
            output = decoratedBytes
            return Data(bytesNoCopy: decoratedBytes, count: rgbaByteCount, deallocator: .free)
        }
        // 字形已经叠进 `decorated`，`fill` 改放阴影；深色阴影只写 alpha，先清掉字形的 RGB。
        if !isLightDecoration {
            memset(fill, 0, rgbaByteCount)
        }
        guard extractAlpha(of: decorated, into: alpha),
            tentBlur(alpha: alpha, into: work, radius: shadowRadiusPixels),
            paintMonochrome(alpha: work, into: fillImage, isLight: isLightDecoration),
            sourceOver(decorated, onto: fillImage)
        else {
            return nil
        }
        output = fill
        return Data(bytesNoCopy: fill, count: rgbaByteCount, deallocator: .free)
    }

    /// 取预乘 RGBA 的 alpha 通道到同尺寸的 Planar8。
    static func extractAlpha(of image: vImage_Buffer, into alpha: vImage_Buffer) -> Bool {
        var (image, alpha) = (image, alpha)
        // 通道下标按内存顺序，RGBA 的 alpha 是 3；函数名里的 ARGB 只表示四个 8 位通道。
        return vImageExtractChannel_ARGB8888(&image, &alpha, 3, noFlags) == kvImageNoError
    }

    /// 字形 alpha 向外膨胀 `radiusPixels` 后减去原 alpha 写进 `ring`，得到只在字形外侧的描边环。
    ///
    /// 半径不足整像素时按比例减弱。两块都是每行恰好 `width` 字节的连续 Planar8。
    static func outerRing(
        alpha: vImage_Buffer,
        into ring: vImage_Buffer,
        radiusPixels: Double
    ) -> Bool {
        var (alpha, ring) = (alpha, ring)
        let radius = max(1, Int(ceil(radiusPixels)))
        let size = vImagePixelCount(radius * 2 + 1)
        let error = vImageMax_Planar8(&alpha, &ring, nil, 0, 0, size, size, edgeExtend)
        guard error == kvImageNoError else { return false }
        // 膨胀核包含中心像素，膨胀结果逐像素不小于原 alpha，所以减法不会下溢，可以用不检查溢出的 `&-=`，
        // 连续内存上的这段循环由编译器向量化。
        let original = alpha.data.assumingMemoryBound(to: UInt8.self)
        let expanded = ring.data.assumingMemoryBound(to: UInt8.self)
        for index in 0..<Int(alpha.width * alpha.height) {
            expanded[index] &-= original[index]
        }
        let coverage = min(max(radiusPixels, 0) / Double(radius), 1)
        guard coverage < 1 else { return true }
        let table = (0...255).map { UInt8((Double($0) * coverage).rounded()) }
        return vImageTableLookUp_Planar8(&ring, &ring, table, noFlags) == kvImageNoError
    }

    /// 阴影用的 tent 模糊；`alpha` 与 `blurred` 是同尺寸的 Planar8。
    static func tentBlur(alpha: vImage_Buffer, into blurred: vImage_Buffer, radius: Int) -> Bool {
        var (alpha, blur) = (alpha, blurred)
        let size = UInt32(radius * 2 + 1)
        let error = vImageTentConvolve_Planar8(&alpha, &blur, nil, 0, 0, size, size, 0, edgeExtend)
        return error == kvImageNoError
    }

    /// 用单一灰阶（浅为白、深为黑）和给定 alpha 铺出预乘 RGBA。
    ///
    /// 深色只写 alpha 通道，调用方必须保证 `image` 的 RGB 已经是 0。
    static func paintMonochrome(
        alpha: vImage_Buffer,
        into image: vImage_Buffer,
        isLight: Bool
    ) -> Bool {
        guard isLight else { return overwriteAlpha(of: image, with: alpha) }
        var (alpha, image) = (alpha, image)
        let error = vImageConvert_Planar8toARGB8888(&alpha, &alpha, &alpha, &alpha, &image, noFlags)
        return error == kvImageNoError
    }

    /// 按列着色的渐变描边（预乘 alpha）：`columns` 是文字所在的列，左缘以左取首个色标、右缘以右取末个色标。
    static func paintGradient(
        alpha: vImage_Buffer,
        into image: vImage_Buffer,
        columns: Range<Int>
    ) -> Bool {
        var image = image
        let width = Int(image.width)
        let pixels = image.data.assumingMemoryBound(to: UInt8.self)
        let span = Double(max(1, columns.count))
        // 颜色只随列变化：先在第一行写不透明颜色，复制到其余各行，再换上描边 alpha 并预乘。
        for column in 0..<width {
            let color = vipGradientColor(at: Double(column - columns.lowerBound) / span)
            let offset = column * 4
            pixels[offset] = color.red
            pixels[offset + 1] = color.green
            pixels[offset + 2] = color.blue
            pixels[offset + 3] = 255
        }
        for row in stride(from: 1, to: Int(image.height), by: 1) {
            memcpy(pixels + row * image.rowBytes, pixels, width * 4)
        }
        return overwriteAlpha(of: image, with: alpha)
            && vImagePremultiplyData_RGBA8888(&image, &image, noFlags) == kvImageNoError
    }

    /// 渐变上 `position`（0 为左缘、1 为右缘，超出时取端点）处的颜色。
    static func vipGradientColor(
        at position: Double
    ) -> (red: UInt8, green: UInt8, blue: UInt8) {
        let stops = vipGradientStops
        let scaled = min(max(position, 0), 1) * Double(stops.count - 1)
        let lower = min(Int(scaled), stops.count - 2)
        let fraction = scaled - Double(lower)
        func mix(_ from: UInt8, _ to: UInt8) -> UInt8 {
            UInt8((Double(from) + (Double(to) - Double(from)) * fraction).rounded())
        }
        let from = stops[lower]
        let to = stops[lower + 1]
        return (mix(from.red, to.red), mix(from.green, to.green), mix(from.blue, to.blue))
    }

    /// 预乘 alpha 的 source-over，原地写回 `background`：每个通道为
    /// `前景 + ((255 − 前景 alpha) × 背景 + 127) / 255`。
    ///
    /// Swift 里 `_RGBA8888` 版本是 C 宏、不可调用；Alpha.h 注明 `_BGRA8888` 适用于任何 alpha 在末位的
    /// 四通道格式，颜色通道各自按同一公式计算。
    static func sourceOver(_ foreground: vImage_Buffer, onto background: vImage_Buffer) -> Bool {
        var (top, bottom) = (foreground, background)
        let error = vImagePremultipliedAlphaBlend_BGRA8888(&top, &bottom, &bottom, noFlags)
        return error == kvImageNoError
    }

    private static let noFlags = vImage_Flags(kvImageNoFlags)
    private static let edgeExtend = vImage_Flags(kvImageEdgeExtend)

    /// 只把 `alpha` 写进 RGBA 的 alpha 通道，RGB 不变。
    private static func overwriteAlpha(of image: vImage_Buffer, with alpha: vImage_Buffer) -> Bool {
        var (alpha, image) = (alpha, image)
        // copyMask 按 ARGB 记位，0x1 是内存里的第四个字节，也就是 RGBA 的 alpha。
        return vImageOverwriteChannels_ARGB8888(&alpha, &image, &image, 0x1, noFlags)
            == kvImageNoError
    }

    /// 把排好的一行字画进 `pixels`：`layout` 尺寸、已清零的预乘 RGBA。
    ///
    /// 高赞图标用 `foreground` 填充，与文字同色；之后的描边与阴影按整张 alpha 生成，图标与文字一并带上。
    private static func draw(
        _ layout: DanmakuTextLineLayout,
        foreground: CGColor,
        scale: CGFloat,
        into pixels: UnsafeMutableRawPointer
    ) -> Bool {
        guard
            let context = CGContext(
                data: pixels,
                width: layout.widthPixels,
                height: layout.heightPixels,
                bitsPerComponent: DanmakuTexturePayload.bitsPerComponent,
                bytesPerRow: layout.bytesPerRow,
                space: DanmakuTexturePayload.colorSpace,
                bitmapInfo: DanmakuTexturePayload.bitmapInfo.rawValue
            )
        else {
            return false
        }
        context.scaleBy(x: scale, y: scale)
        let padding = CGFloat(layout.paddingPixels) / scale
        let baseline = padding + layout.descent
        // UP 主弹幕先让出黑底左留白与标签，标签在合成之后才画（见 `DanmakuUploaderStyle.compose`）。
        var textX = padding + (layout.uploaderStyle?.leadingWidth ?? 0)
        if let icon = layout.highLikeIcon {
            let iconRect = CGRect(
                origin: CGPoint(x: textX, y: baseline - icon.descentBelowBaseline),
                size: icon.size
            )
            context.saveGState()
            context.clip(to: iconRect, mask: icon.mask)
            context.setFillColor(foreground)
            context.fill(iconRect)
            context.restoreGState()
            textX += icon.size.width + icon.spacing
        }
        context.textPosition = CGPoint(x: textX, y: baseline)
        CTLineDraw(layout.line, context)
        return true
    }

    private static func decorationIsLight(colorRGB: UInt32) -> Bool {
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
}
