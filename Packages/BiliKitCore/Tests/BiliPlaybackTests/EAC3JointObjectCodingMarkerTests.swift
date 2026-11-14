import Foundation
import Testing

@testable import BiliPlayback

/// 固定 JOC 标记的改写范围：只改与 B 站全景声 init 实测形状相同的 init（成功路径见
/// `DASHBridgeAudioGroupTests`），其他形状一律不改，调用方按普通杜比音频发布。
struct EAC3JointObjectCodingMarkerTests {
    struct Case: Sendable, CustomTestStringConvertible {
        let testDescription: String
        let initialization: @Sendable () -> Data
    }

    @Test(arguments: [
        Case(testDescription: "dec3 已带扩展字节") {
            makeAudioInitialization(
                sampleEntry: "ec-3",
                children: isoBox("dec3", Data([0x14, 0x00, 0x20, 0x0f, 0x00, 0x01, 0x10]))
            )
        },
        Case(testDescription: "有依赖子流") {
            makeAudioInitialization(
                sampleEntry: "ec-3",
                children: eac3Configuration(acmod: 7, lfe: true, dependentSubstreams: 1)
            )
        },
        Case(testDescription: "两个独立子流") {
            makeAudioInitialization(
                sampleEntry: "ec-3",
                children: isoBox("dec3", Data([0x14, 0x01, 0x20, 0x0f, 0x00]))
            )
        },
        Case(testDescription: "不是 E-AC-3") {
            makeAudioInitialization(sampleEntry: "mp4a", children: Data())
        },
        Case(testDescription: "截断") {
            makeAudioInitialization(sampleEntry: "ec-3", children: biliAtmosDEC3()).dropLast()
        }
    ])
    func leavesOtherShapesUnmarked(_ fixture: Case) {
        #expect(EAC3JointObjectCodingMarker.marked(fixture.initialization()) == nil)
    }
}
