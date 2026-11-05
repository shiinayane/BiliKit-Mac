import Foundation

/// 从音频 init 读出的 HLS `CHANNELS`、`BIT-DEPTH`、`SAMPLE-RATE` 属性值。
struct AudioFormatMetadata: Sendable, Equatable {
    let channelCount: Int
    let bitDepth: Int
    let sampleRate: Int
}

/// 音频 init 无法解析或取值不合理；调用方不输出相应属性，播放照常。
enum AudioFormatMetadataParserError: Error, Sendable, Equatable {
    case initializationTooLarge
    case malformedBoxStructure
    case missingAudioSampleEntry
    case unsupportedSampleEntryVersion(UInt16)
    case invalidFormatValues
}

/// 从有界 fMP4 initialization 的 `mp4a` sample entry 读取 HLS 音频格式属性。
///
/// box 遍历交给 `ISOBoxReader`，这里只解释 sample entry；结构错误统一报 `malformedBoxStructure`。
struct AudioFormatMetadataParser: Sendable {
    func parse(_ data: Data) throws -> AudioFormatMetadata {
        guard data.count <= InitializationSegmentLoader.maximumByteCount else {
            throw AudioFormatMetadataParserError.initializationTooLarge
        }
        do {
            return try metadata(in: ISOBoxReader(data: data))
        } catch is ISOBoxStructureError {
            throw AudioFormatMetadataParserError.malformedBoxStructure
        }
    }

    private func metadata(in reader: ISOBoxReader) throws -> AudioFormatMetadata {
        let topLevel = try reader.boxes(in: reader.data.indices)
        guard let movie = topLevel.first(where: { $0.type == "moov" }) else {
            throw AudioFormatMetadataParserError.missingAudioSampleEntry
        }
        for track in try reader.boxes(in: movie.payload)
        where track.type == "trak" {
            if let metadata = try audioMetadata(in: track, reader: reader) {
                return metadata
            }
        }
        throw AudioFormatMetadataParserError.missingAudioSampleEntry
    }

    private func audioMetadata(
        in track: ISOBox,
        reader: ISOBoxReader
    ) throws -> AudioFormatMetadata? {
        guard
            let media = try reader.child(named: "mdia", of: track),
            let mediaInformation = try reader.child(named: "minf", of: media),
            let sampleTable = try reader.child(named: "stbl", of: mediaInformation),
            let sampleDescription = try reader.child(named: "stsd", of: sampleTable)
        else {
            return nil
        }
        return try sampleEntryMetadata(sampleDescription, reader: reader)
    }

    private func sampleEntryMetadata(
        _ description: ISOBox,
        reader: ISOBoxReader
    ) throws -> AudioFormatMetadata? {
        guard description.payload.count >= 8 else {
            throw AudioFormatMetadataParserError.malformedBoxStructure
        }
        let entryCount = try reader.unsigned32(
            at: description.payload.lowerBound + 4
        )
        guard (1...64).contains(entryCount) else {
            throw AudioFormatMetadataParserError.malformedBoxStructure
        }
        let entries = try reader.boxes(
            in: (description.payload.lowerBound + 8)..<description.payload.upperBound
        )
        guard entries.count == Int(entryCount) else {
            throw AudioFormatMetadataParserError.malformedBoxStructure
        }
        guard let audio = entries.first(where: { $0.type == "mp4a" }) else {
            return nil
        }
        return try parseMP4AudioSampleEntry(audio, reader: reader)
    }

    private func parseMP4AudioSampleEntry(
        _ audio: ISOBox,
        reader: ISOBoxReader
    ) throws -> AudioFormatMetadata {
        guard audio.payload.count >= 28 else {
            throw AudioFormatMetadataParserError.malformedBoxStructure
        }
        let base = audio.payload.lowerBound
        let version = try reader.unsigned16(at: base + 8)
        guard version == 0 || version == 1 else {
            throw AudioFormatMetadataParserError.unsupportedSampleEntryVersion(
                version
            )
        }
        let channelCount = Int(try reader.unsigned16(at: base + 16))
        let bitDepth = Int(try reader.unsigned16(at: base + 18))
        let fixedSampleRate = try reader.unsigned32(at: base + 24)
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
}
