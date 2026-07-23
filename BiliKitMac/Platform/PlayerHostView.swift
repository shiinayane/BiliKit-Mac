import AVKit
import BiliDanmaku
import SwiftUI

struct PlayerHostView<Overlay: View>: View {
    let player: AVPlayer
    let danmakuRenderer: CoreAnimationDanmakuRenderer
    let danmakuController: DanmakuPresentationController
    let overlay: () -> Overlay

    init(
        player: AVPlayer,
        danmakuRenderer: CoreAnimationDanmakuRenderer,
        danmakuController: DanmakuPresentationController,
        @ViewBuilder overlay: @escaping () -> Overlay
    ) {
        self.player = player
        self.danmakuRenderer = danmakuRenderer
        self.danmakuController = danmakuController
        self.overlay = overlay
    }

    var body: some View {
        ZStack {
            AVPlayerContainerView(
                player: player,
                renderer: danmakuRenderer,
                controller: danmakuController
            )
            overlay()
        }
    }
}

private struct AVPlayerContainerView: NSViewRepresentable {
    let player: AVPlayer
    let renderer: CoreAnimationDanmakuRenderer
    let controller: DanmakuPresentationController

    func makeNSView(context: Context) -> DanmakuPlayerView {
        let view = DanmakuPlayerView(
            renderer: renderer,
            controller: controller
        )
        view.player = player
        view.controlsStyle = .floating
        return view
    }

    func updateNSView(_ view: DanmakuPlayerView, context: Context) {
        if view.player !== player {
            view.player = player
        }
    }

    static func dismantleNSView(
        _ view: DanmakuPlayerView,
        coordinator: ()
    ) {
        view.danmakuOverlay.detachSurface()
    }
}

@MainActor
private final class DanmakuPlayerView: AVPlayerView {
    let danmakuOverlay: DanmakuOverlayView
    private var installedDanmakuOverlay = false

    init(
        renderer: CoreAnimationDanmakuRenderer,
        controller: DanmakuPresentationController
    ) {
        danmakuOverlay = DanmakuOverlayView(
            renderer: renderer,
            controller: controller
        )
        super.init(frame: .zero)
        installDanmakuOverlayIfNeeded()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        installDanmakuOverlayIfNeeded()
    }

    private func installDanmakuOverlayIfNeeded() {
        guard !installedDanmakuOverlay,
              let contentOverlayView
        else {
            return
        }
        installedDanmakuOverlay = true
        danmakuOverlay.translatesAutoresizingMaskIntoConstraints = false
        contentOverlayView.addSubview(danmakuOverlay)
        NSLayoutConstraint.activate([
            danmakuOverlay.leadingAnchor.constraint(
                equalTo: contentOverlayView.leadingAnchor
            ),
            danmakuOverlay.trailingAnchor.constraint(
                equalTo: contentOverlayView.trailingAnchor
            ),
            danmakuOverlay.topAnchor.constraint(
                equalTo: contentOverlayView.topAnchor
            ),
            danmakuOverlay.bottomAnchor.constraint(
                equalTo: contentOverlayView.bottomAnchor
            ),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }
}
