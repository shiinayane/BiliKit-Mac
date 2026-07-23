import AppKit
import AVKit
import BiliDanmaku
import SwiftUI
import Testing
@testable import BiliKit

struct PlayerHostLifecycleProbeTests {
    @Test
    @MainActor
    func hostedPlayerBoundaryReportsOneActiveHostThenReturnsToZero() async throws {
        let probe = PlayerHostLifecycleProbe()
        let renderer = CoreAnimationDanmakuRenderer()
        let controller = DanmakuPresentationController(
            backend: renderer,
            configuration: DanmakuLaneConfiguration(
                surfaceWidth: 0,
                surfaceHeight: 0,
                laneHeight: 36,
                minimumHorizontalGap: 12,
                maximumActiveCount:
                    DanmakuLaneConfiguration.hardMaximumActiveCount,
                displayAreaFraction: 1
            )
        )
        let player = AVPlayer()
        func makeHostingView() -> NSHostingView<AnyView> {
            NSHostingView(
                rootView: AnyView(
                    PlayerHostView(
                        player: player,
                        danmakuRenderer: renderer,
                        danmakuController: controller,
                        lifecycleProbe: probe
                    ) {
                        EmptyView()
                    }
                )
            )
        }
        var hostingView: NSHostingView<AnyView>? = makeHostingView()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 360),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        window.contentView = hostingView
        window.layoutIfNeeded()
        #expect(await waitUntil { probe.activeCount == 1 })

        #expect(probe.activeCount == 1)
        #expect(probe.peakActiveCount == 1)

        window.contentView = NSView()
        hostingView = nil
        #expect(await waitUntil { probe.activeCount == 0 })

        #expect(probe.activeCount == 0)

        hostingView = makeHostingView()
        window.contentView = hostingView
        window.layoutIfNeeded()
        #expect(await waitUntil { probe.activeCount == 1 })

        #expect(probe.activeCount == 1)
        #expect(probe.peakActiveCount == 1)

        window.contentView = NSView()
        hostingView = nil
        #expect(await waitUntil { probe.activeCount == 0 })

        #expect(probe.activeCount == 0)
        #expect(probe.peakActiveCount == 1)
    }

    @MainActor
    private func waitUntil(
        _ condition: @MainActor () -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))
        while !condition() {
            guard clock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return true
    }
}
