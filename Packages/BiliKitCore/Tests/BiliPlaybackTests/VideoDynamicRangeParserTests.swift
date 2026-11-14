import Foundation
import Testing

@testable import BiliPlayback

/// 固定 HDR 档的动态范围判定：HDR 真彩按 `colr` 的 PQ／HLG 写 `VIDEO-RANGE`；杜比视界接受基础层兼容
/// HLG 或 PQ 的 profile 8 并给出 `SUPPLEMENTAL-CODECS`，以及 `dvh1` 的 profile 5 并要求 `CODECS` 为
/// `dvh1.05.LL`、写 PQ；SDR、`dvhe` 的 profile 5、畸形或超限的 init 让这一档被丢弃。
struct VideoDynamicRangeParserTests {
    struct Case: Sendable, CustomTestStringConvertible {
        let name: String
        let transfer: UInt16?
        var sampleEntry = "hvc1"
        let dolbyVision: DolbyVisionFixture?
        let range: HLSVideoRange
        let supplementalCodecs: String?
        var requiredCodecs: String?

        var testDescription: String { name }
    }

    @Test(arguments: [
        Case(
            name: "HDR 真彩 PQ",
            transfer: 16,
            dolbyVision: nil,
            range: .pq,
            supplementalCodecs: nil
        ),
        Case(name: "HLG", transfer: 18, dolbyVision: nil, range: .hlg, supplementalCodecs: nil),
        Case(
            name: "杜比视界 8.4 level 5",
            transfer: 18,
            dolbyVision: DolbyVisionFixture(profile: 8, level: 5, compatibilityID: 4),
            range: .hlg,
            supplementalCodecs: "dvh1.08.05/db4h"
        ),
        Case(
            name: "杜比视界 8.1 level 6，没有 colr",
            transfer: nil,
            dolbyVision: DolbyVisionFixture(profile: 8, level: 6, compatibilityID: 1),
            range: .pq,
            supplementalCodecs: "dvh1.08.06/db1p"
        ),
        Case(
            name: "杜比视界 5 level 6，dvh1，没有 colr",
            transfer: nil,
            sampleEntry: "dvh1",
            dolbyVision: DolbyVisionFixture(profile: 5, level: 6, compatibilityID: 0),
            range: .pq,
            supplementalCodecs: nil,
            requiredCodecs: "dvh1.05.06"
        )
    ])
    func readsDynamicRangeFromSampleEntry(_ fixture: Case) throws {
        let metadata = try VideoDynamicRangeParser().parse(
            makeHEVCInitialization(
                sampleEntry: fixture.sampleEntry,
                transfer: fixture.transfer,
                dolbyVision: fixture.dolbyVision
            )
        )

        #expect(metadata.range == fixture.range)
        #expect(metadata.supplementalCodecs == fixture.supplementalCodecs)
        #expect(metadata.requiredCodecs == fixture.requiredCodecs)
    }

    @Test
    func rejectsInitializationsThatCannotBeAnHDRRung() throws {
        let parser = VideoDynamicRangeParser()
        #expect(throws: VideoDynamicRangeParserError.notHighDynamicRange) {
            try parser.parse(makeHEVCInitialization(transfer: 1))
        }
        #expect(throws: VideoDynamicRangeParserError.missingColorInformation) {
            try parser.parse(makeHEVCInitialization(transfer: nil))
        }
        #expect(
            throws: VideoDynamicRangeParserError.unsupportedDolbyVisionConfiguration(
                profile: 5,
                compatibilityID: 0
            )
        ) {
            try parser.parse(
                makeHEVCInitialization(
                    sampleEntry: "dvhe",
                    transfer: nil,
                    dolbyVision: DolbyVisionFixture(profile: 5, level: 6, compatibilityID: 0)
                )
            )
        }
        #expect(throws: VideoDynamicRangeParserError.missingVideoSampleEntry) {
            try parser.parse(makeHEVCInitialization(sampleEntry: "avc1"))
        }
        #expect(throws: VideoDynamicRangeParserError.malformedBoxStructure) {
            try parser.parse(makeHEVCInitialization().dropLast())
        }
        #expect(throws: VideoDynamicRangeParserError.initializationTooLarge) {
            try parser.parse(Data(count: InitializationSegmentLoader.maximumByteCount + 1))
        }
    }
}
