import BiliModels
import Foundation

public struct DanmakuLaneAllocator: Sendable {
    private struct ActivePlacement: Sendable {
        let placement: DanmakuLanePlacement
    }

    private struct LaneKey: Hashable, Sendable {
        let mode: DanmakuPresentationMode
        let index: Int
    }

    private var configuration: DanmakuLaneConfiguration
    private var active: [String: ActivePlacement] = [:]
    private var fixedLaneOccupants: [LaneKey: ActivePlacement] = [:]
    private var scrollingLaneTails: [Int: ActivePlacement] = [:]
    public private(set) var peakActiveCount = 0

    public init(configuration: DanmakuLaneConfiguration) {
        self.configuration = configuration
    }

    public var activeCount: Int { active.count }

    public mutating func updateConfiguration(
        _ configuration: DanmakuLaneConfiguration
    ) -> [DanmakuLanePlacement] {
        let drained = clear()
        self.configuration = configuration
        return drained
    }

    public mutating func clear() -> [DanmakuLanePlacement] {
        let drained = orderedPlacements(active.values.map(\.placement))
        active.removeAll(keepingCapacity: false)
        fixedLaneOccupants.removeAll(keepingCapacity: false)
        scrollingLaneTails.removeAll(keepingCapacity: false)
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
        switch placement.request.event.mode {
        case .scrolling:
            if scrollingLaneTails[placement.laneIndex]?
                .placement.request.event.id == eventID
            {
                scrollingLaneTails[placement.laneIndex] = nil
            }
        case .top, .bottom:
            let key = LaneKey(
                mode: placement.request.event.mode,
                index: placement.laneIndex
            )
            if fixedLaneOccupants[key]?.placement.request.event.id == eventID {
                fixedLaneOccupants[key] = nil
            }
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
            case let .success(placement):
                admitted.append(placement)
            case let .failure(reason):
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
        let laneCount = Int(
            floor(displayHeight / configuration.laneHeight)
        )
        guard laneCount > 0 else {
            return .failure(.noLane)
        }
        for laneIndex in 0..<laneCount
        where laneIsAvailable(
            laneIndex,
            for: request,
            at: playbackTime
        ) {
            let placement = DanmakuLanePlacement(
                request: request,
                laneIndex: laneIndex,
                originY: originY(
                    for: request.event.mode,
                    laneIndex: laneIndex
                ),
                admittedAtSeconds: playbackTime,
                expiresAtSeconds: playbackTime + request.durationSeconds
            )
            let activePlacement = ActivePlacement(placement: placement)
            active[request.event.id] = activePlacement
            switch request.event.mode {
            case .scrolling:
                scrollingLaneTails[laneIndex] = activePlacement
            case .top, .bottom:
                fixedLaneOccupants[
                    LaneKey(mode: request.event.mode, index: laneIndex)
                ] = activePlacement
            }
            peakActiveCount = max(peakActiveCount, active.count)
            return .success(placement)
        }
        return .failure(.noLane)
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
        for request: DanmakuLaneRequest,
        at playbackTime: Double
    ) -> Bool {
        switch request.event.mode {
        case .top, .bottom:
            return fixedLaneOccupants[
                LaneKey(mode: request.event.mode, index: laneIndex)
            ] == nil
        case .scrolling:
            guard let previous = scrollingLaneTails[laneIndex] else {
                return true
            }
            return scrollingRequest(
                request,
                canFollow: previous.placement,
                at: playbackTime
            )
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
        let previousSpeed =
            (surfaceWidth + previousRequest.width)
            / previousRequest.durationSeconds
        let newSpeed =
            (surfaceWidth + request.width)
            / request.durationSeconds
        let previousRightEdge =
            surfaceWidth - previousSpeed * elapsed + previousRequest.width
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
