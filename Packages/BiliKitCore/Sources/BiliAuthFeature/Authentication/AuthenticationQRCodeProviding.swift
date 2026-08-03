import CoreGraphics

/// Presentation 专用的二维码图像 port，使 Feature 无需取得完整 QR URL 或 challenge key。
///
/// `CGImage` 不进入 `BiliApplication`；具体认证 adapter 只在内存中渲染当前 challenge。
public protocol AuthenticationQRCodeProviding: Sendable {
    func makeQRCodeImage(scale: Int) async throws -> CGImage?
}
