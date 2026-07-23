import AppKit
import BiliDanmaku

@MainActor
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
        if window == nil {
            detachSurface()
        } else {
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

    func updateSurfaceIfNeeded() {
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
