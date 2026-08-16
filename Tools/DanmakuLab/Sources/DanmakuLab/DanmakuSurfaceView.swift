import AppKit
import DanmakuLabCore
import SwiftUI

struct DanmakuSurfaceView: NSViewRepresentable {
    let runOwner: LabRunOwner
    let telemetryEnabled: Bool

    func makeNSView(context: Context) -> HostView {
        HostView(
            runOwner: runOwner,
            telemetryEnabled: telemetryEnabled
        )
    }

    func updateNSView(_ nsView: HostView, context: Context) {
        nsView.replaceRunOwnerIfNeeded(runOwner)
        nsView.setTelemetryEnabled(telemetryEnabled)
        nsView.updateSurfaceIfNeeded()
    }

    static func dismantleNSView(_ nsView: HostView, coordinator: ()) {
        nsView.detachSurface()
    }
}

@MainActor
final class HostView: NSView {
    private var runOwner: LabRunOwner
    private let ownerID = UUID()
    private var previousSize: CGSize?
    private var isAttached = false
    private var telemetryEnabled: Bool
    private let displayLinkDriver = LabDisplayLinkDriver()

    init(runOwner: LabRunOwner, telemetryEnabled: Bool) {
        self.runOwner = runOwner
        self.telemetryEnabled = telemetryEnabled
        super.init(frame: .zero)
        wantsLayer = true
        layer = CALayer()
        layer?.masksToBounds = true
        setAccessibilityElement(false)
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

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        previousSize = nil
        updateSurfaceIfNeeded()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    func replaceRunOwnerIfNeeded(_ replacement: LabRunOwner) {
        guard runOwner !== replacement else { return }
        detachSurface()
        runOwner = replacement
        attachSurfaceIfNeeded()
    }

    func setTelemetryEnabled(_ enabled: Bool) {
        guard telemetryEnabled != enabled else { return }
        telemetryEnabled = enabled
        if enabled, isAttached {
            displayLinkDriver.start(view: self, runOwner: runOwner)
        } else {
            displayLinkDriver.stop()
            runOwner.resetDisplayTelemetry()
        }
    }

    func updateSurfaceIfNeeded() {
        guard window != nil, bounds.width > 0, bounds.height > 0 else { return }
        if !isAttached {
            attachSurfaceIfNeeded()
            return
        }
        guard previousSize != bounds.size else { return }
        previousSize = bounds.size
        runOwner.updateSurface(
            width: Double(bounds.width),
            height: Double(bounds.height),
            backingScale: Double(window?.backingScaleFactor ?? 0),
            ownerID: ownerID
        )
    }

    func detachSurface() {
        displayLinkDriver.stop()
        runOwner.resetDisplayTelemetry()
        guard isAttached else { return }
        isAttached = false
        previousSize = nil
        if runOwner.detachSurface(ownerID: ownerID) {
            runOwner.renderer.surfaceLayer.removeFromSuperlayer()
        }
    }

    private func attachSurfaceIfNeeded() {
        guard !isAttached,
            window != nil,
            bounds.width > 0,
            bounds.height > 0,
            runOwner.attachSurface(
                width: Double(bounds.width),
                height: Double(bounds.height),
                backingScale: Double(window?.backingScaleFactor ?? 0),
                ownerID: ownerID
            )
        else {
            return
        }
        isAttached = true
        previousSize = bounds.size
        layer?.addSublayer(runOwner.renderer.surfaceLayer)
        if telemetryEnabled {
            displayLinkDriver.start(view: self, runOwner: runOwner)
        }
    }
}

@MainActor
private final class LabDisplayLinkDriver: NSObject {
    private weak var runOwner: LabRunOwner?
    private var displayLink: CADisplayLink?

    func start(view: NSView, runOwner: LabRunOwner) {
        stop()
        self.runOwner = runOwner
        let displayLink = view.displayLink(
            target: self,
            selector: #selector(displayLinkDidFire(_:))
        )
        self.displayLink = displayLink
        displayLink.add(to: .main, forMode: .common)
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
        runOwner = nil
    }

    @objc
    private func displayLinkDidFire(_ displayLink: CADisplayLink) {
        runOwner?.recordDisplayFrame(
            timestamp: displayLink.timestamp,
            targetDuration: displayLink.duration
        )
    }
}
