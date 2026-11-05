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

/// 从有界 fMP4 initialization 的音频 sample entry（`mp4a`、`ec-3`、`fLaC`）读取 HLS 音频格式属性。
///
/// box 遍历交给 `ISOBoxReader`，这里只解释 sample entry；结构错误统一报 `malformedBoxStructure`。
/// `mp4a` 直接用 AudioSampleEntry 的字段。`ec-3` 的 AudioSampleEntry 声道数是占位值，声道从 `dec3` 读；
/// `fLaC` 的采样率可超过 AudioSampleEntry 16.16 字段能表示的 65535，三项都从 `dfLa` 的 STREAMINFO 读。
struct AudioFormatMetadataParser: Sendable {
    /// AudioSampleEntry 固定字段的长度（ISO/IEC 14496-12 §12.2.3，version 0），子 box 从这之后开始。
    private static let audioSampleEntryHeaderByteCount = 28
    /// E-AC-3 `acmod`（ETSI TS 102 366 表 4.3）对应的全频声道数，下标是 acmod。
    private static let eac3FullBandwidthChannels = [2, 1, 2, 3, 3, 4, 4, 5]

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
        for entry in entries {
            switch entry.type {
            case "mp4a": return try parseMP4AudioSampleEntry(entry, reader: reader)
            case "ec-3": return try parseEAC3SampleEntry(entry, reader: reader)
            case "fLaC": return try parseFLACSampleEntry(entry, reader: reader)
            default: continue
            }
        }
        return nil
    }

    private func parseMP4AudioSampleEntry(
        _ audio: ISOBox,
        reader: ISOBoxReader
    ) throws -> AudioFormatMetadata {
        guard audio.payload.count >= Self.audioSampleEntryHeaderByteCount else {
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

    /// 从 `dec3` 读 E-AC-3 的声道数。
    ///
    /// `dec3` 前 16 位是 data_rate（13 位）与独立子流数减一（3 位），随后是第一个独立子流的 fscod、
    /// bsid、asvc、bsmod、acmod、lfeon 与依赖子流数。只接受一个独立子流且没有依赖子流的布局（B 站的
    /// 5.1）；7.1 等需要依赖子流声道位置的布局拒绝，调用方丢掉这一组而不是写错 `CHANNELS`。
    private func parseEAC3SampleEntry(
        _ audio: ISOBox,
        reader: ISOBoxReader
    ) throws -> AudioFormatMetadata {
        let entry = try parseMP4AudioSampleEntry(audio, reader: reader)
        guard
            let configuration = try childBoxes(of: audio, reader: reader)
                .first(where: { $0.type == "dec3" }),
            configuration.payload.count >= 5
        else {
            throw AudioFormatMetadataParserError.invalidFormatValues
        }
        let base = configuration.payload.lowerBound
        let independentSubstreamCount = Int(try reader.unsigned8(at: base + 1) & 0x07) + 1
        let streamByte = try reader.unsigned8(at: base + 3)
        let audioCodingMode = Int((streamByte >> 1) & 0x07)
        let hasLowFrequencyEffects = streamByte & 0x01 == 1
        let dependentSubstreamCount = Int((try reader.unsigned8(at: base + 4) >> 1) & 0x0F)
        guard independentSubstreamCount == 1, dependentSubstreamCount == 0 else {
            throw AudioFormatMetadataParserError.invalidFormatValues
        }
        return AudioFormatMetadata(
            channelCount: Self.eac3FullBandwidthChannels[audioCodingMode]
                + (hasLowFrequencyEffects ? 1 : 0),
            bitDepth: entry.bitDepth,
            sampleRate: entry.sampleRate
        )
    }

    /// 从 `dfLa` 读 FLAC 的采样率、声道与位深。
    ///
    /// FullBox 头 4 字节后是 FLAC 元数据块，第一个必须是 34 字节的 STREAMINFO；其中第 10 字节起
    /// 依次是采样率（20 位）、声道数减一（3 位）、位深减一（5 位）。
    private func parseFLACSampleEntry(
        _ audio: ISOBox,
        reader: ISOBoxReader
    ) throws -> AudioFormatMetadata {
        guard
            let configuration = try childBoxes(of: audio, reader: reader)
                .first(where: { $0.type == "dfLa" }),
            configuration.payload.count >= 4 + 4 + 34
        else {
            throw AudioFormatMetadataParserError.invalidFormatValues
        }
        let blockHeader = configuration.payload.lowerBound + 4
        let streamInfoLength = try reader.unsigned32(at: blockHeader) & 0x00FF_FFFF
        guard try reader.unsigned8(at: blockHeader) & 0x7F == 0, streamInfoLength == 34 else {
            throw AudioFormatMetadataParserError.invalidFormatValues
        }
        let fields = blockHeader + 4 + 10
        let first = Int(try reader.unsigned8(at: fields))
        let second = Int(try reader.unsigned8(at: fields + 1))
        let third = Int(try reader.unsigned8(at: fields + 2))
        let fourth = Int(try reader.unsigned8(at: fields + 3))
        let sampleRate = (first << 12) | (second << 4) | (third >> 4)
        let channelCount = ((third >> 1) & 0x07) + 1
        let bitDepth = ((third & 0x01) << 4 | fourth >> 4) + 1
        guard (1...768_000).contains(sampleRate), (4...32).contains(bitDepth) else {
            throw AudioFormatMetadataParserError.invalidFormatValues
        }
        return AudioFormatMetadata(
            channelCount: channelCount,
            bitDepth: bitDepth,
            sampleRate: sampleRate
        )
    }

    /// version 0 AudioSampleEntry 固定字段之后的子 box；其他 version 的字段长度不同，拒绝。
    private func childBoxes(of audio: ISOBox, reader: ISOBoxReader) throws -> [ISOBox] {
        let start = audio.payload.lowerBound + Self.audioSampleEntryHeaderByteCount
        guard start <= audio.payload.upperBound,
            try reader.unsigned16(at: audio.payload.lowerBound + 8) == 0
        else {
            throw AudioFormatMetadataParserError.malformedBoxStructure
        }
        return try reader.boxes(in: start..<audio.payload.upperBound)
    }
}
