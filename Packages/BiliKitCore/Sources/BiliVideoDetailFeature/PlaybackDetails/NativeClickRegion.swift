import AppKit

/// 视图里一组限定区域的点击入口：只在这些区域内响应单击。
///
/// 点击手势挂在宿主视图上，子视图的点击也会送到这里；不限定区域的话，点到正文或签名也会误触发。
/// 宿主在 init 里调用一次 `attach(to:onClick:)`，布局或内容变化后用 `setRects(_:)` 给出当前区域。
/// 区域内刻意保持箭头指针：HIG 只给指向 URL 的链接用手形，进入空间是应用内操作。
@MainActor
final class NativeClickRegion: NSObject, NSGestureRecognizerDelegate {
    private weak var host: NSView?
    private var onClick: (@MainActor () -> Void)?
    /// 宿主坐标系里的可点区域；为空时整块都不可点。
    private(set) var rects: [NSRect] = []
    private lazy var recognizer = NSClickGestureRecognizer(
        target: self,
        action: #selector(click)
    )

    func attach(to host: NSView, onClick: @escaping @MainActor () -> Void) {
        self.host = host
        self.onClick = onClick
        recognizer.delegate = self
        host.addGestureRecognizer(recognizer)
    }

    func setRects(_ rects: [NSRect]) {
        self.rects = rects.filter { !$0.isEmpty }
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: NSGestureRecognizer) -> Bool {
        guard let host else { return false }
        let location = gestureRecognizer.location(in: host)
        return rects.contains { $0.contains(location) }
    }

    @objc private func click() {
        onClick?()
    }
}
