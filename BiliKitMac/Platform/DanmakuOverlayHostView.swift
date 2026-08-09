import AppKit
import BiliDanmaku

@MainActor
/// 将 renderer 的 layer 挂到当前 `AVPlayerView` overlay，并独占其尺寸更新权。
///
/// `ownerID` 防止已拆除 host 的迟到 layout/detach 清空新 host；零尺寸只表示 surface
/// 尚未完成布局，不会扩大为另一个渲染会话。
final class DanmakuOverlayView: NSView {
    private let renderer: CoreAnimationDanmakuRenderer
    private let controller: DanmakuPresentationController
    private let ownerID = UUID()
    private var previousSize: CGSize?
    private var isSurfaceAttached = false

    init(
        renderer: CoreAnimationDanmakuRenderer,
        controller: DanmakuPresentationController
    ) {
        self.renderer = renderer
        self.controller = controller
        super.init(frame: .zero)
        wantsLayer = true
        layer = CALayer()
        layer?.masksToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            attachSurfaceIfNeeded()
        }
    }

    override func layout() {
        super.layout()
        updateSurfaceIfNeeded()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    /// 仅由当前 surface owner 发布布局尺寸；已有弹幕保留运动，新弹幕使用最新尺寸。
    func updateSurfaceIfNeeded() {
        guard bounds.width > 0, bounds.height > 0 else { return }
        guard bounds.size != previousSize else { return }
        previousSize = bounds.size
        let width = max(Double(bounds.width), 0)
        let height = max(Double(bounds.height), 0)
        controller.updateSurface(
            DanmakuLaneConfiguration(
                surfaceWidth: width,
                surfaceHeight: height,
                laneHeight: 36,
                minimumHorizontalGap: 12,
                maximumActiveCount:
                    DanmakuLaneConfiguration.hardMaximumActiveCount,
                displayAreaFraction: 1
            ),
            ownerID: ownerID
        )
    }

    /// 撤销当前 host 的 ownership；不是 owner 时不会触碰后来接管的 surface。
    func detachSurface() {
        guard isSurfaceAttached else { return }
        isSurfaceAttached = false
        if controller.detachSurface(ownerID: ownerID) {
            renderer.rootLayer.removeFromSuperlayer()
        }
    }

    private func attachSurfaceIfNeeded() {
        guard !isSurfaceAttached else { return }
        isSurfaceAttached = true
        controller.attachSurface(ownerID: ownerID)
        layer?.addSublayer(renderer.rootLayer)
        previousSize = nil
        updateSurfaceIfNeeded()
    }
}
