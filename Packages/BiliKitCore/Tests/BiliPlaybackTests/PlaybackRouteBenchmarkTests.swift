import BiliModels
import BiliNetworking
import Foundation
import Testing

@testable import BiliPlayback

struct PlaybackRouteBenchmarkTests {
    @Test
    func routeCatalogContainsTheReviewedResolvableUPOSHosts() {
        let expectedHosts: Set<String> = [
            "upos-sz-mirrorali.bilivideo.com",
            "upos-sz-mirroralib.bilivideo.com",
            "upos-sz-mirroralio1.bilivideo.com",
            "upos-sz-mirrorcos.bilivideo.com",
            "upos-sz-mirrorcosb.bilivideo.com",
            "upos-sz-mirrorcoso1.bilivideo.com",
            "upos-sz-mirrorhw.bilivideo.com",
            "upos-sz-mirrorhwb.bilivideo.com",
            "upos-sz-mirrorhwo1.bilivideo.com",
            "upos-sz-mirror08c.bilivideo.com",
            "upos-sz-mirror08h.bilivideo.com",
            "upos-sz-mirror08ct.bilivideo.com",
            "upos-tf-all-hw.bilivideo.com",
            "upos-tf-all-tx.bilivideo.com",
            "upos-sz-mirroraliov.bilivideo.com",
            "upos-sz-mirrorcosov.bilivideo.com",
            "upos-sz-mirrorbos.bilivideo.com",
            "upos-sz-upcdnbda2.bilivideo.com",
        ]

        #expect(Set(BilivideoRoute.allCases.map(\.host)) == expectedHosts)
        #expect(!expectedHosts.contains("upos-sz-mirrorhwov.bilivideo.com"))
    }

    @Test
    func eachRouteHasAnExactTenMiBMediaCap() {
        let minimumCompletedBitsPerSecond =
            Double(BilivideoRouteBenchmark.maximumMediaProbeBytes) * 8
            / BilivideoRouteBenchmark.resourceTimeout
        #expect(BilivideoRouteBenchmark.maximumMediaProbeBytes == 10 * 1_024 * 1_024)
        #expect(minimumCompletedBitsPerSecond < 3_000_000)
    }

    @Test
    func routeReplacementKeepsSignedSuffixByteForByte() throws {
        let source = try #require(
            URL(
                string:
                    "https://upos-sz-mirrorhw.bilivideo.com/upgcxcode/a%2Fb.m4s?deadline=1&token=a%2Bb%2Fz&n=hello+world"
            )
        )

        let result = try #require(
            BilivideoRoute.tencentOverseas.replacingHost(in: source)
        )

        #expect(result.host == BilivideoRoute.tencentOverseas.host)
        #expect(
            result.absoluteString
                == "https://upos-sz-mirrorcosov.bilivideo.com/upgcxcode/a%2Fb.m4s?deadline=1&token=a%2Bb%2Fz&n=hello+world"
        )
    }

    @Test
    func routeReplacementRejectsAkamaiTemplate() throws {
        let source = try #require(
            URL(
                string: "https://upos-hz-mirrorakam.akamaized.net/video.m4s?hdnts=secret"
            )
        )
        #expect(BilivideoRoute.tencentMainland.replacingHost(in: source) == nil)
    }

    @Test
    func manualRouteAddsExperimentalFirstAndKeepsOriginalCandidatesExact() throws {
        let original = try makeRepresentation(includesAkamai: true)
        let result = PlaybackSourceOrdering.applying(
            .experimentalBilivideoRoute(.tencentOverseas),
            to: original
        )

        #expect(result.primaryURL.host == BilivideoRoute.tencentOverseas.host)
        #expect(Array(result.urlCandidates.dropFirst()) == original.urlCandidates)
        #expect(result.primaryURL.path == original.primaryURL.path)
        #expect(result.primaryURL.query == original.primaryURL.query)
    }

    @Test
    func manualRouteDoesNotChangeAudio() throws {
        let video = try makeRepresentation(includesAkamai: true)
        let audio = MediaRepresentation(
            id: video.id,
            kind: .audio,
            codecs: video.codecs,
            mimeType: video.mimeType,
            bandwidth: video.bandwidth,
            videoAttributes: nil,
            primaryURL: video.primaryURL,
            backupURLs: video.backupURLs,
            segmentBase: video.segmentBase
        )
        #expect(
            PlaybackSourceOrdering.applying(
                .experimentalBilivideoRoute(.huaweiMainland),
                to: audio
            ) == audio
        )
    }

    @Test
    func serverDefaultAndMissingCategoryKeepExactCandidateOrder() throws {
        let original = try makeRepresentation()
        #expect(
            PlaybackSourceOrdering.applying(.serverDefault, to: original)
                == original
        )
        #expect(
            PlaybackSourceOrdering.applying(.category(.akamai), to: original)
                == original
        )
    }

    @Test
    func originalCategoryPreferenceUsesStablePartition() throws {
        let original = try makeRepresentation(includesAkamai: true)
        let result = PlaybackSourceOrdering.applying(
            .category(.akamai),
            to: original
        )
        #expect(result.urlCandidates.last == original.primaryURL)
        #expect(Set(result.urlCandidates) == Set(original.urlCandidates))
    }

    @Test
    func unifiedPoolUsesOriginalAkamaiAndGeneratesOnlyBilivideoRoutes() async throws {
        let fetcher = RouteBenchmarkRangeFetcher()
        let runner = BilivideoRouteBenchmark(rangeFetcher: fetcher)
        let representation = try makeRepresentation(includesAkamai: true)

        let results = try await runner.benchmarkUnifiedPool(
            template: representation,
            headers: [:]
        )
        let calls = await fetcher.calls

        let candidateCount = PlaybackRouteTarget.allCases.count
        #expect(results.count == candidateCount)
        #expect(calls.count == 1 + candidateCount * 4)
        #expect(calls[0].host == "upos-sz-mirrordefault.bilivideo.com")
        #expect(calls[1..<5].allSatisfy { $0.host == "upos-hz-mirrorakam.akamaized.net" })
        #expect(calls.dropFirst(5).allSatisfy { $0.host.hasSuffix(".bilivideo.com") })
        #expect(
            calls.dropFirst().allSatisfy {
                $0.host != "upos-sz-mirrordefault.bilivideo.com"
            }
        )
    }

    @Test
    func repeatedBenchmarkAveragesSuccessfulThroughputAndExpandsProgress() async throws {
        let fetcher = RouteBenchmarkRangeFetcher(mediaDurationsByRun: [1, 1, 3, 3])
        let progress = RouteBenchmarkProgressRecorder()
        let runner = BilivideoRouteBenchmark(rangeFetcher: fetcher)
        let repetitions = 2

        let results = try await runner.benchmarkUnifiedPool(
            template: makeRepresentation(includesAkamai: true),
            headers: [:],
            repetitions: repetitions
        ) { completed, total in
            await progress.record(completed: completed, total: total)
        }

        let candidateCount = PlaybackRouteTarget.allCases.count
        let mediaBits = Double(4 * 1_024 * 1_024) * 8
        let expectedAverage = 2 / (1 / (mediaBits / 1) + 1 / (mediaBits / 3))
        #expect(await fetcher.calls.count == repetitions * (1 + candidateCount * 4))
        #expect(
            await progress.latest == (candidateCount * repetitions, candidateCount * repetitions)
        )
        #expect(
            results.allSatisfy { result in
                result.successfulRuns == repetitions
                    && result.totalRuns == repetitions
                    && abs((result.effectiveBitsPerSecond ?? 0) - expectedAverage) < 0.001
            }
        )
    }

    @Test
    func failedRoundIsExcludedFromAverageButKeptInSuccessCount() async throws {
        let akamaiHost = "upos-hz-mirrorakam.akamaized.net"
        let fetcher = RouteBenchmarkRangeFetcher(
            mediaDurationsByRun: [1, 1, 2, 2, 3, 3],
            failedMediaRun: (host: akamaiHost, index: 2)
        )
        let results = try await BilivideoRouteBenchmark(rangeFetcher: fetcher)
            .benchmarkUnifiedPool(
                template: makeRepresentation(includesAkamai: true),
                headers: [:],
                repetitions: 3
            )
        let result = try #require(results.first(where: { $0.target == .serverAkamai }))
        let mediaBits = Double(4 * 1_024 * 1_024) * 8

        #expect(result.target == .serverAkamai)
        #expect(result.successfulRuns == 2)
        #expect(result.totalRuns == 3)
        #expect(
            abs(
                (result.effectiveBitsPerSecond ?? 0) - 2
                    / (1 / (mediaBits / 1) + 1 / (mediaBits / 3))
            )
                < 0.001
        )
    }

    @Test
    func unsupportedRepetitionCountFailsBeforeNetwork() async throws {
        let fetcher = RouteBenchmarkRangeFetcher()
        let runner = BilivideoRouteBenchmark(rangeFetcher: fetcher)

        await #expect(throws: BilivideoRouteBenchmarkError.invalidRepetitionCount(4)) {
            try await runner.benchmarkUnifiedPool(
                template: makeRepresentation(includesAkamai: true),
                headers: [:],
                repetitions: 4
            )
        }
        #expect(await fetcher.calls.isEmpty)
    }

    @Test
    func probeUsesSpreadWholeSIDXReferencesWithoutExceedingTenMiB() async throws {
        let completeLength: Int64 = 20_000_000
        let fetcher = RouteBenchmarkRangeFetcher(completeLength: completeLength)
        let runner = BilivideoRouteBenchmark(rangeFetcher: fetcher)

        let results = try await runner.benchmarkUnifiedPool(
            template: makeRepresentation(includesAkamai: true),
            headers: [:]
        )
        let calls = await fetcher.calls
        let mediaCalls = calls.filter { $0.range.start >= 108 }
        let expectedMediaRanges = [
            try HTTPByteRange(start: 108, endInclusive: 4_194_411),
            try HTTPByteRange(start: 8_388_716, endInclusive: 12_583_019),
        ]

        #expect(results.allSatisfy { $0.succeeded })
        #expect(
            mediaCalls.allSatisfy {
                expectedMediaRanges.contains($0.range)
                    && $0.range.length <= BilivideoRouteBenchmark.maximumMediaProbeBytes
            }
        )
        for candidateIndex in PlaybackRouteTarget.allCases.indices {
            let candidateStart = 1 + candidateIndex * 4
            let bodyCalls = calls[(candidateStart + 1)..<(candidateStart + 4)]
            #expect(
                bodyCalls.map(\.range.length).reduce(0, +)
                    <= BilivideoRouteBenchmark.maximumMediaProbeBytes
            )
        }
        #expect(calls.allSatisfy { $0.range.endInclusive < completeLength })
    }

    @Test
    func candidateWithDifferentParsedSIDXLayoutIsUnavailableBeforeMediaRequests() async throws {
        let mismatchedHost = BilivideoRoute.huaweiMainlandB.host
        let fetcher = RouteBenchmarkRangeFetcher(mismatchedIndexHost: mismatchedHost)
        let runner = BilivideoRouteBenchmark(rangeFetcher: fetcher)

        let results = try await runner.benchmarkUnifiedPool(
            template: makeRepresentation(includesAkamai: true),
            headers: [:]
        )
        let mismatched = results.first(where: {
            $0.target == .bilivideo(.huaweiMainlandB)
        })
        let mismatchedCalls = await fetcher.calls.filter { $0.host == mismatchedHost }
        let expectedIndexRange = try HTTPByteRange(start: 40, endInclusive: 107)

        #expect(mismatched?.succeeded == false)
        #expect(mismatchedCalls.count == 1)
        #expect(mismatchedCalls.first?.range == expectedIndexRange)
    }

    @Test(arguments: [false, true])
    func candidateWithDriftingCompleteLengthIsUnavailable(
        mismatchOnlyForMedia: Bool
    ) async throws {
        let mismatchedHost = BilivideoRoute.huaweiMainlandB.host
        let fetcher = RouteBenchmarkRangeFetcher(
            mismatchedCompleteLengthHost: mismatchedHost,
            mismatchOnlyForMedia: mismatchOnlyForMedia
        )

        let results = try await BilivideoRouteBenchmark(rangeFetcher: fetcher)
            .benchmarkUnifiedPool(
                template: makeRepresentation(includesAkamai: true),
                headers: [:]
            )
        let result = results.first {
            $0.target == .bilivideo(.huaweiMainlandB)
        }
        let calls = await fetcher.calls.filter { $0.host == mismatchedHost }

        #expect(result?.succeeded == false)
        #expect(calls.count == (mismatchOnlyForMedia ? 3 : 2))
    }

    @Test
    func oversizedIndexIsRejectedBeforeAnyNetworkRequest() async throws {
        let fetcher = RouteBenchmarkRangeFetcher()
        let runner = BilivideoRouteBenchmark(rangeFetcher: fetcher)
        let base = try makeRepresentation(includesAkamai: true)
        let oversized = MediaRepresentation(
            id: base.id,
            kind: base.kind,
            codecs: base.codecs,
            mimeType: base.mimeType,
            bandwidth: base.bandwidth,
            videoAttributes: base.videoAttributes,
            primaryURL: base.primaryURL,
            backupURLs: base.backupURLs,
            segmentBase: SegmentBase(
                initialization: try MediaByteRange(start: 0, endInclusive: 39),
                index: try MediaByteRange(
                    start: 40,
                    endInclusive: 40
                        + Int64(BilivideoRouteBenchmark.maximumIndexBytes)
                )
            )
        )

        await #expect(throws: BilivideoRouteBenchmarkError.invalidProbeRange) {
            try await runner.benchmarkUnifiedPool(template: oversized, headers: [:])
        }
        #expect(await fetcher.calls.isEmpty)
    }

    private func makeRepresentation(includesAkamai: Bool = false) throws -> MediaRepresentation {
        let akamai = try #require(
            URL(string: "https://upos-hz-mirrorakam.akamaized.net/video.m4s?hdnts=original")
        )
        return MediaRepresentation(
            id: 80,
            kind: .video,
            codecs: "avc1.640028",
            mimeType: "video/mp4",
            bandwidth: 8_000_000,
            videoAttributes: try VideoRepresentationAttributes(
                width: 1_920,
                height: 1_080,
                frameRate: 60
            ),
            primaryURL: try #require(
                URL(
                    string:
                        "https://upos-sz-mirrordefault.bilivideo.com/video.m4s?token=original"
                )
            ),
            backupURLs: includesAkamai ? [akamai] : [],
            segmentBase: SegmentBase(
                initialization: try MediaByteRange(start: 0, endInclusive: 39),
                index: try MediaByteRange(start: 40, endInclusive: 107)
            )
        )
    }
}

private actor RouteBenchmarkRangeFetcher: HTTPBoundedRangeFetching {
    private static let indexBody: Data = {
        let hexadecimal =
            "00000044736964780000000000000001000003e8000000000000000000000003"
            + "00400000000007d0900000000040000000000bb81000000a"
            + "0040000000000fa01000000a"
        return Data(
            stride(from: 0, to: hexadecimal.count, by: 2).compactMap { offset in
                let start = hexadecimal.index(hexadecimal.startIndex, offsetBy: offset)
                let end = hexadecimal.index(start, offsetBy: 2)
                return UInt8(hexadecimal[start..<end], radix: 16)
            }
        )
    }()

    struct Call: Sendable {
        let host: String
        let range: HTTPByteRange
    }

    private(set) var calls: [Call] = []
    private let completeLength: Int64
    private let mismatchedIndexHost: String?
    private let mismatchedCompleteLengthHost: String?
    private let mismatchOnlyForMedia: Bool
    private let mediaDurationsByRun: [Double]?
    private let failedMediaRun: (host: String, index: Int)?
    private var mediaRequestCounts: [String: Int] = [:]

    init(
        completeLength: Int64 = 32 * 1_024 * 1_024,
        mismatchedIndexHost: String? = nil,
        mismatchedCompleteLengthHost: String? = nil,
        mismatchOnlyForMedia: Bool = false,
        mediaDurationsByRun: [Double]? = nil,
        failedMediaRun: (host: String, index: Int)? = nil
    ) {
        self.completeLength = completeLength
        self.mismatchedIndexHost = mismatchedIndexHost
        self.mismatchedCompleteLengthHost = mismatchedCompleteLengthHost
        self.mismatchOnlyForMedia = mismatchOnlyForMedia
        self.mediaDurationsByRun = mediaDurationsByRun
        self.failedMediaRun = failedMediaRun
    }

    func fetch(
        from url: URL,
        range: HTTPByteRange,
        headers: [String: String],
        collectBody: Bool
    ) async throws -> HTTPBoundedRangeResult {
        let host = url.host ?? ""
        calls.append(Call(host: host, range: range))
        let isMedia = range.start >= 108
        let routeIndex =
            BilivideoRoute.allCases.firstIndex(where: {
                $0.host == host
            }) ?? 0
        let requestDuration: Double
        if isMedia, let mediaDurationsByRun, !mediaDurationsByRun.isEmpty {
            let runIndex = mediaRequestCounts[host, default: 0]
            mediaRequestCounts[host] = runIndex + 1
            if failedMediaRun?.host == host, failedMediaRun?.index == runIndex {
                throw RouteBenchmarkFixtureError.failedRound
            }
            requestDuration = mediaDurationsByRun[min(runIndex, mediaDurationsByRun.count - 1)]
        } else {
            requestDuration =
                Double(
                    BilivideoRoute.allCases.count - routeIndex
                ) / 10
        }
        var body = Self.indexBody
        if collectBody, host == mismatchedIndexHost {
            body[19] = 0xe9
        }
        let responseCompleteLength =
            host == mismatchedCompleteLengthHost
                && !collectBody
                && (isMedia || !mismatchOnlyForMedia)
            ? completeLength + 1 : completeLength
        return HTTPBoundedRangeResult(
            contentRange: try HTTPContentRange(
                start: range.start,
                endInclusive: range.endInclusive,
                completeLength: responseCompleteLength
            ),
            body: collectBody ? body : nil,
            byteCount: range.length,
            requestDurationSeconds: requestDuration
        )
    }
}

private enum RouteBenchmarkFixtureError: Error {
    case failedRound
}

private actor RouteBenchmarkProgressRecorder {
    private(set) var latest = (0, 0)

    func record(completed: Int, total: Int) {
        latest = (completed, total)
    }
}
