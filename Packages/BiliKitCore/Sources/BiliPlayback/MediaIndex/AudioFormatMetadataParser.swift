import BiliModels
import BiliNetworking
import Foundation

struct AudioFormatMetadata: Sendable, Equatable {
    let channelCount: Int
    let bitDepth: Int
    let sampleRate: Int
}

enum AudioFormatMetadataParserError: Error, Sendable, Equatable {
    case initializationTooLarge
    case malformedBoxStructure
    case missingAudioSampleEntry
    case unsupportedSampleEntryVersion(UInt16)
    case invalidFormatValues
}

/// 从有界 fMP4 initialization 的 `mp4a` sample entry 读取 HLS 音频格式属性。
struct AudioFormatMetadataParser: Sendable {
    static let maximumInitializationByteCount = 2 * 1_024 * 1_024

    func parse(_ data: Data) throws -> AudioFormatMetadata {
        guard data.count <= Self.maximumInitializationByteCount else {
            throw AudioFormatMetadataParserError.initializationTooLarge
        }
        let topLevel = try boxTable(in: data.indices, data: data)
        guard let movie = topLevel.first(where: { $0.type == "moov" }) else {
            throw AudioFormatMetadataParserError.missingAudioSampleEntry
        }
        for track in try boxTable(in: movie.payload, data: data)
        where track.type == "trak" {
            if let metadata = try audioMetadata(in: track, data: data) {
                return metadata
            }
        }
        throw AudioFormatMetadataParserError.missingAudioSampleEntry
    }

    private func audioMetadata(
        in track: ISOBox,
        data: Data
    ) throws -> AudioFormatMetadata? {
        guard
            let media = try child(named: "mdia", of: track, data: data),
            let mediaInformation = try child(
                named: "minf",
                of: media,
                data: data
            ),
            let sampleTable = try child(
                named: "stbl",
                of: mediaInformation,
                data: data
            ),
            let sampleDescription = try child(
                named: "stsd",
                of: sampleTable,
                data: data
            )
        else {
            return nil
        }
        return try sampleEntryMetadata(sampleDescription, data: data)
    }

    private func sampleEntryMetadata(
        _ description: ISOBox,
        data: Data
    ) throws -> AudioFormatMetadata? {
        guard description.payload.count >= 8 else {
            throw AudioFormatMetadataParserError.malformedBoxStructure
        }
        let entryCount = try unsigned32(
            at: description.payload.lowerBound + 4,
            data: data
        )
        guard (1...64).contains(entryCount) else {
            throw AudioFormatMetadataParserError.malformedBoxStructure
        }
        let entries = try boxTable(
            in: (description.payload.lowerBound + 8)..<description.payload.upperBound,
            data: data
        )
        guard entries.count == Int(entryCount) else {
            throw AudioFormatMetadataParserError.malformedBoxStructure
        }
        guard let audio = entries.first(where: { $0.type == "mp4a" }) else {
            return nil
        }
        return try parseMP4AudioSampleEntry(audio, data: data)
    }

    private func parseMP4AudioSampleEntry(
        _ audio: ISOBox,
        data: Data
    ) throws -> AudioFormatMetadata {
        guard audio.payload.count >= 28 else {
            throw AudioFormatMetadataParserError.malformedBoxStructure
        }
        let base = audio.payload.lowerBound
        let version = try unsigned16(at: base + 8, data: data)
        guard version == 0 || version == 1 else {
            throw AudioFormatMetadataParserError.unsupportedSampleEntryVersion(
                version
            )
        }
        let channelCount = Int(try unsigned16(at: base + 16, data: data))
        let bitDepth = Int(try unsigned16(at: base + 18, data: data))
        let fixedSampleRate = try unsigned32(at: base + 24, data: data)
        guard fixedSampleRate & 0xffff == 0 else {
            throw AudioFormatMetadataParserError.invalidFormatValues
        }
        let sampleRate = Int(fixedSampleRate >> 16)
        guard (1...128).contains(channelCount),
            (1...64).contains(bitDepth),
            (1...768_000).contains(sampleRate)
        else {
            throw AudioFormatMetadataParserError.invalidFormatValues
        }
        return AudioFormatMetadata(
            channelCount: channelCount,
            bitDepth: bitDepth,
            sampleRate: sampleRate
        )
    }

    private func child(
        named name: String,
        of parent: ISOBox,
        data: Data
    ) throws -> ISOBox? {
        try boxTable(in: parent.payload, data: data).first {
            $0.type == name
        }
    }

    private func boxTable(
        in range: Range<Int>,
        data: Data
    ) throws -> [ISOBox] {
        guard range.lowerBound >= data.startIndex,
            range.upperBound <= data.endIndex
        else {
            throw AudioFormatMetadataParserError.malformedBoxStructure
        }
        var boxes: [ISOBox] = []
        var offset = range.lowerBound
        while offset < range.upperBound {
            guard range.upperBound - offset >= 8 else {
                throw AudioFormatMetadataParserError.malformedBoxStructure
            }
            let compactSize = try unsigned32(at: offset, data: data)
            let type = try boxType(at: offset + 4, data: data)
            let headerSize: Int
            let boxSize: Int
            switch compactSize {
            case 0:
                headerSize = 8
                boxSize = range.upperBound - offset
            case 1:
                let extendedSize = try unsigned64(at: offset + 8, data: data)
                guard extendedSize <= UInt64(Int.max) else {
                    throw AudioFormatMetadataParserError.malformedBoxStructure
                }
                headerSize = 16
                boxSize = Int(extendedSize)
            default:
                headerSize = 8
                boxSize = Int(compactSize)
            }
            guard boxSize >= headerSize,
                boxSize <= range.upperBound - offset
            else {
                throw AudioFormatMetadataParserError.malformedBoxStructure
            }
            let end = offset + boxSize
            boxes.append(
                ISOBox(
                    type: type,
                    payload: (offset + headerSize)..<end
                )
            )
            offset = end
        }
        return boxes
    }

    private func boxType(at offset: Int, data: Data) throws -> String {
        guard offset >= data.startIndex, offset + 4 <= data.endIndex else {
            throw AudioFormatMetadataParserError.malformedBoxStructure
        }
        guard
            let value = String(
                bytes: data[offset..<(offset + 4)],
                encoding: .isoLatin1
            )
        else {
            throw AudioFormatMetadataParserError.malformedBoxStructure
        }
        return value
    }

    private func unsigned16(at offset: Int, data: Data) throws -> UInt16 {
        guard offset >= data.startIndex, offset + 2 <= data.endIndex else {
            throw AudioFormatMetadataParserError.malformedBoxStructure
        }
        return data[offset..<(offset + 2)].reduce(0) {
            ($0 << 8) | UInt16($1)
        }
    }

    private func unsigned32(at offset: Int, data: Data) throws -> UInt32 {
        guard offset >= data.startIndex, offset + 4 <= data.endIndex else {
            throw AudioFormatMetadataParserError.malformedBoxStructure
        }
        return data[offset..<(offset + 4)].reduce(0) {
            ($0 << 8) | UInt32($1)
        }
    }

    private func unsigned64(at offset: Int, data: Data) throws -> UInt64 {
        guard offset >= data.startIndex, offset + 8 <= data.endIndex else {
            throw AudioFormatMetadataParserError.malformedBoxStructure
        }
        return data[offset..<(offset + 8)].reduce(0) {
            ($0 << 8) | UInt64($1)
        }
    }
}

private struct ISOBox {
    let type: String
    let payload: Range<Int>
}

/// 音频格式元数据是可选增强；调用方必须在解析失败时退化为不输出相应 HLS 属性。
struct AudioFormatMetadataLoader: Sendable {
    private let rangeClient: HTTPRangeClient
    private let parser: AudioFormatMetadataParser

    init(
        rangeClient: HTTPRangeClient,
        parser: AudioFormatMetadataParser = AudioFormatMetadataParser()
    ) {
        self.rangeClient = rangeClient
        self.parser = parser
    }

    func load(
        for representation: MediaRepresentation,
        sourceURL: URL,
        headers: [String: String]
    ) async throws -> AudioFormatMetadata {
        let initialization = representation.segmentBase.initialization
        let range = try HTTPByteRange(
            start: initialization.start,
            endInclusive: initialization.endInclusive
        )
        guard
            range.length
                <= UInt64(
                    AudioFormatMetadataParser.maximumInitializationByteCount
                )
        else {
            throw AudioFormatMetadataParserError.initializationTooLarge
        }
        let response = try await rangeClient.fetch(
            from: [sourceURL],
            range: range,
            headers: headers,
            validateBody: { data in
                (try? parser.parse(data)) != nil
            }
        )
        return try parser.parse(response.body)
    }
}
