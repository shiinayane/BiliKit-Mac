import Foundation
import Testing

@testable import BiliModels
@testable import BiliNetworking
@testable import BiliPlayback

/// SIDX 只接受合规的直接引用 box 并换算成绝对字节范围；独立分段只有一个判定（非空且每段从 type 1、
/// delta 为 0 的 SAP 开始），media、master playlist 与 I-frame 都按它。
@Suite(.timeLimit(.minutes(1)))
struct SIDXParserTests {
    @Test
    func parsesSelfOwnedVersionZeroFixtureWithMultipleReferences() throws {
        let data = try fixtureData()

        let index = try SIDXParser().parse(data, boxStartOffset: 100)

        #expect(index.referenceID == 1)
        #expect(index.timescale == 1_000)
        #expect(index.earliestPresentationTime == 0)
        #expect(index.firstOffset == 0)
        #expect(index.references.count == 2)
        #expect(index.references[0].byteRange.start == 156)
        #expect(index.references[0].byteRange.endInclusive == 411)
        #expect(index.references[0].duration == 2_000)
        #expect(index.references[0].startsWithSAP)
        #expect(index.references[0].sapType == 1)
        #expect(index.references[1].byteRange.start == 412)
        #expect(index.references[1].byteRange.endInclusive == 923)
        #expect(index.references[1].duration == 3_000)
        #expect(!index.references[1].startsWithSAP)
        #expect(index.references[1].sapDeltaTime == 10)
    }

    @Test
    func rejectsWrongBoxType() throws {
        var data = try fixtureData()
        data.replaceSubrange(4..<8, with: Data("free".utf8))

        #expect(throws: SIDXParserError.invalidBoxType(0x6672_6565)) {
            try SIDXParser().parse(data)
        }
    }

    @Test
    func rejectsTruncatedBox() throws {
        let data = try fixtureData().dropLast()

        #expect(throws: SIDXParserError.invalidBoxSize(declared: 56, actual: 55)) {
            try SIDXParser().parse(Data(data))
        }
    }

    @Test
    func rejectsIndirectSIDXReference() throws {
        var data = try fixtureData()
        data[32] |= 0x80

        #expect(throws: SIDXParserError.unsupportedIndirectReference(index: 0)) {
            try SIDXParser().parse(data)
        }
    }

    @Test
    func loadsIndexThroughRangeValidationAndKeepsSuccessfulCDN() async throws {
        let data = try fixtureData()
        let primaryURL = try #require(URL(string: "https://primary.fixture.bilivideo.com/media"))
        let backupURL = try #require(URL(string: "https://backup.fixture.bilivideo.com/media"))
        let transport = FixtureRangeTransport(
            media: [backupURL: mediaPlacing(data, at: 100)],
            failingURLs: [primaryURL]
        )
        let representation = MediaRepresentation(
            id: 80,
            kind: .video,
            codecs: "avc1.640032",
            mimeType: "video/mp4",
            primaryURL: primaryURL,
            backupURLs: [backupURL],
            segmentBase: SegmentBase(
                initialization: try MediaByteRange(start: 0, endInclusive: 99),
                index: try MediaByteRange(start: 100, endInclusive: 155)
            )
        )

        let loaded = try await RepresentationIndexLoader(
            rangeClient: HTTPRangeClient(streamer: transport)
        ).load(for: representation)

        #expect(loaded.sourceURL == backupURL)
        #expect(loaded.index.references[0].byteRange.start == 156)
        #expect(await transport.requests.map(\.url) == [primaryURL, backupURL])
        #expect(await transport.requests[1].headers["Range"] == "bytes=100-155")
    }

    @Test
    func rejectsOversizedIndexRangeBeforeAnyRequest() async throws {
        let url = try #require(URL(string: "https://primary.fixture.bilivideo.com/media"))
        let transport = FixtureRangeTransport(
            media: [url: Data(count: SIDXParser.maximumBoxByteCount + 200)]
        )
        let indexLength = SIDXParser.maximumBoxByteCount + 1
        let representation = MediaRepresentation(
            id: 80,
            kind: .video,
            codecs: "avc1.640032",
            mimeType: "video/mp4",
            primaryURL: url,
            segmentBase: SegmentBase(
                initialization: try MediaByteRange(start: 0, endInclusive: 99),
                index: try MediaByteRange(
                    start: 100,
                    endInclusive: Int64(100 + indexLength - 1)
                )
            )
        )

        await #expect(
            throws: SIDXParserError.indexTooLarge(byteCount: UInt64(indexLength))
        ) {
            try await RepresentationIndexLoader(
                rangeClient: HTTPRangeClient(streamer: transport)
            ).load(for: representation)
        }
        #expect(await transport.requests.isEmpty)
    }

    @Test
    func rejectsErrorPageBodyAndParsesBackupSIDX() async throws {
        let data = try fixtureData()
        let primaryURL = try #require(URL(string: "https://primary.fixture.bilivideo.com/media"))
        let backupURL = try #require(URL(string: "https://backup.fixture.bilivideo.com/media"))
        var errorPage = Data("<html>blocked</html>".utf8)
        errorPage.append(Data(repeating: 0x20, count: data.count - errorPage.count))
        let transport = FixtureRangeTransport(
            media: [
                primaryURL: mediaPlacing(errorPage, at: 100),
                backupURL: mediaPlacing(data, at: 100)
            ]
        )
        let representation = MediaRepresentation(
            id: 80,
            kind: .video,
            codecs: "avc1.640032",
            mimeType: "video/mp4",
            primaryURL: primaryURL,
            backupURLs: [backupURL],
            segmentBase: SegmentBase(
                initialization: try MediaByteRange(start: 0, endInclusive: 99),
                index: try MediaByteRange(start: 100, endInclusive: 155)
            )
        )

        let loaded = try await RepresentationIndexLoader(
            rangeClient: HTTPRangeClient(streamer: transport)
        ).load(for: representation)

        #expect(loaded.sourceURL == backupURL)
        #expect(loaded.index.references.count == 2)
        #expect(await transport.requests.map(\.url) == [primaryURL, backupURL])
    }

    @Test(arguments: ["video-avc", "audio-aac"])
    func parsesVersionOneSIDXFromSyntheticFragmentedMP4(
        fixtureName: String
    ) throws {
        let url = try #require(
            Bundle.module.url(
                forResource: fixtureName,
                withExtension: "mp4",
                subdirectory: "Fixtures"
            )
        )
        let media = try Data(contentsOf: url)
        let box = try #require(firstTopLevelBox(named: "sidx", in: media))
        let boxData = media.subdata(in: box.offset..<(box.offset + box.size))

        let index = try SIDXParser().parse(
            boxData,
            boxStartOffset: UInt64(box.offset)
        )

        #expect(index.timescale > 0)
        #expect(!index.references.isEmpty)
        #expect(
            index.references[0].byteRange.start
                == Int64(box.offset + box.size) + Int64(index.firstOffset)
        )
        #expect(index.references[0].byteRange.endInclusive < Int64(media.count))
    }

    @Test(arguments: [
        (startsWithSAP: true, sapType: UInt8(1), sapDeltaTime: UInt32(0), expected: true),
        (startsWithSAP: false, sapType: UInt8(1), sapDeltaTime: UInt32(0), expected: false),
        (startsWithSAP: true, sapType: UInt8(2), sapDeltaTime: UInt32(0), expected: false),
        (startsWithSAP: true, sapType: UInt8(1), sapDeltaTime: UInt32(1), expected: false)
    ])
    func requiresEveryReferenceToStartWithType1SAPAtZeroDelta(
        startsWithSAP: Bool,
        sapType: UInt8,
        sapDeltaTime: UInt32,
        expected: Bool
    ) throws {
        let independent = SegmentReference(
            byteRange: try MediaByteRange(start: 0, endInclusive: 99),
            duration: 1,
            startsWithSAP: true,
            sapType: 1,
            sapDeltaTime: 0
        )
        let candidate = SegmentReference(
            byteRange: try MediaByteRange(start: 100, endInclusive: 199),
            duration: 1,
            startsWithSAP: startsWithSAP,
            sapType: sapType,
            sapDeltaTime: sapDeltaTime
        )

        let index = segmentIndex(references: [independent, candidate])
        let video = MediaRepresentation(
            id: 80,
            kind: .video,
            codecs: "avc1.4d400c",
            mimeType: "video/mp4",
            bandwidth: nil,
            videoAttributes: try VideoRepresentationAttributes(
                width: 256,
                height: 144,
                frameRate: 24
            ),
            primaryURL: try #require(URL(string: "https://media.fixture.bilivideo.com/80")),
            segmentBase: SegmentBase(
                initialization: try MediaByteRange(start: 0, endInclusive: 0),
                index: try MediaByteRange(start: 1, endInclusive: 1)
            )
        )
        let uri = try #require(URL(string: "http://127.0.0.1:1/session/video/80.m3u8"))
        let mediaPlaylist = try HLSMediaPlaylistBuilder().build(
            representation: video,
            index: index,
            mediaURI: uri
        )
        let masterPlaylist = try HLSMasterPlaylistBuilder().build(
            videoVariants: [HLSVideoVariant(representation: video, index: index, playlistURI: uri)],
            audioGroups: []
        )

        #expect(index.hasIndependentSegments == expected)
        // media 与 master playlist 声明 `EXT-X-INDEPENDENT-SEGMENTS` 的条件必须相同：开放 GOP 不能被声明为独立。
        #expect(mediaPlaylist.contains("#EXT-X-INDEPENDENT-SEGMENTS") == expected)
        #expect(masterPlaylist.contains("#EXT-X-INDEPENDENT-SEGMENTS") == expected)
    }

    @Test
    func emptyIndexHasNoIndependentSegments() {
        #expect(!segmentIndex(references: []).hasIndependentSegments)
    }

    private func segmentIndex(references: [SegmentReference]) -> SegmentIndex {
        SegmentIndex(
            referenceID: 1,
            timescale: 1,
            earliestPresentationTime: 0,
            firstOffset: 0,
            references: references
        )
    }

    private func fixtureData() throws -> Data {
        let url = try #require(
            Bundle.module.url(
                forResource: "sidx-v0-two-references",
                withExtension: "hex",
                subdirectory: "Fixtures"
            )
        )
        let text = try String(contentsOf: url, encoding: .utf8)
        let hexadecimal = text.filter { $0.isHexDigit }
        guard hexadecimal.count.isMultiple(of: 2) else {
            throw FixtureError.invalidHexadecimal
        }

        var data = Data()
        data.reserveCapacity(hexadecimal.count / 2)
        var index = hexadecimal.startIndex
        while index < hexadecimal.endIndex {
            let next = hexadecimal.index(index, offsetBy: 2)
            guard let byte = UInt8(hexadecimal[index..<next], radix: 16) else {
                throw FixtureError.invalidHexadecimal
            }
            data.append(byte)
            index = next
        }
        return data
    }

    /// 把 SIDX 放在 924 字节远端媒体的指定偏移处。
    private func mediaPlacing(_ box: Data, at offset: Int) -> Data {
        var media = Data(count: 924)
        media.replaceSubrange(offset..<(offset + box.count), with: box)
        return media
    }
}

private enum FixtureError: Error {
    case invalidHexadecimal
}
