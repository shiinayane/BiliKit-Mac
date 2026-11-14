import Foundation

/// 从 HDR 视频 init 读出、要写进 master 的动态范围属性。
struct VideoDynamicRangeMetadata: Sendable, Equatable {
    let range: HLSVideoRange
    /// 杜比视界 profile 8 的 `SUPPLEMENTAL-CODECS`（如 `dvh1.08.06/db4h`）；HDR 真彩与 profile 5 为 nil。
    let supplementalCodecs: String?
    /// 这一档的 `CODECS` 必须等于的值（profile 5 的 `dvh1.05.06` 等）；nil 表示沿用 playurl 给的编码。
    ///
    /// profile 5 没有可回退的基础层，Authoring Spec 要求 `CODECS` 写 `dvh1.05.LL`，AVPlayer 据此判断设备
    /// 能否播放这一档；master 照抄 playurl 的编码，所以由调用方比对，不一致时丢弃这一档。
    let requiredCodecs: String?

    init(range: HLSVideoRange, supplementalCodecs: String? = nil, requiredCodecs: String? = nil) {
        self.range = range
        self.supplementalCodecs = supplementalCodecs
        self.requiredCodecs = requiredCodecs
    }
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
/// 只接受三种形状：`colr`（nclx）的传递函数是 PQ（16）或 HLG（18）的 HDR 真彩；杜比视界
/// profile 8 且基础层兼容 HLG（compatibility 4）或 PQ（compatibility 1），写成对应的 `VIDEO-RANGE`
/// 加 `SUPPLEMENTAL-CODECS`，让不支持杜比视界的设备按基础层播放；杜比视界 profile 5（`dvh1`
/// sample entry、compatibility 0），按 Apple HLS Authoring Spec 写成 `CODECS="dvh1.05.LL"` 与
/// `VIDEO-RANGE=PQ`、不写 `SUPPLEMENTAL-CODECS`。profile 5 没有基础层，只能由杜比视界解码；`dvhe`
/// 与其余配置拒绝。box 遍历交给 `ISOBoxReader`。
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
            return try dolbyVision(configuration, sampleEntryType: entry.type, reader: reader)
        }
        guard let color = children.first(where: { $0.type == "colr" }) else {
            throw VideoDynamicRangeParserError.missingColorInformation
        }
        return VideoDynamicRangeMetadata(range: try transferRange(color, reader: reader))
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
        sampleEntryType: String,
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
        let unsupported = VideoDynamicRangeParserError.unsupportedDolbyVisionConfiguration(
            profile: profile,
            compatibilityID: compatibilityID
        )
        guard (1...13).contains(level) else { throw unsupported }
        let codec = String(format: "dvh1.%02d.%02d", profile, level)
        switch (profile, compatibilityID) {
        case (8, 4):
            return VideoDynamicRangeMetadata(range: .hlg, supplementalCodecs: codec + "/db4h")
        case (8, 1):
            return VideoDynamicRangeMetadata(range: .pq, supplementalCodecs: codec + "/db1p")
        case (5, 0) where sampleEntryType == "dvh1":
            // `dvh1` 的参数集在 sample description 里，与 `CODECS` 的 `dvh1` 对应；`dvhe` 的参数集在码流内，
            // 要写 `dvhe.05.LL`，Authoring Spec 不推荐，B 站也没有样本，所以拒绝。
            return VideoDynamicRangeMetadata(range: .pq, requiredCodecs: codec)
        default:
            throw unsupported
        }
    }
}
