import BiliModels
import BiliNetworking
import Foundation

public enum PlaybackRouteTarget: Sendable, Equatable, Hashable, CaseIterable {
    case serverAkamai
    case bilivideo(BilivideoRoute)

    public static var allCases: [PlaybackRouteTarget] {
        [.serverAkamai] + BilivideoRoute.allCases.map(Self.bilivideo)
    }

    public var displayName: String {
        switch self {
        case .serverAkamai: "Akamai（服务端原始）"
        case .bilivideo(let route): route.displayName
        }
    }
}

public struct PlaybackRouteMeasurement: Sendable, Equatable {
    public let target: PlaybackRouteTarget
    /// Harmonic mean of successful per-sample conservative throughputs.
    public let effectiveBitsPerSecond: Double?
    public let minimumBitsPerSecond: Double?
    public let medianBitsPerSecond: Double?
    /// Anonymous per-sample values, sorted from slowest to fastest.
    public let sampleBitsPerSecond: [Double]
    public let successfulRuns: Int
    public let totalRuns: Int

    public init(
        target: PlaybackRouteTarget,
        effectiveBitsPerSecond: Double?,
        minimumBitsPerSecond: Double? = nil,
        medianBitsPerSecond: Double? = nil,
        sampleBitsPerSecond: [Double] = [],
        successfulRuns: Int = 1,
        totalRuns: Int = 1
    ) {
        self.target = target
        self.effectiveBitsPerSecond = effectiveBitsPerSecond
        self.minimumBitsPerSecond = minimumBitsPerSecond ?? effectiveBitsPerSecond
        self.medianBitsPerSecond = medianBitsPerSecond ?? effectiveBitsPerSecond
        self.sampleBitsPerSecond = sampleBitsPerSecond
        self.successfulRuns = effectiveBitsPerSecond == nil ? 0 : successfulRuns
        self.totalRuns = totalRuns
    }

    public var succeeded: Bool { effectiveBitsPerSecond != nil }
}

public struct PlaybackRouteBenchmarkSample: Sendable, Equatable {
    public let template: MediaRepresentation
    public let headers: [String: String]

    public init(template: MediaRepresentation, headers: [String: String]) {
        self.template = template
        self.headers = headers
    }
}

public enum BilivideoRouteBenchmarkError: Error, Sendable, Equatable {
    case incompleteCandidatePool
    case invalidProbeRange
    case invalidRepetitionCount(Int)
}

private struct CanonicalProbe: Sendable {
    let index: SegmentIndex
    let completeLength: Int64
    let probeRanges: [HTTPByteRange]
}

private struct RouteProbeResult<Target: Hashable & Sendable>: Sendable {
    let target: Target
    let effectiveBitsPerSecond: Double?
    let minimumBitsPerSecond: Double?
    let medianBitsPerSecond: Double?
    let sampleBitsPerSecond: [Double]
    let successfulRuns: Int
    let totalRuns: Int
}

public actor BilivideoRouteBenchmark {
    public static let maximumMediaProbeBytes: UInt64 = 10 * 1_024 * 1_024
    public static let maximumIndexBytes: UInt64 = 256 * 1_024
    public static let requestTimeout: TimeInterval = 10
    public static let resourceTimeout: TimeInterval = 30
    public static let supportedRepetitions = 1...3

    private let makeRangeFetcher: @Sendable () -> any HTTPBoundedRangeFetching

    public init() {
        makeRangeFetcher = {
            HTTPBoundedRangeClient(
                requestTimeout: BilivideoRouteBenchmark.requestTimeout,
                resourceTimeout: BilivideoRouteBenchmark.resourceTimeout
            )
        }
    }

    init(rangeFetcher: any HTTPBoundedRangeFetching) {
        makeRangeFetcher = { rangeFetcher }
    }

    /// Measures distinct anonymous samples once each.
    ///
    /// The original bilivideo URL establishes
    /// canonical SIDX truth; the 19 measured targets then share one credential-free session.
    public func benchmarkUnifiedPool(
        samples: [PlaybackRouteBenchmarkSample],
        progress: @escaping @Sendable (Int, Int) async -> Void = { _, _ in }
    ) async throws -> [PlaybackRouteMeasurement] {
        guard Self.supportedRepetitions.contains(samples.count) else {
            throw BilivideoRouteBenchmarkError.invalidRepetitionCount(samples.count)
        }
        let targets = PlaybackRouteTarget.allCases
        var values = Dictionary(uniqueKeysWithValues: targets.map { ($0, [Double]()) })
        let totalAttempts = targets.count * samples.count
        let measurementFetcher = makeRangeFetcher()
        defer { measurementFetcher.invalidate() }
        await progress(0, totalAttempts)

        for (sampleIndex, sample) in samples.enumerated() {
            try Task.checkCancellation()
            let candidates = try unifiedCandidates(for: sample.template)
            let canonical = try await canonicalProbe(
                template: sample.template,
                sourceURL: try serverBilivideoURL(for: sample.template),
                headers: sample.headers
            )
            let offset = sampleIndex * max(1, targets.count / samples.count)
            let result = try await probeSample(
                rotated(candidates, by: offset),
                template: sample.template,
                headers: sample.headers,
                canonical: canonical,
                rangeFetcher: measurementFetcher,
                progressBase: sampleIndex * targets.count,
                totalAttempts: totalAttempts,
                progress: progress
            )
            for (target, value) in result {
                values[target, default: []].append(value)
            }
        }

        return aggregate(values, totalRuns: samples.count, order: targets).map {
            PlaybackRouteMeasurement(
                target: $0.target,
                effectiveBitsPerSecond: $0.effectiveBitsPerSecond,
                minimumBitsPerSecond: $0.minimumBitsPerSecond,
                medianBitsPerSecond: $0.medianBitsPerSecond,
                sampleBitsPerSecond: $0.sampleBitsPerSecond,
                successfulRuns: $0.successfulRuns,
                totalRuns: $0.totalRuns
            )
        }
    }

    public func benchmarkUnifiedPool(
        template: MediaRepresentation,
        headers: [String: String],
        repetitions: Int = 1,
        progress: @escaping @Sendable (Int, Int) async -> Void = { _, _ in }
    ) async throws -> [PlaybackRouteMeasurement] {
        try await benchmarkUnifiedPool(
            samples: Array(
                repeating: PlaybackRouteBenchmarkSample(template: template, headers: headers),
                count: repetitions
            ),
            progress: progress
        )
    }

    private func probeSample<Target: Hashable & Sendable>(
        _ candidates: [(Target, URL)],
        template: MediaRepresentation,
        headers: [String: String],
        canonical: CanonicalProbe,
        rangeFetcher: any HTTPBoundedRangeFetching,
        progressBase: Int,
        totalAttempts: Int,
        progress: @escaping @Sendable (Int, Int) async -> Void
    ) async throws -> [Target: Double] {
        let indexRange = try HTTPByteRange(
            start: template.segmentBase.index.start,
            endInclusive: template.segmentBase.index.endInclusive
        )
        let initializationRange = try HTTPByteRange(
            start: template.segmentBase.initialization.start,
            endInclusive: template.segmentBase.initialization.endInclusive
        )
        guard indexRange.length <= Self.maximumIndexBytes,
            initializationRange.length < Self.maximumMediaProbeBytes
        else { throw BilivideoRouteBenchmarkError.invalidProbeRange }
        let parser = SIDXParser()
        var values: [Target: Double] = [:]

        for (candidateIndex, candidate) in candidates.enumerated() {
            try Task.checkCancellation()
            do {
                let indexResult = try await rangeFetcher.fetch(
                    from: candidate.1,
                    range: indexRange,
                    headers: headers,
                    collectBody: true
                )
                guard let body = indexResult.body,
                    let completeLength = indexResult.contentRange.completeLength,
                    initializationRange.endInclusive < completeLength
                else { throw BilivideoRouteBenchmarkError.invalidProbeRange }
                let index = try parser.parse(body, boxStartOffset: UInt64(indexRange.start))
                guard index == canonical.index,
                    completeLength == canonical.completeLength
                else { throw BilivideoRouteBenchmarkError.invalidProbeRange }

                let initializationResult = try await rangeFetcher.fetch(
                    from: candidate.1,
                    range: initializationRange,
                    headers: headers,
                    collectBody: false
                )
                guard initializationResult.byteCount == initializationRange.length,
                    initializationResult.contentRange.completeLength
                        == canonical.completeLength
                else {
                    throw BilivideoRouteBenchmarkError.invalidProbeRange
                }

                var throughputs: [Double] = []
                for probeRange in canonical.probeRanges {
                    try Task.checkCancellation()
                    let mediaResult = try await rangeFetcher.fetch(
                        from: candidate.1,
                        range: probeRange,
                        headers: headers,
                        collectBody: false
                    )
                    guard mediaResult.byteCount == probeRange.length,
                        mediaResult.contentRange.completeLength
                            == canonical.completeLength,
                        mediaResult.requestDurationSeconds.isFinite,
                        mediaResult.requestDurationSeconds > 0
                    else { throw BilivideoRouteBenchmarkError.invalidProbeRange }
                    throughputs.append(
                        Double(mediaResult.byteCount) * 8
                            / mediaResult.requestDurationSeconds
                    )
                }
                guard let conservative = throughputs.min() else {
                    throw BilivideoRouteBenchmarkError.invalidProbeRange
                }
                values[candidate.0] = conservative
            } catch is CancellationError {
                throw CancellationError()
            } catch {}
            await progress(progressBase + candidateIndex + 1, totalAttempts)
        }
        return values
    }

    private func canonicalProbe(
        template: MediaRepresentation,
        sourceURL: URL,
        headers: [String: String]
    ) async throws -> CanonicalProbe {
        let indexRange = try HTTPByteRange(
            start: template.segmentBase.index.start,
            endInclusive: template.segmentBase.index.endInclusive
        )
        let initializationRange = try HTTPByteRange(
            start: template.segmentBase.initialization.start,
            endInclusive: template.segmentBase.initialization.endInclusive
        )
        guard indexRange.length <= Self.maximumIndexBytes,
            initializationRange.length < Self.maximumMediaProbeBytes
        else { throw BilivideoRouteBenchmarkError.invalidProbeRange }

        let canonicalFetcher = makeRangeFetcher()
        defer { canonicalFetcher.invalidate() }
        let result = try await canonicalFetcher.fetch(
            from: sourceURL,
            range: indexRange,
            headers: headers,
            collectBody: true
        )
        guard let body = result.body,
            let completeLength = result.contentRange.completeLength,
            initializationRange.endInclusive < completeLength
        else { throw BilivideoRouteBenchmarkError.invalidProbeRange }
        let index = try SIDXParser().parse(
            body,
            boxStartOffset: UInt64(indexRange.start)
        )
        return CanonicalProbe(
            index: index,
            completeLength: completeLength,
            probeRanges: try spreadProbeRanges(
                index.references,
                completeLength: completeLength,
                maximumBytes: Self.maximumMediaProbeBytes - initializationRange.length
            )
        )
    }

    private func spreadProbeRanges(
        _ references: [SegmentReference],
        completeLength: Int64,
        maximumBytes: UInt64
    ) throws -> [HTTPByteRange] {
        guard references.count >= 2,
            references.allSatisfy({
                $0.byteRange.start >= 0
                    && $0.byteRange.endInclusive >= $0.byteRange.start
                    && $0.byteRange.endInclusive < completeLength
            })
        else { throw BilivideoRouteBenchmarkError.invalidProbeRange }

        let last = references.count - 1
        let anchors = [
            0, last, references.count / 2, references.count / 4,
            3 * references.count / 4,
        ]
        let priority = anchors + references.indices.filter { !anchors.contains($0) }
        var selected: [HTTPByteRange] = []
        var selectedIndices: Set<Int> = []
        var totalBytes: UInt64 = 0
        for index in priority where selectedIndices.insert(index).inserted {
            let range = references[index].byteRange
            let length = UInt64(range.endInclusive - range.start + 1)
            guard length <= maximumBytes,
                totalBytes <= maximumBytes - length
            else { continue }
            selected.append(
                try HTTPByteRange(start: range.start, endInclusive: range.endInclusive)
            )
            totalBytes += length
        }
        guard selected.count >= 2, totalBytes <= maximumBytes else {
            throw BilivideoRouteBenchmarkError.invalidProbeRange
        }
        return selected.sorted { $0.start < $1.start }
    }

    private func unifiedCandidates(
        for template: MediaRepresentation
    ) throws -> [(PlaybackRouteTarget, URL)] {
        let bilivideoTemplate = try serverBilivideoURL(for: template)
        guard
            let akamaiURL = template.urlCandidates.first(where: {
                PlaybackSourceClassifier.category(for: $0) == .akamai
            })
        else { throw BilivideoRouteBenchmarkError.incompleteCandidatePool }
        let candidates =
            [(PlaybackRouteTarget.serverAkamai, akamaiURL)]
            + BilivideoRoute.allCases.compactMap { route in
                route.replacingHost(in: bilivideoTemplate).map {
                    (PlaybackRouteTarget.bilivideo(route), $0)
                }
            }
        guard candidates.count == PlaybackRouteTarget.allCases.count else {
            throw BilivideoRouteBenchmarkError.incompleteCandidatePool
        }
        return candidates
    }

    private func serverBilivideoURL(for template: MediaRepresentation) throws -> URL {
        guard
            let url = template.urlCandidates.first(where: {
                PlaybackSourceClassifier.category(for: $0) == .bilivideo
            })
        else { throw BilivideoRouteBenchmarkError.incompleteCandidatePool }
        return url
    }

    private func aggregate<Target: Hashable & Sendable>(
        _ values: [Target: [Double]],
        totalRuns: Int,
        order: [Target]
    ) -> [RouteProbeResult<Target>] {
        order.map { target in
            let successful = values[target, default: []]
                .filter { $0.isFinite && $0 > 0 }
                .sorted()
            return RouteProbeResult(
                target: target,
                effectiveBitsPerSecond: harmonicMean(successful),
                minimumBitsPerSecond: successful.first,
                medianBitsPerSecond: median(successful),
                sampleBitsPerSecond: successful,
                successfulRuns: successful.count,
                totalRuns: totalRuns
            )
        }.sorted { lhs, rhs in
            let leftSuccess = lhs.successfulRuns * rhs.totalRuns
            let rightSuccess = rhs.successfulRuns * lhs.totalRuns
            if leftSuccess != rightSuccess { return leftSuccess > rightSuccess }
            switch (lhs.effectiveBitsPerSecond, rhs.effectiveBitsPerSecond) {
            case (let .some(left), let .some(right)) where left != right:
                return left > right
            case (.some, .none): return true
            case (.none, .some): return false
            default: break
            }
            switch (lhs.minimumBitsPerSecond, rhs.minimumBitsPerSecond) {
            case (let .some(left), let .some(right)) where left != right:
                return left > right
            case (.some, .none): return true
            case (.none, .some): return false
            default:
                return (order.firstIndex(of: lhs.target) ?? .max)
                    < (order.firstIndex(of: rhs.target) ?? .max)
            }
        }
    }

    private func harmonicMean(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let reciprocalSum = values.reduce(0) { $0 + 1 / $1 }
        guard reciprocalSum.isFinite, reciprocalSum > 0 else { return nil }
        return Double(values.count) / reciprocalSum
    }

    private func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let middle = values.count / 2
        if values.count.isMultiple(of: 2) {
            return (values[middle - 1] + values[middle]) / 2
        }
        return values[middle]
    }

    private func rotated<Element>(_ values: [Element], by rawOffset: Int) -> [Element] {
        guard !values.isEmpty else { return [] }
        let offset = rawOffset % values.count
        return Array(values[offset...]) + Array(values[..<offset])
    }
}
