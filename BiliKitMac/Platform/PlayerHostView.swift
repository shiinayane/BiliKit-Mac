import AVKit
import SwiftUI

struct PlayerHostView<Overlay: View>: View {
    let player: AVPlayer
    let overlay: () -> Overlay

    init(
        player: AVPlayer,
        @ViewBuilder overlay: @escaping () -> Overlay
    ) {
        self.player = player
        self.overlay = overlay
    }

    var body: some View {
        ZStack {
            AVPlayerContainerView(player: player)
            overlay()
        }
    }
}

private struct AVPlayerContainerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .floating
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player {
            view.player = player
        }
    }
}
