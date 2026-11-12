import AppKit

/// 本窗口自己发出的弹幕的边框：沿纹理外缘画一圈与正文同色的细框，和网页播放器标出自己发送的弹幕一样。
///
/// 画在纹理四周已有的留白里（至少 4 像素，见 `DanmakuTextureRasterizer.lineLayout`），不改纹理尺寸，所以测量、车道布局
/// 与缓存的字节上限都不受影响。由 `DanmakuTextureRasterizer.rasterize` 在文字与 UP 主样式合成之后调用。
enum DanmakuOwnBorder {
    /// 边框线宽（point）。
    static let lineWidthPoints = 1.0

    /// 在已合成的像素上叠一圈边框，返回同尺寸的预乘 RGBA；失败时为 nil。
    ///
    /// `pixels` 与返回值的像素格式都是 `DanmakuTexturePayload` 的约定。
    static func compose(
        pixels: Data,
        layout: DanmakuTextLineLayout,
        scale: CGFloat,
        color: CGColor
    ) -> Data? {
        guard
            let source = DanmakuTexturePayload(
                pixels: pixels,
                widthPixels: layout.widthPixels,
                heightPixels: layout.heightPixels,
                bytesPerRow: layout.bytesPerRow,
                backingScale: Double(scale)
            ),
            let buffer = calloc(layout.bytesPerRow * layout.heightPixels, 1)
        else {
            return nil
        }
        guard
            let context = CGContext(
                data: buffer,
                width: layout.widthPixels,
                height: layout.heightPixels,
                bitsPerComponent: DanmakuTexturePayload.bitsPerComponent,
                bytesPerRow: layout.bytesPerRow,
                space: DanmakuTexturePayload.colorSpace,
                bitmapInfo: DanmakuTexturePayload.bitmapInfo.rawValue
            )
        else {
            free(buffer)
            return nil
        }
        let width = CGFloat(layout.widthPixels) / scale
        let height = CGFloat(layout.heightPixels) / scale
        context.scaleBy(x: scale, y: scale)
        context.draw(source.image, in: CGRect(x: 0, y: 0, width: width, height: height))
        // 线条整条落在纹理里：中心线内缩半个线宽，再留 1 像素免得贴边被采样裁掉。
        let inset = CGFloat(lineWidthPoints) / 2 + 1 / scale
        context.setStrokeColor(color)
        context.setLineWidth(CGFloat(lineWidthPoints))
        context.stroke(
            CGRect(x: 0, y: 0, width: width, height: height).insetBy(dx: inset, dy: inset)
        )
        return Data(
            bytesNoCopy: buffer,
            count: layout.bytesPerRow * layout.heightPixels,
            deallocator: .free
        )
    }
}
