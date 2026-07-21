import Foundation
import Testing
@testable import BiliModels
@testable import BiliNetworking
@testable import BiliPlayback

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
        let primaryURL = try #require(URL(string: "https://primary.example/media"))
        let backupURL = try #require(URL(string: "https://backup.example/media"))
        let transport = IndexStubTransport(
            responses: [
                HTTPResponse(statusCode: 403, body: Data()),
                HTTPResponse(
                    statusCode: 206,
                    headers: ["Content-Range": "bytes 100-155/924"],
                    body: data
                ),
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
            rangeClient: HTTPRangeClient(transport: transport)
        ).load(for: representation)

        #expect(loaded.sourceURL == backupURL)
        #expect(loaded.index.references[0].byteRange.start == 156)
        #expect(await transport.requests.map(\.url) == [primaryURL, backupURL])
        #expect(await transport.requests[1].headers["Range"] == "bytes=100-155")
    }

    @Test
    func rejectsErrorPageBodyAndParsesBackupSIDX() async throws {
        let data = try fixtureData()
        let primaryURL = try #require(URL(string: "https://primary.example/media"))
        let backupURL = try #require(URL(string: "https://backup.example/media"))
        var errorPage = Data("<html>blocked</html>".utf8)
        errorPage.append(Data(repeating: 0x20, count: data.count - errorPage.count))
        let transport = IndexStubTransport(
            responses: [
                HTTPResponse(
                    statusCode: 206,
                    headers: ["Content-Range": "bytes 100-155/924"],
                    body: errorPage
                ),
                HTTPResponse(
                    statusCode: 206,
                    headers: ["Content-Range": "bytes 100-155/924"],
                    body: data
                ),
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
            rangeClient: HTTPRangeClient(transport: transport)
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

    private func firstTopLevelBox(
        named expectedType: String,
        in data: Data
    ) -> (offset: Int, size: Int)? {
        var offset = 0
        while offset + 8 <= data.count {
            let size = Int(readUInt32(in: data, at: offset))
            let typeData = data.subdata(in: (offset + 4)..<(offset + 8))
            let type = String(data: typeData, encoding: .ascii)
            guard size >= 8, offset + size <= data.count else {
                return nil
            }
            if type == expectedType {
                return (offset, size)
            }
            offset += size
        }
        return nil
    }

    private func readUInt32(in data: Data, at offset: Int) -> UInt32 {
        data[offset..<(offset + 4)].reduce(UInt32(0)) { value, byte in
            (value << 8) | UInt32(byte)
        }
    }
}

private enum FixtureError: Error {
    case invalidHexadecimal
}

private actor IndexStubTransport: HTTPTransport {
    private var responses: [HTTPResponse]
    private(set) var requests: [HTTPRequest] = []

    init(responses: [HTTPResponse]) {
        self.responses = responses
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        requests.append(request)
        return responses.removeFirst()
    }
}
