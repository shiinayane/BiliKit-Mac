import AVKit
import BiliDanmaku
import SwiftUI

/// 把唯一 `AVPlayer` 宿主与字幕、弹幕 overlay 组合为稳定的播放 surface。
///
/// 响应式页面可以重排这个 View，但不应创建第二个 player host；AppKit host 的销毁会
/// 主动断开 player 并释放弹幕 surface ownership。
struct PlayerHostView<Overlay: View>: View {
    let player: AVPlayer
    let danmakuRenderer: CoreAnimationDanmakuRenderer
    let danmakuController: DanmakuPresentationController
    let lifecycleProbe: PlayerHostLifecycleProbe?
    let overlay: () -> Overlay

    init(
        player: AVPlayer,
        danmakuRenderer: CoreAnimationDanmakuRenderer,
        danmakuController: DanmakuPresentationController,
        lifecycleProbe: PlayerHostLifecycleProbe? = nil,
        @ViewBuilder overlay: @escaping () -> Overlay
    ) {
        self.player = player
        self.danmakuRenderer = danmakuRenderer
        self.danmakuController = danmakuController
        self.lifecycleProbe = lifecycleProbe
        self.overlay = overlay
    }

    var body: some View {
        ZStack {
            AVPlayerContainerView(
                player: player,
                renderer: danmakuRenderer,
                controller: danmakuController,
                lifecycleProbe: lifecycleProbe
            )
            overlay()
        }
    }
}

@MainActor
final class PlayerHostLifecycleProbe {
    enum Event: Equatable {
        case created(ObjectIdentifier)
        case dismantled(ObjectIdentifier)
    }

    private(set) var activeCount = 0
    private(set) var peakActiveCount = 0
    private(set) var events: [Event] = []
    private var activeIdentities: Set<ObjectIdentifier> = []

    func didCreate(_ host: AnyObject) {
        let identity = ObjectIdentifier(host)
        guard activeIdentities.insert(identity).inserted else { return }
        events.append(.created(identity))
        activeCount = activeIdentities.count
        peakActiveCount = max(peakActiveCount, activeCount)
    }

    func didDismantle(_ host: AnyObject) {
        let identity = ObjectIdentifier(host)
        guard activeIdentities.remove(identity) != nil else { return }
        events.append(.dismantled(identity))
        activeCount = activeIdentities.count
    }
}

private struct AVPlayerContainerView: NSViewRepresentable {
    let player: AVPlayer
    let renderer: CoreAnimationDanmakuRenderer
    let controller: DanmakuPresentationController
    let lifecycleProbe: PlayerHostLifecycleProbe?

    final class Coordinator {
        let lifecycleProbe: PlayerHostLifecycleProbe?

        init(lifecycleProbe: PlayerHostLifecycleProbe?) {
            self.lifecycleProbe = lifecycleProbe
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(lifecycleProbe: lifecycleProbe)
    }

    func makeNSView(context: Context) -> DanmakuPlayerView {
        let view = DanmakuPlayerView(
            renderer: renderer,
            controller: controller
        )
        view.player = player
        view.controlsStyle = .floating
        context.coordinator.lifecycleProbe?.didCreate(view)
        return view
    }

    func updateNSView(_ view: DanmakuPlayerView, context: Context) {
        if view.player !== player {
            view.player = player
        }
    }

    /// 在 SwiftUI 销毁宿主时先撤销弹幕 surface，再断开 AVPlayer，避免旧 host 继续呈现。
    static func dismantleNSView(
        _ view: DanmakuPlayerView,
        coordinator: Coordinator
    ) {
        view.danmakuOverlay.detachSurface()
        view.player = nil
        coordinator.lifecycleProbe?.didDismantle(view)
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
