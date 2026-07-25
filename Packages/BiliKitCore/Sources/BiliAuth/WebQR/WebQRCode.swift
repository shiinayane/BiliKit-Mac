import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

public struct WebQRCode: Sendable, Equatable, CustomStringConvertible,
    CustomDebugStringConvertible, CustomReflectable
{
    let payload: String

    init(payload: String) {
        self.payload = payload
    }

    public var host: String {
        URL(string: payload)?.host ?? ""
    }

    public var description: String {
        "<web-qr-code>"
    }

    public var debugDescription: String {
        description
    }

    public var customMirror: Mirror {
        Mirror(self, children: [:], displayStyle: .struct)
    }

    public func makeCGImage(scale: Int = 12) throws -> CGImage {
        guard (1...32).contains(scale) else {
            throw WebQRCodeRenderingError.invalidScale
        }

        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(payload.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else {
            throw WebQRCodeRenderingError.generationFailed
        }

        let scaled = output.transformed(
            by: CGAffineTransform(scaleX: CGFloat(scale), y: CGFloat(scale))
        )
        let context = CIContext(options: [.useSoftwareRenderer: true])
        guard let image = context.createCGImage(scaled, from: scaled.extent) else {
            throw WebQRCodeRenderingError.generationFailed
        }
        return image
    }
}

public enum WebQRCodeRenderingError: Error, Sendable, Equatable {
    case invalidScale
    case generationFailed
}
