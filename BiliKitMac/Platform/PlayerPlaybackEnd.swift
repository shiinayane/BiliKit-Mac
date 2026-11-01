import BiliApplication
import BiliModels
import BiliVideoDetailFeature
import Foundation

/// 「播放结束后」偏好（`PlaybackEndBehavior`）的 `UserDefaults` 存取；持久化范围见 SECURITY-MODEL §6。
///
/// 设备级、所有窗口共用：读取时取此刻的值，不缓存，一个窗口改了，其他窗口下一次播完就按新值处理。只接受已知的原始值，
/// 缺失或损坏时回退默认（不循环）。只在主线程使用。
struct PlaybackEndBehaviorStore {
    private static let key = "player.endBehavior"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var behavior: PlaybackEndBehavior {
        get {
            defaults.string(forKey: Self.key).flatMap(PlaybackEndBehavior.init(rawValue:))
                ?? .defaultValue
        }
        nonmutating set {
            defaults.set(newValue.rawValue, forKey: Self.key)
        }
    }
}

/// 播完时的处理：订阅播放时间线，交给视频模型按偏好处理，执行它要求的跳转，给出要在播放器上显示的提示。
///
/// 由 `WindowAdapters` 的播放器内容用播放引擎、视频模型与窗口导航构造（`make`），交给 `PlayerPlaybackEndObserver`。
/// 下一个分 P 与下一集都走窗口导航（与详情区选分 P、选集同一意图，保留右栏上下文层），下一集的分 P 未知时先经视频模型
/// 解析；解析完才跳转或提示时，先核对视频模型仍在呈现播完的那一项，期间用户换了分 P 或视频就作废。不持有状态。
struct PlayerPlaybackEndActions {
    typealias Observer = @MainActor (PlaybackTimelineSnapshot) -> Void
    typealias Observing = @MainActor (@escaping Observer) -> @MainActor @Sendable () -> Void

    /// 订阅时间线，返回取消订阅的函数。
    ///
    /// 订阅当下先收到一次当前快照（`PlaybackTimeline.observe`）。
    let observeTimeline: Observing
    /// 处理刚进入 `ended` 的快照，返回处理当下的提示；没有动作时为 nil。
    ///
    /// 之后才知道的结果（下一集的分 P 解析失败）经第二个参数提示。
    let handleEnded:
        @MainActor (
            PlaybackTimelineSnapshot, @escaping @MainActor (PlayerActionFeedback) -> Void
        ) async -> PlayerActionFeedback?

    /// 重播失败时，只有播放器仍停在这一项的结尾才提示：期间用户另有操作或换了项，失败是预期内的，不打扰。
    @MainActor
    static func make(
        videoModel: VideoViewModel,
        observeTimeline: @escaping Observing,
        currentTimeline: @escaping @MainActor () -> PlaybackTimelineSnapshot,
        store: PlaybackEndBehaviorStore,
        continuePlayback: @escaping @MainActor (_ bvid: String, _ preferredCID: Int64?) -> Void
    ) -> Self {
        Self(
            observeTimeline: observeTimeline,
            handleEnded: { snapshot, presentLater in
                let behavior = store.behavior
                switch await videoModel.handlePlaybackEnded(snapshot, behavior: behavior) {
                case .none:
                    return nil
                case .replayed:
                    return .endBehavior(behavior)
                case .replayFailed:
                    let current = currentTimeline()
                    return current.state == .ended && current.loadIntent == snapshot.loadIntent
                        ? .replayFailed : nil
                case .advance(let advance):
                    return advanceAfterEnd(
                        advance,
                        endedAt: snapshot,
                        videoModel: videoModel,
                        continuePlayback: continuePlayback,
                        presentLater: presentLater
                    )
                case .nextUnavailable:
                    return .nextUnavailable
                }
            }
        )
    }
}

/// 执行连播的下一项，返回当下的提示。
///
/// 下一集的分 P 可能当场就解析失败（已知分 P 为空、默认 CID 不在分 P 里）：那时 `onFailed` 在
/// `selectCollectionEpisode` 返回前就被调用，这里改为返回“下一集无法播放”，不再随后用“下一集：标题”盖掉它。
@MainActor
private func advanceAfterEnd(
    _ advance: PlaybackEndAdvance,
    endedAt snapshot: PlaybackTimelineSnapshot,
    videoModel: VideoViewModel,
    continuePlayback: @escaping @MainActor (_ bvid: String, _ preferredCID: Int64?) -> Void,
    presentLater: @escaping @MainActor (PlayerActionFeedback) -> Void
) -> PlayerActionFeedback {
    switch advance {
    case .page(let bvid, let page):
        continuePlayback(bvid, page.cid)
    case .episode(let episode):
        var isSelecting = true
        var failedWhileSelecting = false
        videoModel.selectCollectionEpisode(
            episode,
            onResolved: { bvid, preferredCID in
                guard videoModel.isPresenting(snapshot) else { return }
                continuePlayback(bvid, preferredCID)
            },
            onFailed: {
                if isSelecting {
                    failedWhileSelecting = true
                } else if videoModel.isPresenting(snapshot) {
                    presentLater(.nextUnavailable)
                }
            }
        )
        isSelecting = false
        if failedWhileSelecting { return .nextUnavailable }
    }
    return .advancing(title: advance.title)
}

/// 在时间线刚进入 `ended` 的那一刻按偏好处理一次。
///
/// 只认边沿：同一个 item（按 load intent 区分）从别的状态变成 `ended` 才触发，订阅当下补发的当前快照只作起点。
/// 所以用户在已播完时才改偏好、宿主重建、或时间线重复发布 `ended` 都不会触发；不能用只保留最新值、订阅时补发的
/// `timelineUpdates()`，那样会把已经结束的快照当成新的结束。是否真的动作、作用于哪一项由 `VideoViewModel` 再核对。
///
/// 由 `NativePlayerHostView` 持有：宿主创建时 `start`，拆除时 `stop`（先取消订阅，再取消在途的处理）。订阅期间时间线
/// 经回调强持有视频模型，而视频模型持有引擎，宿主拆除时必须 `stop` 才断开这个环。处理用一个 Task，新的结束到来时
/// 取消旧的；Task 只弱引用本类型，在主线程运行。取消只拦住提示，拦不住已经发出的动作：重播由引擎按 item、意图与
/// 用户操作作废，连播的迟到跳转由视频模型的 `isPresenting` 作废；停止后迟到的提示也不再显示。
@MainActor
final class PlayerPlaybackEndObserver {
    private var cancelObservation: (@MainActor @Sendable () -> Void)?
    private var handling: Task<Void, Never>?
    /// 上一个快照的 item 与状态，用来认出“刚进入 ended”。
    private var lastIntent: PlaybackLoadIntent?
    private var lastState: PlaybackTimelineState?
    private var isBaselineSet = false

    /// 开始订阅，`present` 显示处理后的提示。
    ///
    /// 已在订阅时什么都不做。
    func start(
        _ actions: PlayerPlaybackEndActions,
        present: @escaping @MainActor (PlayerActionFeedback) -> Void
    ) {
        guard cancelObservation == nil else { return }
        isBaselineSet = false
        // 迟到的提示（下一集解析失败）只在仍在观察时显示：宿主拆除后不再往浮层上写。
        let presentWhileObserving: @MainActor (PlayerActionFeedback) -> Void = {
            [weak self] feedback in
            guard self?.cancelObservation != nil else { return }
            present(feedback)
        }
        cancelObservation = actions.observeTimeline { [weak self] snapshot in
            guard let self, self.entersEnded(snapshot) else { return }
            self.handling?.cancel()
            self.handling = Task { [weak self] in
                guard let feedback = await actions.handleEnded(snapshot, presentWhileObserving),
                    self != nil, !Task.isCancelled
                else { return }
                present(feedback)
            }
        }
    }

    func stop() {
        cancelObservation?()
        cancelObservation = nil
        handling?.cancel()
        handling = nil
    }

    private func entersEnded(_ snapshot: PlaybackTimelineSnapshot) -> Bool {
        defer {
            lastIntent = snapshot.loadIntent
            lastState = snapshot.state
            isBaselineSet = true
        }
        guard isBaselineSet, snapshot.state == .ended else { return false }
        return lastIntent != snapshot.loadIntent || lastState != .ended
    }
}
