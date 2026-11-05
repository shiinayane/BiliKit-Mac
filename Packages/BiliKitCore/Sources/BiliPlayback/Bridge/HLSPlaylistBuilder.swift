import BiliModels
import Foundation

/// playlist 生成失败：输入缺失或不一致、码率无法计算，或要嵌入 playlist 的文本与 URI 不安全。
public enum HLSPlaylistBuilderError: Error, Sendable, Equatable {
    case noMediaSegments
    case noVideoVariants
    case nonIndependentIFrameSegments
    case duplicateIFrameVariant(Int)
    case unknownIFrameVariant(Int)
    case duplicateAudioTrackID(String)
    case duplicateAudioRenditionName(String)
    case invalidDefaultAudioRenditionCount(Int)
    case invalidAudioTrackSelection(trackID: String, representationID: Int)
    case duplicateSubtitleRenditionName(String)
    case invalidRenditionSelection
    case invalidAudioFormatMetadata
    case invalidTimescale
    case invalidMediaKind(expected: MediaKind, actual: MediaKind)
    case missingVideoAttributes(representationID: Int)
    case invalidSegmentDuration
    case invalidCalculatedBitRate
    case bandwidthOverflow
    case invalidSubtitleDuration
    case unsafeAttributeValue
    case unsafeURI
}

/// 将一个 representation 的已验证 SIDX 引用编码为内存 VOD media playlist。
///
/// 输入必须具有非空分段与正 timescale；输出只引用调用方提供的安全 URI，不持有网络资源。
public struct HLSMediaPlaylistBuilder: Sendable {
    public init() {}

    public func build(
        representation: MediaRepresentation,
        index: SegmentIndex,
        mediaURI: URL
    ) throws -> String {
        guard !index.references.isEmpty else {
            throw HLSPlaylistBuilderError.noMediaSegments
        }
        guard index.timescale > 0 else {
            throw HLSPlaylistBuilderError.invalidTimescale
        }
        let uri = try safePlaylistURI(mediaURI)
        let maximumDuration =
            index.references
            .map { Double($0.duration) / Double(index.timescale) }
            .max() ?? 0
        let targetDuration = max(1, Int(ceil(maximumDuration)))
        let initialization = representation.segmentBase.initialization

        var lines = [
            "#EXTM3U",
            "#EXT-X-VERSION:7",
            "#EXT-X-TARGETDURATION:\(targetDuration)",
            "#EXT-X-MEDIA-SEQUENCE:0",
            "#EXT-X-PLAYLIST-TYPE:VOD"
        ]
        if index.references.allSatisfy(\.startsWithSAP) {
            lines.append("#EXT-X-INDEPENDENT-SEGMENTS")
        }
        lines.append(
            "#EXT-X-MAP:URI=\"\(uri)\",BYTERANGE=\"\(byteRangeValue(initialization))\""
        )

        for reference in index.references {
            let duration = Double(reference.duration) / Double(index.timescale)
            lines.append("#EXTINF:\(formattedPlaylistDuration(duration)),")
            lines.append("#EXT-X-BYTERANGE:\(byteRangeValue(reference.byteRange))")
            lines.append(uri)
        }
        lines.append("#EXT-X-ENDLIST")

        return lines.joined(separator: "\n") + "\n"
    }
}

/// 为每个从 type-1 SAP 开始的完整 fMP4 fragment 构造 VOD I-frame playlist。
///
/// RFC 8216 允许保留 I-frame sample 后的 `mdat` 数据，因此这里不预读或重写远端 fragment。
public struct HLSIFramePlaylistBuilder: Sendable {
    public init() {}

    public func build(
        representation: MediaRepresentation,
        index: SegmentIndex,
        mediaURI: URL
    ) throws -> String {
        guard representation.kind == .video else {
            throw HLSPlaylistBuilderError.invalidMediaKind(
                expected: .video,
                actual: representation.kind
            )
        }
        guard !index.references.isEmpty else {
            throw HLSPlaylistBuilderError.noMediaSegments
        }
        guard index.timescale > 0 else {
            throw HLSPlaylistBuilderError.invalidTimescale
        }
        guard index.allReferencesStartWithType1SAP else {
            throw HLSPlaylistBuilderError.nonIndependentIFrameSegments
        }

        let uri = try safePlaylistURI(mediaURI)
        let maximumDuration =
            index.references
            .map { Double($0.duration) / Double(index.timescale) }
            .max() ?? 0
        guard maximumDuration.isFinite, maximumDuration > 0 else {
            throw HLSPlaylistBuilderError.invalidSegmentDuration
        }
        let targetDuration = max(1, Int(ceil(maximumDuration)))
        let initialization = representation.segmentBase.initialization
        var lines = [
            "#EXTM3U",
            "#EXT-X-VERSION:7",
            "#EXT-X-TARGETDURATION:\(targetDuration)",
            "#EXT-X-MEDIA-SEQUENCE:0",
            "#EXT-X-PLAYLIST-TYPE:VOD",
            "#EXT-X-I-FRAMES-ONLY",
            "#EXT-X-MAP:URI=\"\(uri)\",BYTERANGE=\"\(byteRangeValue(initialization))\""
        ]
        for reference in index.references {
            let duration = Double(reference.duration) / Double(index.timescale)
            guard duration.isFinite, duration > 0 else {
                throw HLSPlaylistBuilderError.invalidSegmentDuration
            }
            lines.append("#EXTINF:\(formattedPlaylistDuration(duration)),")
            lines.append("#EXT-X-BYTERANGE:\(byteRangeValue(reference.byteRange))")
            lines.append(uri)
        }
        lines.append("#EXT-X-ENDLIST")
        return lines.joined(separator: "\n") + "\n"
    }
}

/// 为一个完整 WebVTT 正文构造单分段 VOD playlist。
public struct HLSSubtitlePlaylistBuilder: Sendable {
    public init() {}

    public func build(
        segmentURI: URL,
        duration: Double
    ) throws -> String {
        guard duration.isFinite, duration > 0 else {
            throw HLSPlaylistBuilderError.invalidSubtitleDuration
        }
        let uri = try safePlaylistURI(segmentURI)
        let targetDuration = max(1, Int(ceil(duration)))
        return [
            "#EXTM3U",
            "#EXT-X-VERSION:7",
            "#EXT-X-TARGETDURATION:\(targetDuration)",
            "#EXT-X-MEDIA-SEQUENCE:0",
            "#EXT-X-PLAYLIST-TYPE:VOD",
            "#EXTINF:\(formattedPlaylistDuration(duration)),",
            uri,
            "#EXT-X-ENDLIST",
            ""
        ].joined(separator: "\n")
    }
}

/// playlist 的引号属性与 URI 行只接受非空、且不含引号、反斜杠或任何控制字符（含 CR/LF/Tab）的文本。
func isPlaylistSafeText(_ value: String) -> Bool {
    !value.isEmpty
        && !value.contains("\"")
        && !value.contains("\\")
        && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
}

/// 本模块各 playlist builder 写 URI 行与 `URI=` 属性的唯一入口：不通过 `isPlaylistSafeText` 时抛
/// `unsafeURI`，防止 URI 注入新属性或新行。
func safePlaylistURI(_ url: URL) throws -> String {
    let value = url.absoluteString
    guard isPlaylistSafeText(value) else {
        throw HLSPlaylistBuilderError.unsafeURI
    }
    return value
}

/// HLS `BYTERANGE` 的 `<长度>@<起点>` 写法。
func byteRangeValue(_ range: MediaByteRange) -> String {
    let length = UInt64(range.endInclusive - range.start) + 1
    return "\(length)@\(range.start)"
}

/// playlist 里的秒数固定 6 位小数、POSIX 小数点，不随用户地区设置变化。
func formattedPlaylistDuration(_ duration: Double) -> String {
    String(
        format: "%.6f",
        locale: Locale(identifier: "en_US_POSIX"),
        duration
    )
}
