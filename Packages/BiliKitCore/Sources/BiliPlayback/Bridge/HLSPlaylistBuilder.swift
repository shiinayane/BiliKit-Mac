import BiliModels
import Foundation

public enum HLSPlaylistBuilderError: Error, Sendable, Equatable {
    case noMediaSegments
    case noVideoVariants
    case invalidTimescale
    case invalidMediaKind(expected: MediaKind, actual: MediaKind)
    case missingVideoAttributes(representationID: Int)
    case unsupportedFrameRate(representationID: Int)
    case invalidSegmentDuration
    case invalidCalculatedBitRate
    case bandwidthOverflow
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
        let uri = try safeURI(mediaURI)
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
            "#EXT-X-PLAYLIST-TYPE:VOD",
        ]
        if index.references.allSatisfy(\.startsWithSAP) {
            lines.append("#EXT-X-INDEPENDENT-SEGMENTS")
        }
        lines.append(
            "#EXT-X-MAP:URI=\"\(uri)\",BYTERANGE=\"\(byteRangeValue(initialization))\""
        )

        for reference in index.references {
            let duration = Double(reference.duration) / Double(index.timescale)
            lines.append("#EXTINF:\(formattedDuration(duration)),")
            lines.append("#EXT-X-BYTERANGE:\(byteRangeValue(reference.byteRange))")
            lines.append(uri)
        }
        lines.append("#EXT-X-ENDLIST")

        return lines.joined(separator: "\n") + "\n"
    }

    private func byteRangeValue(_ range: MediaByteRange) -> String {
        let length = UInt64(range.endInclusive - range.start) + 1
        return "\(length)@\(range.start)"
    }

    private func formattedDuration(_ duration: Double) -> String {
        String(
            format: "%.6f",
            locale: Locale(identifier: "en_US_POSIX"),
            duration
        )
    }

    private func safeURI(_ url: URL) throws -> String {
        let value = url.absoluteString
        guard !value.isEmpty,
            !value.contains("\r"),
            !value.contains("\n"),
            !value.contains("\"")
        else {
            throw HLSPlaylistBuilderError.unsafeURI
        }
        return value
    }
}

public struct HLSVideoVariant: Sendable, Equatable {
    public let representation: MediaRepresentation
    public let index: SegmentIndex
    public let playlistURI: URL

    public init(
        representation: MediaRepresentation,
        index: SegmentIndex,
        playlistURI: URL
    ) {
        self.representation = representation
        self.index = index
        self.playlistURI = playlistURI
    }
}

/// 把一个或多个视频 variant 与单一音频 representation 组合成 AVPlayer 的 ABR master playlist。
///
/// Builder 从真实分段计算带宽并验证媒体类型、视频属性与可嵌入字符串，不决定 CDN 或会话生命周期。
public struct HLSMasterPlaylistBuilder: Sendable {
    public init() {}

    public func build(
        videoVariants: [HLSVideoVariant],
        audio: MediaRepresentation,
        audioIndex: SegmentIndex,
        audioPlaylistURI: URL
    ) throws -> String {
        guard !videoVariants.isEmpty else {
            throw HLSPlaylistBuilderError.noVideoVariants
        }
        guard audio.kind == .audio else {
            throw HLSPlaylistBuilderError.invalidMediaKind(
                expected: .audio,
                actual: audio.kind
            )
        }

        let audioURI = try safeURI(audioPlaylistURI)
        let audioCodecs = try safeAttribute(audio.codecs)
        let audioGroupID = "audio-\(audio.id)"
        let audioBitRates = try bitRates(for: audioIndex)

        var lines = [
            "#EXTM3U",
            "#EXT-X-VERSION:7",
            "#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"\(audioGroupID)\",NAME=\"Audio \(audio.id)\",DEFAULT=YES,AUTOSELECT=YES,URI=\"\(audioURI)\"",
        ]

        for variant in videoVariants {
            let video = variant.representation
            guard video.kind == .video else {
                throw HLSPlaylistBuilderError.invalidMediaKind(
                    expected: .video,
                    actual: video.kind
                )
            }
            guard let attributes = video.videoAttributes else {
                throw HLSPlaylistBuilderError.missingVideoAttributes(
                    representationID: video.id
                )
            }
            guard attributes.frameRate <= 60 else {
                throw HLSPlaylistBuilderError.unsupportedFrameRate(
                    representationID: video.id
                )
            }

            let videoBitRates = try bitRates(for: variant.index)
            let bandwidth = try adding(
                videoBitRates.peak,
                audioBitRates.peak
            )
            let averageBandwidth = try adding(
                videoBitRates.average,
                audioBitRates.average
            )
            let videoURI = try safeURI(variant.playlistURI)
            let videoCodecs = try safeAttribute(video.codecs)
            let frameRate = String(
                format: "%.3f",
                locale: Locale(identifier: "en_US_POSIX"),
                attributes.frameRate
            )
            lines.append(
                "#EXT-X-STREAM-INF:BANDWIDTH=\(bandwidth),AVERAGE-BANDWIDTH=\(averageBandwidth),RESOLUTION=\(attributes.width)x\(attributes.height),FRAME-RATE=\(frameRate),CODECS=\"\(videoCodecs),\(audioCodecs)\",AUDIO=\"\(audioGroupID)\""
            )
            lines.append(videoURI)
        }

        return lines.joined(separator: "\n") + "\n"
    }

    private func bitRates(
        for index: SegmentIndex
    ) throws -> (peak: Int, average: Int) {
        guard !index.references.isEmpty else {
            throw HLSPlaylistBuilderError.noMediaSegments
        }
        guard index.timescale > 0 else {
            throw HLSPlaylistBuilderError.invalidTimescale
        }

        let segments = try index.references.map { reference in
            let duration =
                Double(reference.duration) / Double(index.timescale)
            guard duration.isFinite, duration > 0 else {
                throw HLSPlaylistBuilderError.invalidSegmentDuration
            }
            let byteCount =
                UInt64(reference.byteRange.endInclusive)
                - UInt64(reference.byteRange.start)
                + 1
            return (bits: Double(byteCount) * 8, duration: duration)
        }
        let totalBits = segments.reduce(0) { $0 + $1.bits }
        let totalDuration = segments.reduce(0) { $0 + $1.duration }
        let average = try integerBitRate(totalBits / totalDuration)

        let maximumDuration = segments.map(\.duration).max() ?? 0
        let targetDuration = ceil(maximumDuration)
        let minimumPeakWindow = 0.5 * targetDuration
        let maximumPeakWindow = 1.5 * targetDuration + 0.5
        var peak = 0.0

        for start in segments.indices {
            var bits = 0.0
            var duration = 0.0
            for end in start..<segments.endIndex {
                bits += segments[end].bits
                duration += segments[end].duration
                if duration > maximumPeakWindow {
                    break
                }
                if duration >= minimumPeakWindow {
                    peak = max(peak, bits / duration)
                }
            }
        }
        return (
            peak: try integerBitRate(peak),
            average: average
        )
    }

    private func integerBitRate(_ value: Double) throws -> Int {
        guard value.isFinite,
            value > 0,
            value <= Double(Int.max)
        else {
            throw HLSPlaylistBuilderError.invalidCalculatedBitRate
        }
        return Int(ceil(value))
    }

    private func adding(_ lhs: Int, _ rhs: Int) throws -> Int {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        guard !overflow else {
            throw HLSPlaylistBuilderError.bandwidthOverflow
        }
        return sum
    }

    private func safeAttribute(_ value: String) throws -> String {
        guard !value.isEmpty,
            !value.contains("\r"),
            !value.contains("\n"),
            !value.contains("\"")
        else {
            throw HLSPlaylistBuilderError.unsafeAttributeValue
        }
        return value
    }

    private func safeURI(_ url: URL) throws -> String {
        let value = url.absoluteString
        guard !value.isEmpty,
            !value.contains("\r"),
            !value.contains("\n"),
            !value.contains("\"")
        else {
            throw HLSPlaylistBuilderError.unsafeURI
        }
        return value
    }
}
