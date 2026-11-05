import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

/// 封装不可公开读取的完整二维码 payload，只允许在内存中渲染。
public struct TVQRCode: Sendable, Equatable, CustomStringConvertible,
    CustomDebugStringConvertible, CustomReflectable
{
    let payload: String

    init(payload: String) {
        self.payload = payload
    }

    public var description: String {
        "<tv-qr-code>"
    }

    public var debugDescription: String {
        description
    }

    public var customMirror: Mirror {
        Mirror(self, children: [:], displayStyle: .struct)
    }

    public func makeCGImage(scale: Int = 12) throws -> CGImage {
        guard (1...32).contains(scale) else {
            throw TVQRCodeRenderingError.invalidScale
        }

        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(payload.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else {
            throw TVQRCodeRenderingError.generationFailed
        }

        let scaled = output.transformed(
            by: CGAffineTransform(scaleX: CGFloat(scale), y: CGFloat(scale))
        )
        let context = CIContext(options: [.useSoftwareRenderer: true])
        guard let image = context.createCGImage(scaled, from: scaled.extent) else {
            throw TVQRCodeRenderingError.generationFailed
        }
        return image
    }
}

/// 二维码渲染失败：倍率不在 1...32，或 Core Image 未能生成图像。
public enum TVQRCodeRenderingError: Error, Sendable, Equatable {
    case invalidScale
    case generationFailed
}
