import Foundation
import Testing

@testable import BiliPlayback

/// 固定 HDR 档的动态范围判定：HDR 真彩按 `colr` 的 PQ／HLG 写 `VIDEO-RANGE`，杜比视界只接受基础层兼容
/// HLG 或 PQ 的 profile 8 并给出 `SUPPLEMENTAL-CODECS`；SDR、profile 5、畸形或超限的 init 让这一档被丢弃。
struct VideoDynamicRangeParserTests {
    struct Case: Sendable, CustomTestStringConvertible {
        let name: String
        let transfer: UInt16?
        let dolbyVision: DolbyVisionFixture?
        let range: HLSVideoRange
        let supplementalCodecs: String?

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
        )
    ])
    func readsDynamicRangeFromSampleEntry(_ fixture: Case) throws {
        let metadata = try VideoDynamicRangeParser().parse(
            makeHEVCInitialization(transfer: fixture.transfer, dolbyVision: fixture.dolbyVision)
        )

        #expect(metadata.range == fixture.range)
        #expect(metadata.supplementalCodecs == fixture.supplementalCodecs)
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
