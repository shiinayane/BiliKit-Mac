import Darwin
import Foundation

public struct LabProcessTelemetrySample: Sendable, Equatable {
    public var timestamp: Double
    public var residentBytes: UInt64
    public var physicalFootprintBytes: UInt64
    public var cumulativeCPUSeconds: Double

    public init(
        timestamp: Double,
        residentBytes: UInt64,
        physicalFootprintBytes: UInt64,
        cumulativeCPUSeconds: Double
    ) {
        self.timestamp = timestamp
        self.residentBytes = residentBytes
        self.physicalFootprintBytes = physicalFootprintBytes
        self.cumulativeCPUSeconds = cumulativeCPUSeconds
    }
}

public struct LabProcessTelemetrySnapshot: Sendable, Equatable {
    public var residentBytes: UInt64
    public var peakResidentBytes: UInt64
    public var physicalFootprintBytes: UInt64
    public var peakPhysicalFootprintBytes: UInt64
    public var cpuPercentage: Double
    public var hasCPUInterval: Bool

    public init(
        residentBytes: UInt64,
        peakResidentBytes: UInt64,
        physicalFootprintBytes: UInt64,
        peakPhysicalFootprintBytes: UInt64,
        cpuPercentage: Double,
        hasCPUInterval: Bool
    ) {
        self.residentBytes = residentBytes
        self.peakResidentBytes = peakResidentBytes
        self.physicalFootprintBytes = physicalFootprintBytes
        self.peakPhysicalFootprintBytes = peakPhysicalFootprintBytes
        self.cpuPercentage = cpuPercentage
        self.hasCPUInterval = hasCPUInterval
    }

    public static let zero = LabProcessTelemetrySnapshot(
        residentBytes: 0,
        peakResidentBytes: 0,
        physicalFootprintBytes: 0,
        peakPhysicalFootprintBytes: 0,
        cpuPercentage: 0,
        hasCPUInterval: false
    )
}

public struct LabProcessTelemetryAccumulator: Sendable {
    private var previousTimestamp: Double?
    private var previousCPUSeconds: Double?
    private var peakResidentBytes: UInt64 = 0
    private var peakPhysicalFootprintBytes: UInt64 = 0

    public init() {}

    public mutating func record(
        _ sample: LabProcessTelemetrySample
    ) -> LabProcessTelemetrySnapshot? {
        guard sample.timestamp.isFinite,
            sample.cumulativeCPUSeconds.isFinite,
            sample.timestamp >= 0,
            sample.cumulativeCPUSeconds >= 0
        else {
            return nil
        }

        peakResidentBytes = max(peakResidentBytes, sample.residentBytes)
        peakPhysicalFootprintBytes = max(
            peakPhysicalFootprintBytes,
            sample.physicalFootprintBytes
        )

        let cpuPercentage: Double
        let hasCPUInterval: Bool
        if let previousTimestamp,
            let previousCPUSeconds,
            sample.timestamp > previousTimestamp,
            sample.cumulativeCPUSeconds >= previousCPUSeconds
        {
            cpuPercentage =
                (sample.cumulativeCPUSeconds - previousCPUSeconds)
                / (sample.timestamp - previousTimestamp) * 100
            hasCPUInterval = true
        } else {
            cpuPercentage = 0
            hasCPUInterval = false
        }

        previousTimestamp = sample.timestamp
        previousCPUSeconds = sample.cumulativeCPUSeconds
        return LabProcessTelemetrySnapshot(
            residentBytes: sample.residentBytes,
            peakResidentBytes: peakResidentBytes,
            physicalFootprintBytes: sample.physicalFootprintBytes,
            peakPhysicalFootprintBytes: peakPhysicalFootprintBytes,
            cpuPercentage: cpuPercentage,
            hasCPUInterval: hasCPUInterval
        )
    }

    public mutating func reset() {
        previousTimestamp = nil
        previousCPUSeconds = nil
        peakResidentBytes = 0
        peakPhysicalFootprintBytes = 0
    }
}

enum LabProcessMetricsSampler {
    static func sample(timestamp: Double) -> LabProcessTelemetrySample? {
        guard let memory = memorySample(),
            let cumulativeCPUSeconds = cumulativeCPUSeconds()
        else {
            return nil
        }
        return LabProcessTelemetrySample(
            timestamp: timestamp,
            residentBytes: memory.residentBytes,
            physicalFootprintBytes: memory.physicalFootprintBytes,
            cumulativeCPUSeconds: cumulativeCPUSeconds
        )
    }

    private static func memorySample() -> (
        residentBytes: UInt64,
        physicalFootprintBytes: UInt64
    )? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size
                / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(
                to: integer_t.self,
                capacity: Int(count)
            ) { rebound in
                task_info(
                    mach_task_self_,
                    task_flavor_t(TASK_VM_INFO),
                    rebound,
                    &count
                )
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return (
            residentBytes: UInt64(info.resident_size),
            physicalFootprintBytes: UInt64(info.phys_footprint)
        )
    }

    private static func cumulativeCPUSeconds() -> Double? {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return nil }
        return seconds(usage.ru_utime) + seconds(usage.ru_stime)
    }

    private static func seconds(_ value: timeval) -> Double {
        Double(value.tv_sec) + Double(value.tv_usec) / 1_000_000
    }
}
