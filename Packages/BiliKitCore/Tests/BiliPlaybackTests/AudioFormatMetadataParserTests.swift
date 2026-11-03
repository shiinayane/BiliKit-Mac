import Foundation
import Testing

@testable import BiliPlayback

/// 音频格式元数据从 init 段的 AAC sample entry 读出声道、位深与采样率，非音频或截断的 init 段报错。
struct AudioFormatMetadataParserTests {
    @Test
    func readsAACSampleEntryMetadataFromInitialization() throws {
        let initialization = try initialization(
            from: fixtureBase64Data(named: "audio-aac-4s-global-sidx.mp4")
        )

        let metadata = try AudioFormatMetadataParser().parse(initialization)

        #expect(metadata.channelCount == 2)
        #expect(metadata.bitDepth == 16)
        #expect(metadata.sampleRate == 48_000)
    }

    @Test
    func rejectsNonAudioAndTruncatedInitializations() throws {
        let videoInitialization = try initialization(
            from: fixtureBase64Data(named: "video-avc-128x72-4s-global-sidx.mp4")
        )
        #expect(
            throws: AudioFormatMetadataParserError.missingAudioSampleEntry
        ) {
            try AudioFormatMetadataParser().parse(videoInitialization)
        }

        let audioInitialization = try initialization(
            from: fixtureBase64Data(named: "audio-aac-4s-global-sidx.mp4")
        )
        #expect(throws: AudioFormatMetadataParserError.self) {
            try AudioFormatMetadataParser().parse(audioInitialization.dropLast())
        }
    }

    /// init 段是首个顶层 `sidx` box 之前的全部字节。
    private func initialization(from media: Data) throws -> Data {
        let sidx = try #require(firstTopLevelBox(named: "sidx", in: media))
        return media.prefix(upTo: sidx.offset)
    }
}
