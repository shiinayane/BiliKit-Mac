import BiliModels
import Foundation

public struct DanmakuTextMetrics: Sendable, Equatable {
    public let width: Double
    public let height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }
}

public struct DanmakuRendererDurations: Sendable, Equatable {
    public let scrollingSeconds: Double
    public let fixedSeconds: Double

    public init(
        scrollingSeconds: Double = 8,
        fixedSeconds: Double = 4
    ) {
        self.scrollingSeconds = scrollingSeconds
        self.fixedSeconds = fixedSeconds
    }

    func duration(for mode: DanmakuPresentationMode) -> Double {
        switch mode {
        case .scrolling: scrollingSeconds
        case .top, .bottom: fixedSeconds
        }
    }
}

@MainActor
public protocol DanmakuRenderingBackendDelegate: AnyObject {
    func rendererDidFinish(eventID: String)
}

@MainActor
public protocol DanmakuRenderingBackend: AnyObject {
    var delegate: (any DanmakuRenderingBackendDelegate)? { get set }

    func measure(_ event: DanmakuEvent) -> DanmakuTextMetrics
    func render(_ placement: DanmakuLanePlacement)
    func remove(eventID: String)
    func clearAll()
    func setPlaybackRate(_ rate: Double)
    func updateSurfaceSize(width: Double, height: Double)
    func stop()
}
