import Foundation

public struct LabPerformancePendingSample: Sendable, Equatable {
    public let sampleID: UUID
    public let presetIdentity: String
    public let rendererID: LabRendererID
    public let repetition: Int
    public let binarySHA256: String
    public let thresholdSHA256: String
}

public enum LabPerformanceArtifactError: Error, LocalizedError {
    case invalidRoot
    case missingPendingSample
    case invalidPendingSample
    case pendingSampleMismatch
    case writeFailed

    public var errorDescription: String? {
        switch self {
        case .invalidRoot:
            "The performance artifact root is invalid."
        case .missingPendingSample:
            "Start record-performance-trace.sh before running the repetition."
        case .invalidPendingSample:
            "The pending performance sample manifest is invalid."
        case .pendingSampleMismatch:
            "The pending sample does not match the selected preset, renderer, or repetition."
        case .writeFailed:
            "The Lab could not persist its performance result."
        }
    }
}

@MainActor
public final class LabPerformanceArtifactStore {
    public static let environmentKey = "DANMAKU_LAB_PERFORMANCE_ROOT"

    public let root: URL?

    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        root = Self.validatedRoot(environment[Self.environmentKey])
    }

    public var isEnabled: Bool { root != nil }

    public func claimPendingSample(
        presetIdentity: String,
        rendererID: LabRendererID,
        repetition: Int
    ) throws -> LabPerformancePendingSample? {
        guard let root else { return nil }
        let pendingURL = root.appendingPathComponent("pending-sample.txt")
        guard let content = try? String(contentsOf: pendingURL, encoding: .utf8) else {
            throw LabPerformanceArtifactError.missingPendingSample
        }
        let values = Self.values(in: content)
        guard values["protocol-version"] == "3",
            let sampleIDValue = values["sample-id"],
            let sampleID = UUID(uuidString: sampleIDValue),
            let pendingPreset = values["preset"],
            let pendingRenderer = values["renderer"],
            let repetitionValue = values["repetition"],
            let pendingRepetition = Int(repetitionValue),
            let binarySHA256 = values["binary-sha256"],
            let thresholdSHA256 = values["threshold-sha256"]
        else {
            throw LabPerformanceArtifactError.invalidPendingSample
        }
        guard pendingPreset == presetIdentity,
            pendingRenderer == rendererID.rawValue,
            pendingRepetition == repetition
        else {
            throw LabPerformanceArtifactError.pendingSampleMismatch
        }
        let claimedDirectory = root.appendingPathComponent(
            "claimed-samples",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: claimedDirectory,
            withIntermediateDirectories: true
        )
        let claimedURL = claimedDirectory.appendingPathComponent(
            "\(sampleID.uuidString.lowercased()).txt"
        )
        do {
            try FileManager.default.moveItem(at: pendingURL, to: claimedURL)
        } catch {
            throw LabPerformanceArtifactError.writeFailed
        }
        return LabPerformancePendingSample(
            sampleID: sampleID,
            presetIdentity: pendingPreset,
            rendererID: LabRendererID(rawValue: pendingRenderer),
            repetition: pendingRepetition,
            binarySHA256: binarySHA256,
            thresholdSHA256: thresholdSHA256
        )
    }

    public func writeResult(
        pending: LabPerformancePendingSample,
        assessment: LabPerformanceSampleAssessment,
        evidence: LabPerformanceRunEvidence?,
        statistics: LabStatistics,
        processTelemetry: LabProcessTelemetrySnapshot
    ) throws {
        guard let root else { return }
        let resultDirectory = root.appendingPathComponent(
            "lab-results",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: resultDirectory,
            withIntermediateDirectories: true
        )
        let resultURL = resultDirectory.appendingPathComponent(
            "\(pending.sampleID.uuidString.lowercased()).txt"
        )
        let dropped = statistics.droppedNoLane.addingReportingOverflow(
            statistics.droppedCapacity
        )
        let values: [(String, String)] = [
            ("protocol-version", "3"),
            ("sample-id", pending.sampleID.uuidString.lowercased()),
            ("preset", pending.presetIdentity),
            ("renderer", pending.rendererID.rawValue),
            ("repetition", "\(pending.repetition)"),
            ("binary-sha256", pending.binarySHA256),
            ("threshold-sha256", pending.thresholdSHA256),
            ("attempt-id", evidence?.attemptID.uuidString.lowercased() ?? "none"),
            ("disposition", assessment.disposition.artifactValue),
            ("logical-ticks-actual", "\(evidence?.logicalTicksProcessed ?? 0)"),
            ("logical-ticks-expected", "\(evidence?.expectedLogicalTicks ?? 0)"),
            ("generated-events-actual", "\(evidence?.generatedEvents ?? 0)"),
            ("generated-events-expected", "\(evidence?.expectedGeneratedEvents ?? 0)"),
            ("measurement-duration-seconds", "\(evidence?.measurementDurationSeconds ?? 0)"),
            ("surface-changed", evidence?.surfaceChangedDuringMeasurement == true ? "yes" : "no"),
            ("manifest-matched", evidence?.manifestMatchesPreset == true ? "yes" : "no"),
            ("admitted-events", "\(statistics.admitted)"),
            ("dropped-events", dropped.overflow ? "\(Int.max)" : "\(dropped.partialValue)"),
            ("peak-active", "\(statistics.peakActive)"),
            ("rss-peak-bytes", "\(processTelemetry.peakResidentBytes)"),
            ("physical-footprint-peak-bytes", "\(processTelemetry.peakPhysicalFootprintBytes)"),
            ("process-cpu-percent", "\(processTelemetry.cpuPercentage)"),
        ]
        let content = values.map { "\($0.0)=\($0.1)" }.joined(separator: "\n") + "\n"
        do {
            try content.write(to: resultURL, atomically: true, encoding: .utf8)
        } catch {
            throw LabPerformanceArtifactError.writeFailed
        }
    }

    private static func validatedRoot(_ value: String?) -> URL? {
        guard let value, value.hasPrefix("/private/tmp/") else { return nil }
        let suffix = value.dropFirst("/private/tmp/".count)
        guard !suffix.isEmpty, !suffix.contains("/"), suffix != ".", suffix != ".." else {
            return nil
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: value, isDirectory: &isDirectory),
            isDirectory.boolValue
        else {
            return nil
        }
        return URL(fileURLWithPath: value, isDirectory: true).standardizedFileURL
    }

    private static func values(in content: String) -> [String: String] {
        content.split(separator: "\n").reduce(into: [:]) { result, line in
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2, !parts[0].isEmpty else { return }
            result[parts[0]] = parts[1]
        }
    }
}

extension LabPerformanceSampleDisposition {
    fileprivate var artifactValue: String {
        switch self {
        case .polluted: "polluted"
        case .revise: "revise"
        case .eligibleForTraceReview: "eligible"
        }
    }
}
