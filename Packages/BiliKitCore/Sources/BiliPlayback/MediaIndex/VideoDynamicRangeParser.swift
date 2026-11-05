import Foundation

/// 从 HDR 视频 init 读出、要写进 master 的动态范围属性。
struct VideoDynamicRangeMetadata: Sendable, Equatable {
    let range: HLSVideoRange
    /// 杜比视界档的 `SUPPLEMENTAL-CODECS`（如 `dvh1.08.06/db4h`）；HDR 真彩为 nil。
    let supplementalCodecs: String?
}

/// 视频 init 无法解析、不是 HDR，或是不支持的杜比视界配置；调用方丢弃这一档。
enum VideoDynamicRangeParserError: Error, Sendable, Equatable {
    case initializationTooLarge
    case malformedBoxStructure
    case missingVideoSampleEntry
    case missingColorInformation
    case notHighDynamicRange
    case unsupportedDolbyVisionConfiguration(profile: Int, compatibilityID: Int)
}

/// 从有界 fMP4 initialization 的 HEVC 或杜比视界 sample entry 读出动态范围。
///
/// 只接受两种形状：`colr`（nclx）的传递函数是 PQ（16）或 HLG（18）的 HDR 真彩；杜比视界
/// profile 8 且基础层兼容 HLG（compatibility 4）或 PQ（compatibility 1），写成对应的 `VIDEO-RANGE`
/// 加 `SUPPLEMENTAL-CODECS`，让不支持杜比视界的设备按基础层播放。profile 5 没有可兼容的基础层，
/// 其余配置也拒绝。box 遍历交给 `ISOBoxReader`。
struct VideoDynamicRangeParser: Sendable {
    /// HEVC 与杜比视界 HEVC 的 sample entry 类型。
    private static let sampleEntryTypes: Set<String> = ["hvc1", "hev1", "dvh1", "dvhe"]
    /// VisualSampleEntry 固定字段的长度（ISO/IEC 14496-12 §12.1.3），子 box 从这之后开始。
    private static let visualSampleEntryHeaderByteCount = 78

    func parse(_ data: Data) throws -> VideoDynamicRangeMetadata {
        guard data.count <= InitializationSegmentLoader.maximumByteCount else {
            throw VideoDynamicRangeParserError.initializationTooLarge
        }
        do {
            return try metadata(in: ISOBoxReader(data: data))
        } catch is ISOBoxStructureError {
            throw VideoDynamicRangeParserError.malformedBoxStructure
        }
    }

    private func metadata(in reader: ISOBoxReader) throws -> VideoDynamicRangeMetadata {
        let entry = try videoSampleEntry(in: reader)
        let start = entry.payload.lowerBound + Self.visualSampleEntryHeaderByteCount
        guard start <= entry.payload.upperBound else {
            throw VideoDynamicRangeParserError.malformedBoxStructure
        }
        let children = try reader.boxes(in: start..<entry.payload.upperBound)
        if let configuration = children.first(where: { $0.type == "dvvC" || $0.type == "dvcC" }) {
            return try dolbyVision(configuration, reader: reader)
        }
        guard let color = children.first(where: { $0.type == "colr" }) else {
            throw VideoDynamicRangeParserError.missingColorInformation
        }
        return VideoDynamicRangeMetadata(
            range: try transferRange(color, reader: reader),
            supplementalCodecs: nil
        )
    }

    private func videoSampleEntry(in reader: ISOBoxReader) throws -> ISOBox {
        let topLevel = try reader.boxes(in: reader.data.indices)
        guard let movie = topLevel.first(where: { $0.type == "moov" }) else {
            throw VideoDynamicRangeParserError.missingVideoSampleEntry
        }
        for track in try reader.boxes(in: movie.payload) where track.type == "trak" {
            guard
                let media = try reader.child(named: "mdia", of: track),
                let information = try reader.child(named: "minf", of: media),
                let table = try reader.child(named: "stbl", of: information),
                let description = try reader.child(named: "stsd", of: table),
                description.payload.count >= 8
            else { continue }
            let entries = try reader.boxes(
                in: (description.payload.lowerBound + 8)..<description.payload.upperBound
            )
            if let entry = entries.first(where: { Self.sampleEntryTypes.contains($0.type) }) {
                return entry
            }
        }
        throw VideoDynamicRangeParserError.missingVideoSampleEntry
    }

    /// `colr` 的 nclx 形式：4 字节类型后依次是 primaries、transfer、matrix 各 16 位。
    private func transferRange(_ color: ISOBox, reader: ISOBoxReader) throws -> HLSVideoRange {
        guard color.payload.count >= 10,
            try reader.unsigned32(at: color.payload.lowerBound) == 0x6E63_6C78  // "nclx"
        else {
            throw VideoDynamicRangeParserError.missingColorInformation
        }
        switch try reader.unsigned16(at: color.payload.lowerBound + 6) {
        case 16: return .pq
        case 18: return .hlg
        default: throw VideoDynamicRangeParserError.notHighDynamicRange
        }
    }

    /// `dvcC`／`dvvC`：版本两字节后，16 位里依次是 profile（7 位）、level（6 位）与三个标志位，
    /// 再往后 4 位是基础层兼容 ID。
    private func dolbyVision(
        _ configuration: ISOBox,
        reader: ISOBoxReader
    ) throws -> VideoDynamicRangeMetadata {
        guard configuration.payload.count >= 5 else {
            throw VideoDynamicRangeParserError.malformedBoxStructure
        }
        let base = configuration.payload.lowerBound
        let bits = try reader.unsigned16(at: base + 2)
        let profile = Int(bits >> 9)
        let level = Int((bits >> 3) & 0x3F)
        let compatibilityID = Int(try reader.unsigned8(at: base + 4) >> 4)
        let range: HLSVideoRange
        let brand: String
        switch (profile, compatibilityID) {
        case (8, 4):
            range = .hlg
            brand = "db4h"
        case (8, 1):
            range = .pq
            brand = "db1p"
        default:
            throw VideoDynamicRangeParserError.unsupportedDolbyVisionConfiguration(
                profile: profile,
                compatibilityID: compatibilityID
            )
        }
        guard (1...13).contains(level) else {
            throw VideoDynamicRangeParserError.unsupportedDolbyVisionConfiguration(
                profile: profile,
                compatibilityID: compatibilityID
            )
        }
        return VideoDynamicRangeMetadata(
            range: range,
            supplementalCodecs: String(format: "dvh1.%02d.%02d/", profile, level) + brand
        )
    }
}
