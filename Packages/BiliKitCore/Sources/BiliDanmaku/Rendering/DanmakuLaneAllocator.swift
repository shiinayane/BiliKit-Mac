import BiliModels
import Foundation

/// 在固定 surface 与活动数量上限内分配弹幕轨道，并阻止滚动弹幕追尾。
///
/// 高于一个 lane 基元的文本会占用连续 lane，避免大字号重叠；小字号仍只占一个基元。
///
/// allocator 只使用媒体时间计算占用与过期，输入顺序与宽高确定时结果就确定；车道布局按弹幕自己的时间点
/// 逐条准入，复制一份就是某一时刻的车道占用。
struct DanmakuLaneAllocator: Sendable {
    private struct ActivePlacement: Sendable {
        let placement: DanmakuLanePlacement
        let laneKeys: [LaneKey]
        let slotKeys: [LaneSlotKey]
    }

    private struct LaneKey: Hashable, Sendable {
        let mode: DanmakuPresentationMode
        let index: Int
    }

    private struct LaneSlotKey: Hashable, Sendable {
        let lane: LaneKey
        let overlapDepth: Int
    }

    private var configuration: DanmakuLaneConfiguration
    /// 按事件 ID 的活动 placement。
    private var active: [String: ActivePlacement] = [:]
    /// 顶部与底部弹幕：每个（车道，层）槽位的占用者，到期或移除前独占该槽位。
    private var fixedLaneOccupants: [LaneSlotKey: ActivePlacement] = [:]
    /// 滚动弹幕：每个槽位最后进入的一条；新弹幕只需与它比较会不会追尾。
    private var scrollingLaneTails: [LaneSlotKey: ActivePlacement] = [:]
    /// 每条车道跨所有层的活动数；顶部与底部弹幕先找计数为 0 的车道。
    private var activeLaneCounts: [LaneKey: Int] = [:]

    init(configuration: DanmakuLaneConfiguration) {
        self.configuration = configuration
    }

    /// 两份占用对之后的准入是否完全等价：活动 placement 相同，且每个滚动槽位最后进入的是同一条。
    ///
    /// 车道布局用它判断上一段重新布局后末尾的占用是否变了：不变时下一段的布局原样有效，变了才需要
    /// 从新的种子重排。顶部／底部槽位与车道计数都由活动 placement 决定，不必另比；滚动槽位的尾巴不行，
    /// 尾巴到期移除后，同槽位更早进入、仍在走的那条不会补回尾巴。
    func hasSameOccupancy(as other: Self) -> Bool {
        guard active.count == other.active.count,
            scrollingLaneTails.count == other.scrollingLaneTails.count
        else {
            return false
        }
        let sameActive = active.allSatisfy { eventID, value in
            other.active[eventID]?.placement == value.placement
        }
        return sameActive
            && scrollingLaneTails.allSatisfy { slotKey, tail in
                other.scrollingLaneTails[slotKey]?.placement.request.event.id
                    == tail.placement.request.event.id
            }
    }

    /// 回收一条到期的 placement 占用的槽位与车道计数。
    private mutating func remove(eventID: String) {
        guard let removed = active.removeValue(forKey: eventID) else {
            return
        }
        let placement = removed.placement
        let laneKeys = removed.laneKeys
        let slotKeys = removed.slotKeys
        switch placement.request.event.mode {
        case .scrolling:
            for slotKey in slotKeys
            where scrollingLaneTails[slotKey]?.placement.request.event.id
                == eventID
            {
                scrollingLaneTails[slotKey] = nil
            }
        case .top, .bottom:
            for slotKey in slotKeys
            where fixedLaneOccupants[slotKey]?.placement.request.event.id
                == eventID
            {
                fixedLaneOccupants[slotKey] = nil
            }
        }
        for laneKey in laneKeys {
            let remainingCount = (activeLaneCounts[laneKey] ?? 1) - 1
            if remainingCount > 0 {
                activeLaneCounts[laneKey] = remainingCount
            } else {
                activeLaneCounts[laneKey] = nil
            }
        }
    }

    /// 在 `playbackTime` 先回收到期的 placement，再准入一条；放不下时返回 nil，不排队。
    ///
    /// 先找完全不叠放也不会追尾的车道；配置允许叠放时，才逐层寻找可用的槽位。放不下的原因：配置或请求
    /// 无效、同一事件 ID 仍在活动中、准入时间不是有限值、活动数已达上限，或没有可用车道（显示区域放不下，
    /// 滚动弹幕在每个可用槽位都会追尾，顶部与底部弹幕的槽位都被占用）。
    mutating func admit(
        _ request: DanmakuLaneRequest,
        at playbackTime: Double
    ) -> DanmakuLanePlacement? {
        guard playbackTime.isFinite else { return nil }
        expire(at: playbackTime)
        guard configuration.isValid,
            request.isValid,
            active[request.event.id] == nil
        else {
            return nil
        }
        guard active.count < DanmakuLaneConfiguration.hardMaximumActiveCount else {
            return nil
        }
        let displayHeight =
            configuration.surfaceHeight * configuration.displayAreaFraction
        let laneCount = DanmakuLaneConfiguration.laneCount(
            surfaceHeight: configuration.surfaceHeight,
            displayAreaFraction: configuration.displayAreaFraction
        )
        guard laneCount > 0,
            request.height <= displayHeight,
            let laneSpan = DanmakuLaneConfiguration.laneSpan(forHeight: request.height),
            laneSpan <= laneCount
        else {
            return nil
        }
        // 第一轮从上往下取第一条安全车道，放不下时不占任何车道；所以前 N 条车道的准入只取决于前 N 条
        // 车道的占用，与总车道数无关（取景框模型依赖这一点，例外见 docs/ARCHITECTURE.md「弹幕」）。
        let candidateLanes = 0...(laneCount - laneSpan)
        if let safeLane = candidateLanes.first(where: {
            laneIsSafeWithoutOverlap(
                $0,
                laneSpan: laneSpan,
                for: request,
                at: playbackTime
            )
        }) {
            return place(
                request,
                laneIndex: safeLane,
                laneSpan: laneSpan,
                overlapDepth: 0,
                at: playbackTime
            )
        }
        guard configuration.maximumOverlapDepth > 1 else {
            return nil
        }
        for overlapDepth in 0..<configuration.maximumOverlapDepth {
            if let availableLane = candidateLanes.first(where: {
                laneIsAvailable(
                    $0,
                    laneSpan: laneSpan,
                    overlapDepth: overlapDepth,
                    for: request,
                    at: playbackTime
                )
            }) {
                return place(
                    request,
                    laneIndex: availableLane,
                    laneSpan: laneSpan,
                    overlapDepth: overlapDepth,
                    at: playbackTime
                )
            }
        }
        return nil
    }

    private mutating func place(
        _ request: DanmakuLaneRequest,
        laneIndex: Int,
        laneSpan: Int,
        overlapDepth: Int,
        at playbackTime: Double
    ) -> DanmakuLanePlacement {
        let placement = DanmakuLanePlacement(
            request: request,
            laneIndex: laneIndex,
            planningWidth: configuration.surfaceWidth,
            admittedAtSeconds: playbackTime,
            expiresAtSeconds: playbackTime + request.durationSeconds,
            overlapDepth: overlapDepth
        )
        let laneKeys = (laneIndex..<(laneIndex + laneSpan)).map {
            LaneKey(mode: request.event.mode, index: $0)
        }
        let slotKeys = laneKeys.map {
            LaneSlotKey(lane: $0, overlapDepth: overlapDepth)
        }
        let activePlacement = ActivePlacement(
            placement: placement,
            laneKeys: laneKeys,
            slotKeys: slotKeys
        )
        active[request.event.id] = activePlacement
        for laneKey in laneKeys {
            activeLaneCounts[laneKey, default: 0] += 1
        }
        switch request.event.mode {
        case .scrolling:
            for slotKey in slotKeys {
                scrollingLaneTails[slotKey] = activePlacement
            }
        case .top, .bottom:
            for slotKey in slotKeys {
                fixedLaneOccupants[slotKey] = activePlacement
            }
        }
        return placement
    }

    private func laneIsAvailable(
        _ laneIndex: Int,
        laneSpan: Int,
        overlapDepth: Int,
        for request: DanmakuLaneRequest,
        at playbackTime: Double
    ) -> Bool {
        let slotKeys = (laneIndex..<(laneIndex + laneSpan)).map {
            LaneSlotKey(
                lane: LaneKey(mode: request.event.mode, index: $0),
                overlapDepth: overlapDepth
            )
        }
        switch request.event.mode {
        case .top, .bottom:
            return slotKeys.allSatisfy { fixedLaneOccupants[$0] == nil }
        case .scrolling:
            return slotKeys.allSatisfy { slotKey in
                guard let previous = scrollingLaneTails[slotKey] else {
                    return true
                }
                return scrollingRequest(
                    request,
                    canFollow: previous.placement,
                    at: playbackTime
                )
            }
        }
    }

    private func laneIsSafeWithoutOverlap(
        _ laneIndex: Int,
        laneSpan: Int,
        for request: DanmakuLaneRequest,
        at playbackTime: Double
    ) -> Bool {
        let laneKeys = Set(
            (laneIndex..<(laneIndex + laneSpan)).map {
                LaneKey(mode: request.event.mode, index: $0)
            }
        )
        switch request.event.mode {
        case .top, .bottom:
            return laneKeys.allSatisfy { activeLaneCounts[$0] == nil }
        case .scrolling:
            return scrollingLaneTails.allSatisfy { slotKey, previous in
                guard laneKeys.contains(slotKey.lane) else { return true }
                return scrollingRequest(
                    request,
                    canFollow: previous.placement,
                    at: playbackTime
                )
            }
        }
    }

    /// 新滚动弹幕能否跟在 `previous` 之后：入场时与前一条右缘的间距不小于最小间距，且新弹幕更快时，
    /// 间距缩小到最小间距之前前一条已经到期。
    ///
    /// 一份占用里的 placement 都按同一个配置排出（种子也来自同一组设置），所以两条都用配置的画布宽度。
    /// 追尾按整张规划画布算，前一条在窗口外的那段也计入，窄窗口里因此偏保守。
    private func scrollingRequest(
        _ request: DanmakuLaneRequest,
        canFollow previous: DanmakuLanePlacement,
        at playbackTime: Double
    ) -> Bool {
        let previousRequest = previous.request
        let elapsed = playbackTime - previous.admittedAtSeconds
        guard elapsed >= 0 else { return false }
        let surfaceWidth = configuration.surfaceWidth
        let previousSpeed = DanmakuMotionPolicy.scrollingSpeed(
            textWidth: previousRequest.width,
            planningWidth: surfaceWidth,
            durationSeconds: previousRequest.durationSeconds
        )
        let newSpeed = DanmakuMotionPolicy.scrollingSpeed(
            textWidth: request.width,
            planningWidth: surfaceWidth,
            durationSeconds: request.durationSeconds
        )
        let previousRightEdge =
            surfaceWidth - previousSpeed * elapsed
            + previousRequest.width
        let availableGap = surfaceWidth - previousRightEdge
        guard availableGap >= configuration.minimumHorizontalGap else {
            return false
        }
        guard newSpeed > previousSpeed else { return true }
        let remainingGap =
            availableGap - configuration.minimumHorizontalGap
        let catchUpTime = remainingGap / (newSpeed - previousSpeed)
        let previousRemainingTime =
            previous.expiresAtSeconds - playbackTime
        return catchUpTime >= previousRemainingTime
    }

    private mutating func expire(at playbackTime: Double) {
        let expiredIDs = active.compactMap { eventID, activePlacement in
            activePlacement.placement.expiresAtSeconds <= playbackTime
                ? eventID
                : nil
        }
        for eventID in expiredIDs {
            remove(eventID: eventID)
        }
    }
}
