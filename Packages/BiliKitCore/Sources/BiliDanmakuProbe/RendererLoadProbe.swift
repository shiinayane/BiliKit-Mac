import AppKit
import BiliApplication
import BiliDanmaku
import BiliModels
import Darwin.Mach
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
        let identity = PlaybackItemIdentity(
            bvid: "BV0000000000",
            cid: 1
        )
        let timeline = RendererProbeTimeline()
        let repository = RendererProbeRepository(rate: configuration.rate)
        let session = DanmakuSession(
            useCase: DanmakuSegmentUseCase(repository: repository),
            timeline: timeline,
            presentationSink: controller
        )

        controller.attachSurface(ownerID: ownerID)
        controller.updateSurface(laneConfiguration, ownerID: ownerID)
        window.makeKeyAndOrderFront(nil as Any?)
        NSApplication.shared.activate(ignoringOtherApps: true)

        var didCleanUp = false
        func cleanUpSurface() {
            guard !didCleanUp else { return }
            didCleanUp = true
            _ = controller.detachSurface(ownerID: ownerID)
            renderer.rootLayer.removeFromSuperlayer()
            window.orderOut(nil as Any?)
            window.close()
        }
        defer {
            session.stop()
            cleanUpSurface()
        }

        session.start(for: identity)
        timeline.publish(
            snapshot(
                identity: identity,
                positionSeconds: 0,
                durationSeconds: configuration.durationSeconds
            )
        )
        try await waitUntilReady(session, identity: identity)
        await session.waitForLoads()

        let start = CACurrentMediaTime()
        var emitted = 0
        var maximumLatenessSeconds = 0.0
        var residentMemorySamples = [residentMemoryBytes()]
        var nextResidentMemorySampleTime = start + 60
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
            timeline.publish(
                snapshot(
                    identity: identity,
                    positionSeconds: elapsed,
                    durationSeconds: configuration.durationSeconds
                )
            )
            emitted += 1
            if emissionTime >= nextResidentMemorySampleTime {
                residentMemorySamples.append(residentMemoryBytes())
                nextResidentMemorySampleTime += 60
            }
        }

        let actualElapsedSeconds = CACurrentMediaTime() - start
        let effectiveRate = Double(emitted) / actualElapsedSeconds
        await Task.yield()
        let beforeStop = renderer.activeLayerCount
        let statistics = controller.statistics
        residentMemorySamples.append(residentMemoryBytes())
        session.stop()
        for _ in 0..<20 where timeline.subscriberCount > 0 {
            await Task.yield()
        }
        let timelineSubscribersAfterStop = timeline.subscriberCount
        let requestedSegmentCount = await repository.requestedSegmentIndices.count
        let crossedRetentionWindow =
            requestedSegmentCount > DanmakuScheduler.maximumCachedSegments
        let shouldCrossRetentionWindow =
            configuration.durationSeconds
                > DanmakuScheduler.segmentDurationSeconds
                    * Double(DanmakuScheduler.maximumCachedSegments)
        let accountedEventCount = statistics.admitted
            + statistics.droppedNoLane
            + statistics.droppedCapacity
        let sessionStopped = session.state == .idle
        cleanUpSurface()

        let activeAfterStop = controller.statistics.active
        let layersAfterStop = renderer.activeLayerCount
        let rootAttachedAfterStop = renderer.rootLayer.superlayer != nil
        let residentMemoryAfterStop = residentMemoryBytes()
        guard residentMemorySamples.allSatisfy({ $0 > 0 }),
              residentMemoryAfterStop > 0
        else {
            throw DanmakuApplicationError.invalidResponse
        }
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
            "segments-requested=\(requestedSegmentCount)",
            "retention-window-crossed=\(crossedRetentionWindow ? 1 : 0)",
            "timeline-subscribers-after-stop=\(timelineSubscribersAfterStop)",
            "session-idle-after-stop=\(sessionStopped ? 1 : 0)",
            "rss-samples-mib=\(residentMemorySamples.map(formattedMiB).joined(separator: ","))",
            "rss-sample-max-mib=\(formattedMiB(residentMemorySamples.max() ?? 0))",
            "rss-immediate-after-stop-mib=\(formattedMiB(residentMemoryAfterStop))",
        ]
        print(fields.joined(separator: " "))
        guard emitted == targetCount,
              activeAfterStop == 0,
              layersAfterStop == 0,
              !rootAttachedAfterStop,
              requestedSegmentCount > 0,
              accountedEventCount == targetCount,
              !shouldCrossRetentionWindow || crossedRetentionWindow,
              timelineSubscribersAfterStop == 0,
              sessionStopped
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

    private static func snapshot(
        identity: PlaybackItemIdentity,
        positionSeconds: Double,
        durationSeconds: Double
    ) -> PlaybackTimelineSnapshot {
        PlaybackTimelineSnapshot(
            identity: identity,
            positionSeconds: positionSeconds,
            durationSeconds: durationSeconds,
            rate: 1,
            state: .playing,
            discontinuityGeneration: 1
        )
    }

    nonisolated fileprivate static func event(
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

    private static func formattedMiB(_ bytes: UInt64) -> String {
        formatted(Double(bytes) / 1_048_576)
    }

    private static func waitUntilReady(
        _ session: DanmakuSession,
        identity: PlaybackItemIdentity
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while session.state != .ready(identity), clock.now < deadline {
            if case .failed = session.state {
                throw DanmakuApplicationError.invalidResponse
            }
            await Task.yield()
        }
        guard session.state == .ready(identity) else {
            throw DanmakuApplicationError.unavailable
        }
    }

    private static func residentMemoryBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info_data_t>.stride
                / MemoryLayout<natural_t>.stride
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(
                to: integer_t.self,
                capacity: Int(count)
            ) { reboundPointer in
                task_info(
                    mach_task_self_,
                    task_flavor_t(MACH_TASK_BASIC_INFO),
                    reboundPointer,
                    &count
                )
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return UInt64(info.resident_size)
    }
}

@MainActor
private final class RendererProbeTimeline: PlaybackTimelineProviding {
    private var snapshot = PlaybackTimelineSnapshot.idle
    private var continuations: [
        UUID: AsyncStream<PlaybackTimelineSnapshot>.Continuation
    ] = [:]

    var currentTimelineSnapshot: PlaybackTimelineSnapshot { snapshot }
    var subscriberCount: Int { continuations.count }

    func timelineUpdates() -> AsyncStream<PlaybackTimelineSnapshot> {
        let id = UUID()
        let stream = AsyncStream<PlaybackTimelineSnapshot>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        continuations[id] = stream.continuation
        stream.continuation.yield(snapshot)
        stream.continuation.onTermination = { [weak self] _ in
            Task { @MainActor in
                self?.continuations.removeValue(forKey: id)
            }
        }
        return stream.stream
    }

    func publish(_ snapshot: PlaybackTimelineSnapshot) {
        self.snapshot = snapshot
        continuations.values.forEach { $0.yield(snapshot) }
    }
}

private actor RendererProbeRepository: DanmakuSegmentRepository {
    let rate: Int
    private(set) var requestedSegmentIndices: Set<Int> = []

    init(rate: Int) {
        self.rate = rate
    }

    func segment(
        index: Int,
        for identity: PlaybackItemIdentity
    ) async throws -> DanmakuSegment {
        guard identity.cid > 0,
              (1...DanmakuSegmentUseCase.maximumSegmentIndex).contains(index)
        else {
            throw DanmakuApplicationError.invalidRequest
        }
        requestedSegmentIndices.insert(index)
        let eventsPerSegment = Int(
            DanmakuScheduler.segmentDurationSeconds * Double(rate)
        )
        let firstGlobalIndex = (index - 1) * eventsPerSegment
        let segmentStart = Double(index - 1)
            * DanmakuScheduler.segmentDurationSeconds
        let events = (0..<eventsPerSegment).map { offset in
            RendererLoadProbe.event(
                index: firstGlobalIndex + offset,
                timeSeconds: segmentStart
                    + Double(offset + 1) / Double(rate)
            )
        }
        return DanmakuSegment(index: index, events: events)
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
