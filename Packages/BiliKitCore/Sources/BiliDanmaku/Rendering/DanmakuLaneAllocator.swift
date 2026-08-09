import BiliModels
import Foundation

/// 在固定 surface 与活动数量上限内分配弹幕轨道，并阻止滚动弹幕追尾。
///
/// allocator 只使用媒体时间计算占用/过期；renderer completion 通过 `remove` 回收相同事件。
public struct DanmakuLaneAllocator: Sendable {
    private struct ActivePlacement: Sendable {
        let placement: DanmakuLanePlacement
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
    private var active: [String: ActivePlacement] = [:]
    private var fixedLaneOccupants: [LaneSlotKey: ActivePlacement] = [:]
    private var scrollingLaneTails: [LaneSlotKey: ActivePlacement] = [:]
    private var activeLaneCounts: [LaneKey: Int] = [:]
    public private(set) var peakActiveCount = 0

    public init(configuration: DanmakuLaneConfiguration) {
        self.configuration = configuration
    }

    public var activeCount: Int { active.count }

    /// 更新后续准入使用的 surface；已活动 placement 保留入场时的 geometry 与过期时间。
    public mutating func updateConfiguration(
        _ configuration: DanmakuLaneConfiguration
    ) {
        self.configuration = configuration
    }

    public mutating func clear() -> [DanmakuLanePlacement] {
        let drained = orderedPlacements(active.values.map(\.placement))
        active.removeAll(keepingCapacity: false)
        fixedLaneOccupants.removeAll(keepingCapacity: false)
        scrollingLaneTails.removeAll(keepingCapacity: false)
        activeLaneCounts.removeAll(keepingCapacity: false)
        return drained
    }

    @discardableResult
    public mutating func remove(
        eventID: String
    ) -> DanmakuLanePlacement? {
        guard let removed = active.removeValue(forKey: eventID) else {
            return nil
        }
        let placement = removed.placement
        let laneKey = LaneKey(
            mode: placement.request.event.mode,
            index: placement.laneIndex
        )
        let slotKey = LaneSlotKey(
            lane: laneKey,
            overlapDepth: placement.overlapDepth
        )
        switch placement.request.event.mode {
        case .scrolling:
            if scrollingLaneTails[slotKey]?
                .placement.request.event.id == eventID
            {
                scrollingLaneTails[slotKey] = nil
            }
        case .top, .bottom:
            if fixedLaneOccupants[slotKey]?.placement.request.event.id == eventID {
                fixedLaneOccupants[slotKey] = nil
            }
        }
        let remainingCount = (activeLaneCounts[laneKey] ?? 1) - 1
        if remainingCount > 0 {
            activeLaneCounts[laneKey] = remainingCount
        } else {
            activeLaneCounts[laneKey] = nil
        }
        return placement
    }

    public mutating func admit(
        _ requests: [DanmakuLaneRequest],
        at playbackTime: Double
    ) -> DanmakuLaneAdmission {
        guard playbackTime.isFinite else {
            var dropCounts = DanmakuLaneDropCounts()
            for _ in requests {
                dropCounts.record(.invalidRequest)
            }
            return DanmakuLaneAdmission(
                expired: [],
                admitted: [],
                dropCounts: dropCounts
            )
        }
        let expired = expire(at: playbackTime)
        var admitted: [DanmakuLanePlacement] = []
        var dropCounts = DanmakuLaneDropCounts()
        for request in requests {
            let result = admit(request, at: playbackTime)
            switch result {
            case .success(let placement):
                admitted.append(placement)
            case .failure(let reason):
                dropCounts.record(reason)
            }
        }
        return DanmakuLaneAdmission(
            expired: expired,
            admitted: admitted,
            dropCounts: dropCounts
        )
    }

    private mutating func admit(
        _ request: DanmakuLaneRequest,
        at playbackTime: Double
    ) -> Result<DanmakuLanePlacement, DanmakuLaneDropReason> {
        guard configuration.isValid,
            request.isValid,
            request.height <= configuration.laneHeight,
            active[request.event.id] == nil
        else {
            return .failure(.invalidRequest)
        }
        guard active.count < configuration.maximumActiveCount else {
            return .failure(.capacity)
        }
        let displayHeight =
            configuration.surfaceHeight * configuration.displayAreaFraction
        let uncappedLaneCount = floor(
            displayHeight / configuration.laneHeight
        )
        let laneCount = Int(
            min(
                uncappedLaneCount,
                Double(DanmakuLaneConfiguration.hardMaximumActiveCount)
            )
        )
        guard laneCount > 0 else {
            return .failure(.noLane)
        }
        if let safeLane = (0..<laneCount).first(where: {
            laneIsSafeWithoutOverlap(
                $0,
                for: request,
                at: playbackTime
            )
        }) {
            return .success(
                place(
                    request,
                    laneIndex: safeLane,
                    overlapDepth: 0,
                    at: playbackTime
                )
            )
        }
        guard configuration.maximumOverlapDepth > 1 else {
            return .failure(.noLane)
        }
        for overlapDepth in 0..<configuration.maximumOverlapDepth {
            if let availableLane = (0..<laneCount).first(where: {
                laneIsAvailable(
                    $0,
                    overlapDepth: overlapDepth,
                    for: request,
                    at: playbackTime
                )
            }) {
                return .success(
                    place(
                        request,
                        laneIndex: availableLane,
                        overlapDepth: overlapDepth,
                        at: playbackTime
                    )
                )
            }
        }
        return .failure(.noLane)
    }

    private mutating func place(
        _ request: DanmakuLaneRequest,
        laneIndex: Int,
        overlapDepth: Int,
        at playbackTime: Double
    ) -> DanmakuLanePlacement {
        let placement = DanmakuLanePlacement(
            request: request,
            laneIndex: laneIndex,
            originY: originY(
                for: request.event.mode,
                laneIndex: laneIndex
            ),
            surfaceWidthAtAdmission: configuration.surfaceWidth,
            admittedAtSeconds: playbackTime,
            expiresAtSeconds: playbackTime + request.durationSeconds,
            overlapDepth: overlapDepth
        )
        let activePlacement = ActivePlacement(placement: placement)
        let laneKey = LaneKey(mode: request.event.mode, index: laneIndex)
        let slotKey = LaneSlotKey(
            lane: laneKey,
            overlapDepth: overlapDepth
        )
        active[request.event.id] = activePlacement
        activeLaneCounts[laneKey, default: 0] += 1
        switch request.event.mode {
        case .scrolling:
            scrollingLaneTails[slotKey] = activePlacement
        case .top, .bottom:
            fixedLaneOccupants[slotKey] = activePlacement
        }
        peakActiveCount = max(peakActiveCount, active.count)
        return placement
    }

    private func originY(
        for mode: DanmakuPresentationMode,
        laneIndex: Int
    ) -> Double {
        switch mode {
        case .scrolling, .top:
            Double(laneIndex) * configuration.laneHeight
        case .bottom:
            configuration.surfaceHeight
                - Double(laneIndex + 1) * configuration.laneHeight
        }
    }

    private func laneIsAvailable(
        _ laneIndex: Int,
        overlapDepth: Int,
        for request: DanmakuLaneRequest,
        at playbackTime: Double
    ) -> Bool {
        let slotKey = LaneSlotKey(
            lane: LaneKey(mode: request.event.mode, index: laneIndex),
            overlapDepth: overlapDepth
        )
        switch request.event.mode {
        case .top, .bottom:
            return fixedLaneOccupants[slotKey] == nil
        case .scrolling:
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

    private func laneIsSafeWithoutOverlap(
        _ laneIndex: Int,
        for request: DanmakuLaneRequest,
        at playbackTime: Double
    ) -> Bool {
        let laneKey = LaneKey(
            mode: request.event.mode,
            index: laneIndex
        )
        switch request.event.mode {
        case .top, .bottom:
            return activeLaneCounts[laneKey] == nil
        case .scrolling:
            return scrollingLaneTails.allSatisfy { slotKey, previous in
                guard slotKey.lane == laneKey else { return true }
                return scrollingRequest(
                    request,
                    canFollow: previous.placement,
                    at: playbackTime
                )
            }
        }
    }

    private func scrollingRequest(
        _ request: DanmakuLaneRequest,
        canFollow previous: DanmakuLanePlacement,
        at playbackTime: Double
    ) -> Bool {
        let previousRequest = previous.request
        let elapsed = playbackTime - previous.admittedAtSeconds
        guard elapsed >= 0 else { return false }
        let surfaceWidth = configuration.surfaceWidth
        let previousSurfaceWidth = previous.surfaceWidthAtAdmission
        guard previousSurfaceWidth.isFinite,
            previousSurfaceWidth > 0
        else {
            return false
        }
        let previousSpeed =
            (previousSurfaceWidth + previousRequest.width)
            / previousRequest.durationSeconds
        let newSpeed =
            (surfaceWidth + request.width)
            / request.durationSeconds
        let previousRightEdge =
            previousSurfaceWidth - previousSpeed * elapsed
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

    private mutating func expire(
        at playbackTime: Double
    ) -> [DanmakuLanePlacement] {
        let expiredIDs = active.compactMap { eventID, activePlacement in
            activePlacement.placement.expiresAtSeconds <= playbackTime
                ? eventID
                : nil
        }
        let expired = expiredIDs.compactMap { eventID in
            remove(eventID: eventID)
        }
        return orderedPlacements(expired)
    }

    private func orderedPlacements(
        _ placements: [DanmakuLanePlacement]
    ) -> [DanmakuLanePlacement] {
        placements.sorted {
            if $0.admittedAtSeconds != $1.admittedAtSeconds {
                return $0.admittedAtSeconds < $1.admittedAtSeconds
            }
            return $0.request.event.id < $1.request.event.id
        }
    }
}
