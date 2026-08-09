import Foundation
import Testing

@testable import BiliPlayback

struct AudioFormatMetadataParserTests {
    @Test
    func readsAACSampleEntryMetadataFromInitialization() throws {
        let initialization = try initialization(
            from: fixture(named: "audio-aac-4s-global-sidx.mp4")
        )

        let metadata = try AudioFormatMetadataParser().parse(initialization)

        #expect(metadata.channelCount == 2)
        #expect(metadata.bitDepth == 16)
        #expect(metadata.sampleRate == 48_000)
    }

    @Test
    func rejectsNonAudioAndTruncatedInitializations() throws {
        let videoInitialization = try initialization(
            from: fixture(named: "video-avc-128x72-4s-global-sidx.mp4")
        )
        #expect(
            throws: AudioFormatMetadataParserError.missingAudioSampleEntry
        ) {
            try AudioFormatMetadataParser().parse(videoInitialization)
        }

        let audioInitialization = try initialization(
            from: fixture(named: "audio-aac-4s-global-sidx.mp4")
        )
        #expect(throws: AudioFormatMetadataParserError.self) {
            try AudioFormatMetadataParser().parse(audioInitialization.dropLast())
        }
    }

    private func fixture(named name: String) throws -> Data {
        let url = try #require(
            Bundle.module.url(
                forResource: name,
                withExtension: "base64",
                subdirectory: "Fixtures"
            )
        )
        let encoded = try String(contentsOf: url, encoding: .utf8)
            .filter { !$0.isWhitespace }
        return try #require(Data(base64Encoded: encoded))
    }

    private func initialization(from media: Data) throws -> Data {
        var offset = 0
        while offset + 8 <= media.count {
            let size = Int(
                media[offset..<(offset + 4)].reduce(UInt32(0)) {
                    ($0 << 8) | UInt32($1)
                }
            )
            guard size >= 8, size <= media.count - offset else {
                Issue.record("Invalid top-level fixture box")
                return Data()
            }
            let type = String(
                bytes: media[(offset + 4)..<(offset + 8)],
                encoding: .isoLatin1
            )
            if type == "sidx" {
                return media.prefix(upTo: offset)
            }
            offset += size
        }
        Issue.record("Fixture is missing sidx")
        return Data()
    }
}
