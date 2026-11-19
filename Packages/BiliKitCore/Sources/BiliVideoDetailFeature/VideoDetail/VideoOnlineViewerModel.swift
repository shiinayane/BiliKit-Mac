import BiliApplication
import BiliModels
import Foundation
import Observation

/// 某个分 P 的「正在看」人数文本，带上所属分 P；呈现方据此丢弃别的分 P 的结果。
public struct VideoOnlineViewers: Sendable, Equatable {
    public let identity: PlaybackItemIdentity
    public let text: String
}

/// 播放页「正在看」人数的唯一 owner：读取正在呈现的分 P 的人数，播放中按固定间隔刷新。
///
/// 工具栏副标题只读这里。拥有轮询 Task（`LatestTask`）；不拥有播放状态，只在刷新时刻读时间线的当前快照判断是否在播。
///
/// 由窗口组装持有，与分段章节模型同一生命周期：播放页在呈现的分 P 变化时 `select`，没有可播放的分 P、停止播放与关窗时
/// `reset`。`select` 新分 P 时先取消旧的轮询并清空人数，再立即读一次，之后每到一个间隔、且时间线正在播放这个分 P 时
/// 再读；暂停、缓冲或播放器上不是这个分 P 时跳过这一次，不发请求。迟到的结果按 `LatestTask` 与所选分 P 一并核对后丢弃。
/// 读取失败保留上一次的人数，等下一个间隔再试；B 站明确不显示（读到 nil）时清空。
@MainActor
@Observable
public final class VideoOnlineViewerModel {
    /// 播放中的刷新间隔。
    ///
    /// 人数是粗粒度的统计（`1000+` 之类），一分钟一刷已足够跟上；调小会按窗口成倍增加对同一公开接口的请求，调大则
    /// 人数变化更滞后。
    static let refreshInterval: Duration = .seconds(60)

    /// 正在呈现的分 P 的人数；还没读到、B 站不显示、或已换分 P 时为 nil。
    public private(set) var viewers: VideoOnlineViewers?

    @ObservationIgnored private let useCase: VideoOnlineViewerUseCase
    @ObservationIgnored private let timeline: any PlaybackTimelineProviding
    @ObservationIgnored private let refreshTicks:
        @MainActor @Sendable (Duration) -> AsyncStream<Void>
    @ObservationIgnored private let pollTask = LatestTask()
    @ObservationIgnored private var selectedIdentity: PlaybackItemIdentity?

    /// `refreshTicks` 按给定间隔产生刷新时刻，是本模型的时钟边界；App 传 `PeriodicTicks.system(every:)`。
    public init(
        useCase: VideoOnlineViewerUseCase,
        timeline: any PlaybackTimelineProviding,
        refreshTicks: @escaping @MainActor @Sendable (Duration) -> AsyncStream<Void>
    ) {
        self.useCase = useCase
        self.timeline = timeline
        self.refreshTicks = refreshTicks
    }

    /// 播放页呈现的分 P 变了时调用；同一分 P 正在轮询时不重新开始。
    public func select(_ identity: PlaybackItemIdentity) {
        if selectedIdentity == identity, pollTask.isRunning { return }
        if selectedIdentity != identity {
            // 旧分 P 的轮询由下面的 `replace` 取消；先清空，迟到的旧结果再按所选分 P 丢弃。
            if viewers != nil { viewers = nil }
            selectedIdentity = identity
        }
        let ticks = refreshTicks(Self.refreshInterval)
        pollTask.replace { [weak self] isCurrent in
            await self?.refresh(identity, isCurrent: isCurrent)
            for await _ in ticks {
                guard let self, isCurrent() else { return }
                guard self.isPlaying(identity) else { continue }
                await self.refresh(identity, isCurrent: isCurrent)
            }
        }
    }

    public func reset() {
        pollTask.cancel()
        selectedIdentity = nil
        if viewers != nil { viewers = nil }
    }

    /// `identity` 正在呈现时它的人数文本；不是这份人数所属的分 P 时为 nil。
    public func text(for identity: PlaybackItemIdentity?) -> String? {
        guard let viewers, viewers.identity == identity else { return nil }
        return viewers.text
    }

    private func isPlaying(_ identity: PlaybackItemIdentity) -> Bool {
        let snapshot = timeline.currentTimelineSnapshot
        return snapshot.identity == identity && snapshot.state == .playing
    }

    private func refresh(
        _ identity: PlaybackItemIdentity,
        isCurrent: LatestTask.IsCurrent
    ) async {
        let text: String?
        do {
            text = try await useCase.onlineViewerText(for: identity)
        } catch {
            return
        }
        guard isCurrent(), selectedIdentity == identity else { return }
        let next = text.map { VideoOnlineViewers(identity: identity, text: $0) }
        if viewers != next { viewers = next }
    }
}
