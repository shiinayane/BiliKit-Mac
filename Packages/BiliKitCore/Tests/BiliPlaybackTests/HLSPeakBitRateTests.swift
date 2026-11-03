import BiliModels
import Foundation
import Testing

@testable import BiliPlayback

/// HLS 峰值码率等于按定义逐个窗口求出的精确值，并对精确比值向上取整。
///
/// 合法窗口的时长在目标时长的 0.5–1.5 倍之间；用逐起点累加的参考实现对照边界用例、固定反例与多种 timescale 的
/// 随机输入，并用闭式结果固定参考实现跑不动的病态索引。
@Suite(.timeLimit(.minutes(1)))
struct HLSPeakBitRateTests {
    @Test(arguments: peakBoundaryCases)
    func matchesExactWindowDefinition(_ peakCase: PeakCase) throws {
        try expectMatchesReference(peakCase.index)
    }

    /// 浮点逐段累加会把恰好等于 1.5×目标时长的窗口误判超限，或在整数比值上多进 1。
    @Test(arguments: [
        // 1+10+3+1 tick 恰好 1.5 秒：32 bit ÷ 1.5 s 向上取整为 22，浮点累加漏掉该窗口只得 19。
        (
            PeakCase(
                timescale: 10,
                segments: [.init(1, 2), .init(1, 1), .init(1, 10), .init(1, 3), .init(1, 1)]
            ),
            22
        ),
        // 9792 bit × 7 ÷ 17 tick 恰为 4032，浮点除法得到略大于 4032 的值后会进到 4033。
        (PeakCase(timescale: 7, segments: [.init(1_224, 17)]), 4_032)
    ])
    func fixedCounterexamplesYieldExactCeiling(_ peakCase: PeakCase, _ expected: Int) throws {
        #expect(try HLSPeakBitRate.peak(of: peakCase.index) == expected)
        #expect(referencePeak(of: peakCase.index) == expected)
    }

    /// 时长取 timescale/10 的倍数，频繁命中 0.5×、1.5×目标时长的等号边界。
    @Test(arguments: [7, 10, 1_000, 44_100, 90_000] as [UInt32])
    func matchesExactWindowDefinitionAcrossTimescales(_ timescale: UInt32) throws {
        var generator = LinearCongruentialGenerator(seed: UInt64(timescale))
        let tick = max(1, timescale / 10)
        for _ in 0..<200 {
            let count = Int(generator.next() % 24) + 1
            let segments = (0..<count).map { _ in
                PeakCase.Segment(
                    UInt64(generator.next() % 4_000_000) + 1,
                    tick * (UInt32(generator.next() % 60) + 1)
                )
            }
            try expectMatchesReference(PeakCase(timescale: timescale, segments: segments).index)
        }
    }

    @Test
    func pathologicalIndexYieldsClosedFormPeak() throws {
        // reference_count 上限 65535：逐起点累加需要约 21 亿步。只有包含长分段的窗口合法，
        // 每多带一个 1 tick 短分段码率都更高，所以峰值窗口就是全部分段。
        let shortByteCounts = (0..<65_534).map { UInt64(1_000 + $0 % 4_999) }
        let segments =
            shortByteCounts.map { PeakCase.Segment($0, 1) }
            + [PeakCase.Segment(10, 90_000 * 600)]
        let index = PeakCase(timescale: 90_000, segments: segments).index
        let bits = Int128(shortByteCounts.reduce(10, +)) * 8
        let ticks = Int128(90_000 * 600 + shortByteCounts.count)
        let expected = Int((bits * 90_000 + ticks - 1) / ticks)

        #expect(try HLSPeakBitRate.peak(of: index) == expected)
    }

    private func expectMatchesReference(_ index: SegmentIndex) throws {
        if let expected = referencePeak(of: index) {
            #expect(try HLSPeakBitRate.peak(of: index) == expected)
        } else {
            #expect(throws: HLSPlaylistBuilderError.invalidCalculatedBitRate) {
                try HLSPeakBitRate.peak(of: index)
            }
        }
    }

    /// 按定义逐个起点累加窗口求峰值，没有合法窗口时为 nil。
    ///
    /// 时长超过上界即停；比值用整数交叉相乘比较，结果对精确比值向上取整。
    private func referencePeak(of index: SegmentIndex) -> Int? {
        let timescale = Int128(index.timescale)
        let segments = index.references.map { reference in
            let byteCount =
                Int128(reference.byteRange.endInclusive) - Int128(reference.byteRange.start) + 1
            return (bits: byteCount * 8, ticks: Int128(reference.duration))
        }
        guard let target = segments.map({ ($0.ticks + timescale - 1) / timescale }).max()
        else { return nil }
        var best: (bits: Int128, ticks: Int128)?
        for start in segments.indices {
            var bits: Int128 = 0
            var ticks: Int128 = 0
            for end in start..<segments.endIndex {
                bits += segments[end].bits
                ticks += segments[end].ticks
                if 2 * ticks > 3 * target * timescale { break }
                guard 2 * ticks >= target * timescale else { continue }
                if best.map({ bits * $0.ticks > $0.bits * ticks }) ?? true {
                    best = (bits, ticks)
                }
            }
        }
        return best.map { Int(($0.bits * timescale + $0.ticks - 1) / $0.ticks) }
    }
}

private let manyShortSegments: [PeakCase.Segment] = (0..<2_000).map {
    PeakCase.Segment(UInt64(1_000 + $0 % 37), 1)
}

let peakBoundaryCases: [PeakCase] = [
    // 普通：90 kHz、2 秒等长分段。
    PeakCase(timescale: 90_000, segments: [.init(500_000, 180_000), .init(900_000, 180_000)]),
    // 单个分段恰好等于 0.5×目标时长（下界含等号）。
    PeakCase(timescale: 4, segments: [.init(9_000, 2), .init(1_000, 4)]),
    // 三段合计恰好等于 1.5×目标时长（上界含等号）。
    PeakCase(
        timescale: 4,
        segments: [.init(1_000, 2), .init(6_000, 2), .init(1_000, 2), .init(100, 4)]
    ),
    // 非二进制 timescale 下恰好等于 1.5×目标时长的窗口。
    PeakCase(
        timescale: 10,
        segments: [.init(3_000, 3), .init(2_000, 10), .init(3_000, 2), .init(100, 5)]
    ),
    // 最高码率出现在较短窗口而不是最长合法窗口。
    PeakCase(timescale: 1, segments: [.init(10, 1), .init(80, 1), .init(10, 1), .init(10, 2)]),
    // 只有一个过短分段：没有合法窗口。
    PeakCase(timescale: 4, segments: [.init(1_000, 1)]),
    // 大量极短分段加一个极长分段。
    PeakCase(timescale: 1_024, segments: manyShortSegments + [.init(5, 1_024 * 8)])
]

struct PeakCase: Sendable, CustomTestStringConvertible {
    struct Segment: Sendable {
        let byteCount: UInt64
        let ticks: UInt32

        init(_ byteCount: UInt64, _ ticks: UInt32) {
            self.byteCount = byteCount
            self.ticks = ticks
        }
    }

    let timescale: UInt32
    let segments: [Segment]

    var testDescription: String { "\(segments.count) segments @ \(timescale)" }

    var index: SegmentIndex {
        var offset: Int64 = 0
        let references = segments.map { segment in
            defer { offset += Int64(segment.byteCount) }
            return SegmentReference(
                byteRange: try! MediaByteRange(
                    start: offset,
                    endInclusive: offset + Int64(segment.byteCount) - 1
                ),
                duration: segment.ticks,
                startsWithSAP: true,
                sapType: 1,
                sapDeltaTime: 0
            )
        }
        return SegmentIndex(
            referenceID: 1,
            timescale: timescale,
            earliestPresentationTime: 0,
            firstOffset: 0,
            references: references
        )
    }
}

/// 固定种子的可复现输入生成器。
private struct LinearCongruentialGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state >> 33
    }
}
