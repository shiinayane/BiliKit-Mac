import BiliApplication
import BiliModels
import Foundation
import Testing

@testable import BiliDanmaku

/// 呈现测试的车道配置：默认 800 × 360pt（10 条车道）、12pt 间距、全屏显示区域、不叠放。
func configuration(
    planningWidth: Double = 800,
    planningHeight: Double = 360
) -> DanmakuLaneConfiguration {
    DanmakuLaneConfiguration(
        planningWidth: planningWidth,
        planningHeight: planningHeight,
        minimumHorizontalGap: 12,
        displayAreaFraction: 1
    )
}

/// 显示区域为全屏的取景框；默认与 `configuration()` 的规划画布一样大。
func viewport(width: Double = 800, height: Double = 360) -> DanmakuViewport {
    DanmakuViewport(width: width, height: height, displayAreaFraction: 1)
}

/// 用测试测量把分段排成布局表；设置取 `configuration()` 与默认速度。
func layoutTable(
    _ segments: [Int: [DanmakuEvent]],
    planningWidth: Double = 800,
    planningHeight: Double = 360
) -> [Int: DanmakuSegmentLayout] {
    let lanes = configuration(planningWidth: planningWidth, planningHeight: planningHeight)
    return DanmakuLayoutPlanner.layouts(
        for: segments,
        reusing: [:],
        parameters: DanmakuLayoutParameters(
            configuration: lanes,
            speedLevel: .default,
            backingScale: 2,
            filter: DanmakuFilter()
        ),
        measure: fixtureMetrics
    ) ?? [:]
}

/// 呈现测试唯一的渲染后端替身，不创建任何 layer。
///
/// 记录在屏弹幕的 placement 与纹理 scale、清屏与画面尺寸，可延迟纹理准备由测试逐个完成；在屏集合变化或
/// 收到延迟的准备请求时检查等待条件。与 renderer 一样：backing scale 变化时静默取消在途准备，交还的准备不再
/// 回调；纹理已在缓存里的弹幕即使延迟准备也在请求内同步就绪；在当前 scale 下生成不了纹理的弹幕在请求内同步
/// 拒绝；挂上时被纹理字节上限拒绝的弹幕保留原有的纹理与 placement；已就绪的准备要么被挂上、要么被交还，
/// 否则一直占着名额。
@MainActor
final class RecordingRenderingBackend: DanmakuRenderingBackend {
    /// 此刻在屏的弹幕与它们的 placement。
    private(set) var installed: [String: DanmakuLanePlacement] = [:]
    /// 此刻在屏的弹幕的纹理按哪个 backing scale 准备。
    private(set) var textureScales: [String: Double] = [:]
    /// 每次移除的事件 ID，按顺序。
    private(set) var removedHistory: [String] = []
    /// 每次收到准备请求的事件 ID，按顺序；含被拒绝的。
    private(set) var preparationHistory: [String] = []
    private(set) var clearCount = 0
    private(set) var stopCount = 0
    /// 每次 `updateSurfaceSize` 收到的宽高，按顺序。
    private(set) var surfaceSizes: [(width: Double, height: Double)] = []
    private var backingScale = DanmakuTextureRasterizer.defaultBackingScale
    /// 为 true 时准备不立即完成，等测试调用 `completePreparations`。
    var delaysPreparation = false
    /// 纹理已在缓存里的弹幕：即使 `delaysPreparation` 也在 `prepare` 内同步就绪。
    var cachedEventIDs: Set<String> = []
    /// 挂上时像纹理字节超出上限那样被拒绝的弹幕：已在屏的保留原有的纹理与 placement。
    var rejectedEventIDs: Set<String> = []
    private typealias DelayedCompletion = (
        eventID: String,
        preparationID: UInt64,
        completion: @MainActor @Sendable (DanmakuPreparationResult) -> Void
    )
    private var delayedCompletions: [DelayedCompletion] = []
    /// 已就绪、既没挂上也没交还的准备。
    private var heldPreparationIDs: Set<UInt64> = []
    private var waiters:
        [UUID: (isSatisfied: @MainActor () -> Bool, continuation: CheckedContinuation<Void, Never>)] =
            [:]

    var installedEventIDs: Set<String> { Set(installed.keys) }
    var pendingPreparationCount: Int { delayedCompletions.count }
    /// 纹理还在准备中的弹幕。
    var pendingEventIDs: Set<String> { Set(delayedCompletions.map(\.eventID)) }
    /// 已就绪、既没挂上也没交还的准备数；renderer 里它们一直计入未完成请求的上限。
    var heldPreparationCount: Int { heldPreparationIDs.count }

    func prepare(
        _ event: DanmakuEvent,
        preparationID: UInt64,
        completion:
            @escaping @MainActor @Sendable (
                DanmakuPreparationResult
            ) -> Void
    ) {
        preparationHistory.append(event.id)
        // materializer 对文本无效与超限一视同仁，这里都按超限拒绝。
        guard fitsTexture(event, backingScale: backingScale) else {
            completion(.rejected(.oversized))
            return
        }
        if delaysPreparation, !cachedEventIDs.contains(event.id) {
            delayedCompletions.append((event.id, preparationID, completion))
            notifyWaiters()
        } else {
            complete(preparationID, completion)
        }
    }

    /// 按发起顺序完成最早的 `count` 个延迟的准备（默认全部），返回按完成顺序排列的事件 ID。
    ///
    /// `reversed` 时从最晚发起的开始倒序完成 `count` 个。
    @discardableResult
    func completePreparations(_ count: Int? = nil, reversed: Bool = false) -> [String] {
        let count = min(count ?? delayedCompletions.count, delayedCompletions.count)
        let completing: [DelayedCompletion]
        if reversed {
            completing = delayedCompletions.suffix(count).reversed()
            delayedCompletions.removeLast(count)
        } else {
            completing = Array(delayedCompletions.prefix(count))
            delayedCompletions.removeFirst(count)
        }
        for item in completing {
            complete(item.preparationID, item.completion)
        }
        return completing.map(\.eventID)
    }

    private func complete(
        _ preparationID: UInt64,
        _ completion: @MainActor @Sendable (DanmakuPreparationResult) -> Void
    ) {
        heldPreparationIDs.insert(preparationID)
        completion(.ready(DanmakuTextMetrics(width: 120, height: 24)))
    }

    /// 不计纹理字节，只拒绝 `rejectedEventIDs` 里的；已在屏的同一 ID 视为原位换纹理。
    @discardableResult
    func install(
        _ placement: DanmakuLanePlacement,
        preparationID: UInt64,
        at position: Double
    ) -> DanmakuInstallResult {
        heldPreparationIDs.remove(preparationID)
        let eventID = placement.request.event.id
        guard !rejectedEventIDs.contains(eventID) else {
            return DanmakuInstallResult(isInstalled: false, evictedEventIDs: [])
        }
        installed[eventID] = placement
        textureScales[eventID] = backingScale
        notifyWaiters()
        return DanmakuInstallResult(isInstalled: true, evictedEventIDs: [])
    }

    @discardableResult
    func update(_ placement: DanmakuLanePlacement) -> Bool {
        let eventID = placement.request.event.id
        guard installed[eventID] != nil else { return false }
        installed[eventID] = placement
        notifyWaiters()
        return true
    }

    /// 与 renderer 一样：交还的准备若还在途就不再回调。
    func discardPreparation(preparationID: UInt64) {
        heldPreparationIDs.remove(preparationID)
        delayedCompletions.removeAll { $0.preparationID == preparationID }
    }

    /// 与 renderer 一样：取消的准备不再回调，已就绪未取走的记录一并丢弃。
    func cancelAllPreparations() {
        delayedCompletions.removeAll()
        heldPreparationIDs.removeAll()
    }

    func remove(eventID: String) {
        removedHistory.append(eventID)
        installed[eventID] = nil
        textureScales[eventID] = nil
        notifyWaiters()
    }

    func clearAll() {
        clearCount += 1
        cancelAllPreparations()
        installed.removeAll()
        textureScales.removeAll()
        notifyWaiters()
    }

    func setOpacity(_ opacity: DanmakuOpacity) {}

    /// 每次交来的整组互动弹幕卡片，按到达顺序。
    private(set) var commandCardChanges: [[DanmakuCommandCard]] = []

    func setCommandCards(_ cards: [DanmakuCommandCard]) {
        commandCardChanges.append(cards)
    }

    /// 与 renderer 一样：backing scale 变化时静默取消在途准备，不回调。
    func updateSurfaceSize(
        width: Double,
        height: Double,
        backingScale: Double
    ) {
        surfaceSizes.append((width, height))
        if backingScale != self.backingScale {
            self.backingScale = backingScale
            cancelAllPreparations()
        }
    }

    func stop() {
        stopCount += 1
        cancelAllPreparations()
        installed.removeAll()
        textureScales.removeAll()
        notifyWaiters()
    }

    /// 等到状态满足 `isSatisfied`；每次在屏集合变化或收到延迟的准备请求时检查。
    func waitUntil(_ isSatisfied: @escaping @MainActor () -> Bool) async {
        guard !isSatisfied() else { return }
        await withCheckedContinuation { continuation in
            waiters[UUID()] = (isSatisfied, continuation)
        }
    }

    private func notifyWaiters() {
        let ready = waiters.filter { $0.value.isSatisfied() }
        for (id, waiter) in ready where waiters.removeValue(forKey: id) != nil {
            waiter.continuation.resume()
        }
    }
}

/// 呈现测试唯一的显示时间替身：测试直接设定时钟层发布的 D；`time` 为 nil 表示读不到（从未绑定、换绑后
/// 新纪元还没写入）。
final class ManualDisplayClock: DanmakuDisplayClock, @unchecked Sendable {
    // 只在 MainActor 上的测试里读写，不跨线程；`@unchecked` 只为满足 port 的 Sendable 要求。
    var time: Double?

    init(time: Double? = nil) {
        self.time = time
    }

    func displayTime() -> Double? {
        time
    }
}

/// 在 1x 下纹理放得下、在 2x 下超出像素宽度上限的滚动弹幕：250 个汉字约 6000pt 宽。
func longTextEvent(id: String, time: Double) -> DanmakuEvent {
    danmakuEvent(id: id, time: time, text: String(repeating: "弹", count: 250))
}

/// `event` 在 `backingScale` 下能否生成纹理：测量与栅格化共用同一份像素上限。
func fitsTexture(_ event: DanmakuEvent, backingScale: Double) -> Bool {
    DanmakuTextureRasterizer.measureKey(event: event, backingScale: backingScale)
        .flatMap(DanmakuTextureRasterizer.measure) != nil
}

/// 布局表里每条弹幕的 placement，按事件 ID 索引；ID 重复时取先出现的一条。
func placementsByEventID(
    _ table: [Int: DanmakuSegmentLayout]
) -> [String: DanmakuLanePlacement] {
    Dictionary(table.values.flatMap(\.placements).map { ($0.request.event.id, $0) }) { first, _ in
        first
    }
}

/// t 时刻屏上真正看得见的弹幕：在屏、已进场，且按自己的 placement 在取景框里还没走完。
///
/// 只看 backend 记录的 placement 与时刻，不看 materializer 的内部记录；前瞻挂上、还没进场的不算。
@MainActor
func visibleEventIDs(
    on backend: RecordingRenderingBackend,
    at time: Double,
    viewport: DanmakuViewport
) -> Set<String> {
    Set(
        backend.installed.values
            .filter { $0.admittedAtSeconds <= time && viewport.shows($0, at: time) }
            .map(\.request.event.id)
    )
}

/// 布局表在 t 时刻应该看得见的弹幕：直接由布局表与取景框求，不经过 materializer，不含前瞻。
func expectedVisibleEventIDs(
    in table: [Int: DanmakuSegmentLayout],
    at time: Double,
    viewport: DanmakuViewport
) -> Set<String> {
    Set(
        table.values.flatMap { layout in
            layout.placements(at: time, lookahead: 0)
                .filter { $0.admittedAtSeconds <= time && viewport.shows($0, at: time) }
                .map(\.request.event.id)
        }
    )
}

/// 可见性采样相对 D 的偏移（媒体秒）：此刻，以及前瞻（2 秒）里挂上的弹幕陆续进场的两个时刻。
private let visibilitySampleOffsets = [0, 0.5, 1.4]

/// 显示时间停在 `displayTime` 时，此刻与之后 1.4 媒体秒内看得见的都与布局表一致。
@MainActor
func expectVisibilityMatchesTheTable(
    on backend: RecordingRenderingBackend,
    table: [Int: DanmakuSegmentLayout],
    viewport: DanmakuViewport,
    at displayTime: Double,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    for offset in visibilitySampleOffsets {
        let time = displayTime + offset
        #expect(
            visibleEventIDs(on: backend, at: time, viewport: viewport)
                == expectedVisibleEventIDs(in: table, at: time, viewport: viewport),
            "D + \(offset) 秒时看得见的集合与布局表不一致",
            sourceLocation: sourceLocation
        )
    }
}

/// 显示时间为 `displayTime` 时不扣留：布局表此刻应看得见的，要么看得见，要么纹理还在准备；看得见的也不超出
/// 布局表此刻应有的。
@MainActor
func expectNothingWithheld(
    on backend: RecordingRenderingBackend,
    table: [Int: DanmakuSegmentLayout],
    viewport: DanmakuViewport,
    at displayTime: Double,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    let visible = visibleEventIDs(on: backend, at: displayTime, viewport: viewport)
    let expected = expectedVisibleEventIDs(in: table, at: displayTime, viewport: viewport)
    #expect(visible.isSubset(of: expected), "看得见的超出布局表", sourceLocation: sourceLocation)
    let withheld = expected.subtracting(visible).subtracting(backend.pendingEventIDs)
    #expect(withheld.isEmpty, "纹理已就绪却看不见：\(withheld.sorted())", sourceLocation: sourceLocation)
}
