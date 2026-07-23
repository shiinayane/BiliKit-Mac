import AppKit
import BiliApplication
import BiliDanmaku
import BiliModels
import QuartzCore

@MainActor
enum RendererLoadProbe {
    static func run(arguments: [String]) async throws {
        let configuration = try Configuration(arguments: arguments)
        let renderer = CoreAnimationDanmakuRenderer(
            contentsScale: Double(
                NSScreen.main?.backingScaleFactor ?? 2
            )
        )
        let controller = DanmakuPresentationController(
            backend: renderer,
            configuration: laneConfiguration
        )
        let ownerID = UUID()
        let surface = makeSurface(renderer: renderer)
        let window = makeWindow(contentView: surface)

        controller.attachSurface(ownerID: ownerID)
        controller.updateSurface(laneConfiguration, ownerID: ownerID)
        window.makeKeyAndOrderFront(nil as Any?)
        NSApplication.shared.activate(ignoringOtherApps: true)

        let identity = PlaybackItemIdentity(
            bvid: "BV0000000000",
            cid: 1
        )
        var didCleanUp = false
        func cleanUp() {
            guard !didCleanUp else { return }
            didCleanUp = true
            controller.stopPresentation()
            _ = controller.detachSurface(ownerID: ownerID)
            renderer.rootLayer.removeFromSuperlayer()
            window.orderOut(nil as Any?)
            window.close()
        }
        defer { cleanUp() }

        let start = CACurrentMediaTime()
        var emitted = 0
        var maximumLatenessSeconds = 0.0
        let targetCount = Int(
            (configuration.durationSeconds * Double(configuration.rate))
                .rounded(.down)
        )

        for index in 0..<targetCount {
            let deadline = start
                + Double(index + 1) / Double(configuration.rate)
            let remainingSeconds = deadline - CACurrentMediaTime()
            if remainingSeconds > 0 {
                try await Task.sleep(
                    for: .nanoseconds(
                        Int64(remainingSeconds * 1_000_000_000)
                    )
                )
            }
            let emissionTime = CACurrentMediaTime()
            maximumLatenessSeconds = max(
                maximumLatenessSeconds,
                emissionTime - deadline
            )
            let elapsed = emissionTime - start
            controller.apply(
                update(
                    identity: identity,
                    positionSeconds: elapsed,
                    events: [event(index: index, timeSeconds: elapsed)]
                )
            )
            emitted += 1
        }

        let actualElapsedSeconds = CACurrentMediaTime() - start
        let effectiveRate = Double(emitted) / actualElapsedSeconds
        let beforeStop = renderer.activeLayerCount
        let statistics = controller.statistics
        cleanUp()

        let activeAfterStop = controller.statistics.active
        let layersAfterStop = renderer.activeLayerCount
        let rootAttachedAfterStop = renderer.rootLayer.superlayer != nil
        let fields = [
            "renderer-production",
            "rate=\(configuration.rate)",
            "requested-duration=\(configuration.durationSeconds)",
            "actual-duration=\(formatted(actualElapsedSeconds))",
            "effective-rate=\(formatted(effectiveRate))",
            "max-lateness-ms=\(formatted(maximumLatenessSeconds * 1_000))",
            "emitted=\(emitted)",
            "admitted=\(statistics.admitted)",
            "dropped-no-lane=\(statistics.droppedNoLane)",
            "dropped-capacity=\(statistics.droppedCapacity)",
            "peak=\(statistics.peakActive)",
            "active-before-stop=\(beforeStop)",
            "active-after-stop=\(activeAfterStop)",
            "layers-after-stop=\(layersAfterStop)",
            "root-attached-after-stop=\(rootAttachedAfterStop ? 1 : 0)",
        ]
        print(fields.joined(separator: " "))
        guard emitted == targetCount,
              activeAfterStop == 0,
              layersAfterStop == 0,
              !rootAttachedAfterStop
        else {
            throw DanmakuApplicationError.invalidResponse
        }
    }

    private static let laneConfiguration = DanmakuLaneConfiguration(
        surfaceWidth: 1_280,
        surfaceHeight: 720,
        laneHeight: 36,
        minimumHorizontalGap: 12,
        maximumActiveCount:
            DanmakuLaneConfiguration.hardMaximumActiveCount,
        displayAreaFraction: 1
    )

    private static func makeSurface(
        renderer: CoreAnimationDanmakuRenderer
    ) -> NSView {
        let view = NSView(
            frame: NSRect(x: 0, y: 0, width: 1_280, height: 720)
        )
        view.wantsLayer = true
        view.layer = CALayer()
        view.layer?.backgroundColor = NSColor.black.cgColor
        view.layer?.addSublayer(renderer.rootLayer)
        return view
    }

    private static func makeWindow(contentView: NSView) -> NSWindow {
        let window = NSWindow(
            contentRect: contentView.frame,
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "BiliKit M4.4 Renderer Probe"
        window.contentView = contentView
        return window
    }

    private static func update(
        identity: PlaybackItemIdentity,
        positionSeconds: Double,
        events: [DanmakuEvent]
    ) -> DanmakuPresentationUpdate {
        DanmakuPresentationUpdate(
            snapshot: PlaybackTimelineSnapshot(
                identity: identity,
                positionSeconds: positionSeconds,
                durationSeconds: nil,
                rate: 1,
                state: .playing,
                discontinuityGeneration: 1
            ),
            batch: DanmakuBatch(
                identity: identity,
                discontinuityGeneration: 1,
                events: events,
                clearsExisting: false
            )
        )
    }

    private static func event(
        index: Int,
        timeSeconds: Double
    ) -> DanmakuEvent {
        let modes: [DanmakuPresentationMode] = [
            .scrolling, .scrolling, .scrolling, .top, .bottom,
        ]
        return DanmakuEvent(
            id: "synthetic-\(index)",
            timeSeconds: timeSeconds,
            mode: modes[index % modes.count],
            text: "中文 日本語 한국어 Latin 😀 # \(index % 100)",
            fontSize: 24,
            colorRGB: 0xFFFFFF,
            weight: 1
        )
    }

    private static func formatted(_ value: Double) -> String {
        String(format: "%.3f", value)
    }
}

private struct Configuration {
    let rate: Int
    let durationSeconds: Double

    init(arguments: [String]) throws {
        let arguments = Array(arguments.dropFirst())
        guard arguments.count == 4 else {
            throw DanmakuApplicationError.invalidRequest
        }
        var values: [String: String] = [:]
        var index = 0
        while index < arguments.count {
            let name = arguments[index]
            guard name.hasPrefix("--"), values[name] == nil else {
                throw DanmakuApplicationError.invalidRequest
            }
            values[name] = arguments[index + 1]
            index += 2
        }
        guard values.count == 2,
              let rawRate = values["--renderer-rate"],
              let rate = Int(rawRate),
              rate == 40 || rate == 80,
              let rawDuration = values["--duration"],
              let durationSeconds = Double(rawDuration),
              durationSeconds.isFinite,
              (1...1_800).contains(durationSeconds)
        else {
            throw DanmakuApplicationError.invalidRequest
        }
        self.rate = rate
        self.durationSeconds = durationSeconds
    }
}
