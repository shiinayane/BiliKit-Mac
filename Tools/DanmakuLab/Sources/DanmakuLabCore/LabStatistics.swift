import BiliDanmaku

public struct LabRendererSnapshot: Sendable, Equatable {
    public let admitted: Int
    public let droppedNoLane: Int
    public let droppedCapacity: Int
    public let active: Int
    public let peakActive: Int

    public init(
        admitted: Int,
        droppedNoLane: Int,
        droppedCapacity: Int,
        active: Int,
        peakActive: Int
    ) {
        self.admitted = max(admitted, 0)
        self.droppedNoLane = max(droppedNoLane, 0)
        self.droppedCapacity = max(droppedCapacity, 0)
        self.active = max(active, 0)
        self.peakActive = max(peakActive, self.active)
    }

    public init(_ statistics: DanmakuRendererStatistics) {
        self.init(
            admitted: statistics.admitted,
            droppedNoLane: statistics.droppedNoLane,
            droppedCapacity: statistics.droppedCapacity,
            active: statistics.active,
            peakActive: statistics.peakActive
        )
    }
}

public struct LabStatistics: Sendable, Equatable {
    public var generated = 0
    public var attempted = 0
    public var filtered = 0
    public var generatorOverflow = 0
    public var admitted = 0
    public var droppedNoLane = 0
    public var droppedCapacity = 0
    public var active = 0
    public var peakActive = 0
    public var logicalTicksProcessed = 0

    public init() {}

    public mutating func mapRenderer(_ current: LabRendererSnapshot) {
        admitted = max(current.admitted, 0)
        droppedNoLane = max(current.droppedNoLane, 0)
        droppedCapacity = max(current.droppedCapacity, 0)
        active = max(current.active, 0)
        peakActive = max(peakActive, current.peakActive)
    }
}
