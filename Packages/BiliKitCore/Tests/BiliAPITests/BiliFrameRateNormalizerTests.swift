import Testing

@testable import BiliAPI

/// 固定帧率归一：标准帧率原样保留，B 站时间刻度桶与小幅漂移归到最近的标准帧率，其余 1–120 的报告值
/// 原样保留；空值、非正、除零与超出 1–120 的值给 nil。
struct BiliFrameRateNormalizerTests {
    @Test(arguments: [
        FrameRateCase(rawValue: "24000/1001", expected: 24_000.0 / 1_001.0),
        FrameRateCase(rawValue: "30000/1001", expected: 30_000.0 / 1_001.0),
        FrameRateCase(rawValue: "60000/1001", expected: 60_000.0 / 1_001.0),
        FrameRateCase(rawValue: "120000/1001", expected: 120_000.0 / 1_001.0),
        FrameRateCase(rawValue: "24", expected: 24),
        FrameRateCase(rawValue: "25", expected: 25),
        FrameRateCase(rawValue: "30", expected: 30),
        FrameRateCase(rawValue: "50", expected: 50),
        FrameRateCase(rawValue: "60", expected: 60),
        FrameRateCase(rawValue: "120", expected: 120)
    ])
    func preservesExplicitStandardRates(testCase: FrameRateCase) {
        #expect(
            BiliFrameRateNormalizer.normalizedValue(
                from: testCase.rawValue
            ) == testCase.expected
        )
    }

    @Test(arguments: [
        FrameRateCase(rawValue: "16000/672", expected: 24),
        FrameRateCase(rawValue: "16000/656", expected: 24),
        FrameRateCase(rawValue: "16000/640", expected: 25),
        FrameRateCase(rawValue: "16000/544", expected: 30),
        FrameRateCase(rawValue: "16000/528", expected: 30),
        FrameRateCase(rawValue: "16000/320", expected: 50),
        FrameRateCase(rawValue: "16000/272", expected: 60),
        FrameRateCase(rawValue: "16000/256", expected: 60),
        FrameRateCase(rawValue: "16000/144", expected: 120),
        FrameRateCase(rawValue: "16000/128", expected: 120),
        FrameRateCase(rawValue: "30.303", expected: 30),
        FrameRateCase(rawValue: "58.824", expected: 60),
        FrameRateCase(rawValue: "62.500", expected: 60),
        FrameRateCase(rawValue: "111.111", expected: 120),
        FrameRateCase(rawValue: "125.000", expected: 120)
    ])
    func normalizesBiliTimescaleBuckets(testCase: FrameRateCase) {
        #expect(
            BiliFrameRateNormalizer.normalizedValue(
                from: testCase.rawValue
            ) == testCase.expected
        )
    }

    @Test(arguments: [
        FrameRateCase(rawValue: "29.976", expected: 30_000.0 / 1_001.0),
        FrameRateCase(rawValue: "30.019", expected: 30),
        FrameRateCase(rawValue: "59.940", expected: 60_000.0 / 1_001.0),
        FrameRateCase(rawValue: "60.001", expected: 60),
        FrameRateCase(rawValue: "60.150", expected: 60),
        FrameRateCase(rawValue: "119.880", expected: 120_000.0 / 1_001.0),
        FrameRateCase(rawValue: "120.150", expected: 120)
    ])
    func normalizesSmallReportedDrift(testCase: FrameRateCase) {
        #expect(
            BiliFrameRateNormalizer.normalizedValue(
                from: testCase.rawValue
            ) == testCase.expected
        )
    }

    /// 归不到名义帧率的值按 B 站报告的帧率原样保留：master 的 `FRAME-RATE` 本来就是“四舍五入到三位小数的
    /// 最高帧率”，丢掉它会让 HDR 档因缺帧率被丢弃，而同一值的 SDR 档照常发布。
    @Test(arguments: ["15", "20", "48", "90", "100", "12.500", "37.2"])
    func preservesReportedRatesThatAreNotNominal(rawValue: String) {
        #expect(
            BiliFrameRateNormalizer.normalizedValue(from: rawValue)
                == Double(rawValue)
        )
    }

    @Test(
        arguments: [
            nil,
            "",
            " ",
            "0",
            "-1",
            "nan",
            "60/0",
            "60/",
            "0.5",
            "240"
        ] as [String?]
    )
    func rejectsUnreliableValues(rawValue: String?) {
        #expect(BiliFrameRateNormalizer.normalizedValue(from: rawValue) == nil)
    }
}

struct FrameRateCase: Sendable {
    let rawValue: String
    let expected: Double
}
