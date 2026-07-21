import CoreGraphics

public protocol AuthenticationQRCodeProviding: Sendable {
    func makeQRCodeImage(scale: Int) async throws -> CGImage?
}
