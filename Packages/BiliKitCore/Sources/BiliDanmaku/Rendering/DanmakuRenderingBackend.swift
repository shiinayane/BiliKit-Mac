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
/// Renderer 的最小平台 port。
///
/// `clearAll` 只移除活动对象；`stop` 还把播放速率归零。尺寸变化允许实现清空无法安全
/// 迁移的对象，因此 controller 必须同步重置 lane allocator。
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
