import BiliModels
import Foundation

/// HLS `VIDEO-RANGE` 的取值。
///
/// master 里有 HDR 档时，SDR 档与全部 I-frame 行也写明 `SDR`；没有 HDR 档时都不写。AVPlayer 只在一个
/// 动态范围内做 ABR（实测，见 ARCHITECTURE）。
public enum HLSVideoRange: String, Sendable, Equatable {
    case sdr = "SDR"
    case pq = "PQ"
    case hlg = "HLG"
}

/// master playlist 的一个视频档：representation、它的 SIDX、本机 media playlist URI，以及 HDR 时的
/// 动态范围与杜比视界的 `SUPPLEMENTAL-CODECS`。
public struct HLSVideoVariant: Sendable, Equatable {
    public let representation: MediaRepresentation
    public let index: SegmentIndex
    public let playlistURI: URL
    public let videoRange: HLSVideoRange?
    public let supplementalCodecs: String?

    public init(
        representation: MediaRepresentation,
        index: SegmentIndex,
        playlistURI: URL,
        videoRange: HLSVideoRange? = nil,
        supplementalCodecs: String? = nil
    ) {
        self.representation = representation
        self.index = index
        self.playlistURI = playlistURI
        self.videoRange = videoRange
        self.supplementalCodecs = supplementalCodecs
    }
}

/// 复用普通 fMP4 fragment 的完整字节范围提供一个 I-frame rendition；动态范围与对应视频档相同。
public struct HLSIFrameVariant: Sendable, Equatable {
    public let representation: MediaRepresentation
    public let index: SegmentIndex
    public let playlistURI: URL
    public let videoRange: HLSVideoRange?

    public init(
        representation: MediaRepresentation,
        index: SegmentIndex,
        playlistURI: URL,
        videoRange: HLSVideoRange? = nil
    ) {
        self.representation = representation
        self.index = index
        self.playlistURI = playlistURI
        self.videoRange = videoRange
    }
}

/// master playlist 的一条字幕 rendition：显示名、语言、HLS 特征、选择属性与本机 playlist URI。
public struct HLSSubtitleRendition: Sendable, Equatable {
    public let name: String
    public let languageTag: String
    public let characteristics: [String]
    public let isDefault: Bool
    public let isAutoselect: Bool
    public let isForced: Bool
    public let playlistURI: URL

    public init(
        name: String,
        languageTag: String,
        characteristics: [String] = [],
        isDefault: Bool = false,
        isAutoselect: Bool = false,
        isForced: Bool = false,
        playlistURI: URL
    ) {
        self.name = name
        self.languageTag = languageTag
        self.characteristics = characteristics
        self.isDefault = isDefault
        self.isAutoselect = isAutoselect
        self.isForced = isForced
        self.playlistURI = playlistURI
    }
}

/// 把一个或多个视频 variant 与音频组（稿件没有声音时为空）组合成 AVPlayer 的 ABR master playlist。
///
/// 每个视频档与每个音频组组合成一行 variant，按音频组在外、视频档在内排列，所以首行是第一组配第一个
/// 视频档。Builder 从真实分段计算带宽并验证媒体类型、视频属性与可嵌入字符串，不决定 CDN 或会话生命周期。
public struct HLSMasterPlaylistBuilder: Sendable {
    public init() {}

    public func build(
        videoVariants: [HLSVideoVariant],
        audioGroups: [HLSAudioGroup],
        subtitleRenditions: [HLSSubtitleRendition] = [],
        iFrameVariants: [HLSIFrameVariant] = [],
        localizedRenditionNamesURI: URL? = nil,
        startOffsetSeconds: Double? = nil
    ) throws -> String {
        guard !videoVariants.isEmpty else {
            throw HLSPlaylistBuilderError.noVideoVariants
        }
        // `VIDEO-RANGE` 要么每个视频档与 I-frame 行都写，要么都不写：只给部分档写时，没写的档按 SDR
        // 处理，与写明的档混在一起时 AVPlayer 的选择取决于它自己的推断。
        let declaresVideoRange = videoVariants[0].videoRange != nil
        guard videoVariants.allSatisfy({ ($0.videoRange != nil) == declaresVideoRange }),
            iFrameVariants.allSatisfy({ ($0.videoRange != nil) == declaresVideoRange })
        else {
            throw HLSPlaylistBuilderError.inconsistentVideoRange
        }
        var lines = [
            "#EXTM3U",
            "#EXT-X-VERSION:7"
        ]
        let allIndices =
            videoVariants.map(\.index) + audioGroups.flatMap { $0.renditions.map(\.index) }
        if allIndices.allSatisfy(isIndependent) {
            lines.append("#EXT-X-INDEPENDENT-SEGMENTS")
        }
        if let startOffsetSeconds, startOffsetSeconds.isFinite, startOffsetSeconds > 0 {
            lines.append(
                "#EXT-X-START:TIME-OFFSET=\(formattedPlaylistDuration(startOffsetSeconds)),PRECISE=YES"
            )
        }
        if let localizedRenditionNamesURI {
            lines.append(
                "#EXT-X-SESSION-DATA:DATA-ID=\"_hls.localized-rendition-names\",URI=\"\(try safePlaylistURI(localizedRenditionNamesURI))\""
            )
        }
        // 没有声音的稿件没有音频组：master 只写视频 variant，不声明 AUDIO group。
        let audio = try audioGroupLines(audioGroups)
        lines += audio.lines

        let subtitleGroupID = "subtitles"
        var subtitleNames = Set<String>()
        for rendition in subtitleRenditions {
            guard subtitleNames.insert(rendition.name).inserted else {
                throw HLSPlaylistBuilderError.duplicateSubtitleRenditionName(
                    rendition.name
                )
            }
            guard !rendition.isDefault || rendition.isAutoselect else {
                throw HLSPlaylistBuilderError.invalidRenditionSelection
            }
            let name = try safeAttribute(rendition.name)
            let language = try safeLanguageTag(rendition.languageTag)
            let uri = try safePlaylistURI(rendition.playlistURI)
            var subtitleLine =
                "#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID=\"\(subtitleGroupID)\",NAME=\"\(name)\",LANGUAGE=\"\(language)\""
            if !rendition.characteristics.isEmpty {
                subtitleLine +=
                    ",CHARACTERISTICS=\"\(try safeCharacteristics(rendition.characteristics))\""
            }
            subtitleLine +=
                ",DEFAULT=\(yesNo(rendition.isDefault)),AUTOSELECT=\(yesNo(rendition.isAutoselect)),FORCED=\(yesNo(rendition.isForced)),URI=\"\(uri)\""
            lines.append(subtitleLine)
        }

        let groupsForVariants: [AudioGroupSummary?] =
            audio.summaries.isEmpty ? [nil] : audio.summaries
        for group in groupsForVariants {
            for variant in videoVariants {
                lines += try variantLines(
                    variant,
                    audioGroup: group,
                    subtitleGroupID: subtitleRenditions.isEmpty ? nil : subtitleGroupID
                )
            }
        }

        var iFrameRepresentationIDs = Set<Int>()
        for variant in iFrameVariants {
            let video = variant.representation
            guard
                videoVariants.contains(where: {
                    $0.representation == video
                })
            else {
                throw HLSPlaylistBuilderError.unknownIFrameVariant(video.id)
            }
            guard iFrameRepresentationIDs.insert(video.id).inserted else {
                throw HLSPlaylistBuilderError.duplicateIFrameVariant(video.id)
            }
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
            // 空索引不在这里拒绝，交给下面 `bitRates(for:)` 报 `noMediaSegments`。
            guard variant.index.allReferencesStartWithType1SAP else {
                throw HLSPlaylistBuilderError.nonIndependentIFrameSegments
            }
            let bitRates = try bitRates(for: variant.index)
            let uri = try safePlaylistURI(variant.playlistURI)
            let codecs = try safeAttribute(video.codecs)
            let videoRange = variant.videoRange.map { ",VIDEO-RANGE=\($0.rawValue)" } ?? ""
            lines.append(
                "#EXT-X-I-FRAME-STREAM-INF:BANDWIDTH=\(bitRates.peak),AVERAGE-BANDWIDTH=\(bitRates.average),RESOLUTION=\(attributes.width)x\(attributes.height),CODECS=\"\(codecs)\"\(videoRange),URI=\"\(uri)\""
            )
        }

        return lines.joined(separator: "\n") + "\n"
    }

    /// 一个视频档配一个音频组的 `EXT-X-STREAM-INF` 与 URI 两行；带宽取视频加该组最高的音频码率，CODECS
    /// 也列出该组全部音频 codec：组内任一音轨都可能被选中。
    private func variantLines(
        _ variant: HLSVideoVariant,
        audioGroup: AudioGroupSummary?,
        subtitleGroupID: String?
    ) throws -> [String] {
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
        let frameRate = attributes.frameRate.map {
            String(
                format: "%.3f",
                locale: Locale(identifier: "en_US_POSIX"),
                $0
            )
        }

        let videoBitRates = try bitRates(for: variant.index)
        let bandwidth = try adding(videoBitRates.peak, audioGroup?.peakBitRate ?? 0)
        let averageBandwidth = try adding(
            videoBitRates.average,
            audioGroup?.averageBitRate ?? 0
        )
        let videoURI = try safePlaylistURI(variant.playlistURI)
        let videoCodecs = try safeAttribute(video.codecs)
        let codecs = try safeAttribute(
            ([videoCodecs] + (audioGroup?.codecs ?? [])).joined(separator: ",")
        )
        var streamAttributes =
            "#EXT-X-STREAM-INF:BANDWIDTH=\(bandwidth),AVERAGE-BANDWIDTH=\(averageBandwidth),RESOLUTION=\(attributes.width)x\(attributes.height)"
        if let frameRate {
            streamAttributes += ",FRAME-RATE=\(frameRate)"
        }
        streamAttributes += ",CODECS=\"\(codecs)\""
        if let supplementalCodecs = variant.supplementalCodecs {
            streamAttributes +=
                ",SUPPLEMENTAL-CODECS=\"\(try safeAttribute(supplementalCodecs))\""
        }
        if let videoRange = variant.videoRange {
            streamAttributes += ",VIDEO-RANGE=\(videoRange.rawValue)"
        }
        if let audioGroup {
            streamAttributes += ",AUDIO=\"\(audioGroup.id)\""
        }
        if let subtitleGroupID {
            streamAttributes += ",SUBTITLES=\"\(subtitleGroupID)\""
        }
        streamAttributes += ",CLOSED-CAPTIONS=NONE"
        return [streamAttributes, videoURI]
    }

    func bitRates(
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
        return (
            peak: try HLSPeakBitRate.peak(of: index),
            average: average
        )
    }

    /// 空索引没有可声明独立的分段，不算独立。
    private func isIndependent(_ index: SegmentIndex) -> Bool {
        !index.references.isEmpty && index.allReferencesStartWithType1SAP
    }

    func yesNo(_ value: Bool) -> String {
        value ? "YES" : "NO"
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

    /// 写进引号属性的文本（显示名、codecs、语言等，部分来自远端）必须通过 `isPlaylistSafeText`
    /// 且不超过 128 字节，不能注入新属性或新行。
    func safeAttribute(_ value: String) throws -> String {
        guard isPlaylistSafeText(value), value.utf8.count <= 128 else {
            throw HLSPlaylistBuilderError.unsafeAttributeValue
        }
        return value
    }

    func safeCharacteristics(_ values: [String]) throws -> String {
        guard !values.isEmpty,
            values.allSatisfy({ !$0.contains(",") })
        else {
            throw HLSPlaylistBuilderError.unsafeAttributeValue
        }
        return try safeAttribute(values.joined(separator: ","))
    }

    func safeLanguageTag(_ value: String) throws -> String {
        let safeValue = try safeAttribute(value)
        let subtags = safeValue.split(
            separator: "-",
            omittingEmptySubsequences: false
        )
        guard let primary = subtags.first,
            (2...3).contains(primary.utf8.count),
            primary.utf8.allSatisfy(isASCIILetter),
            subtags.dropFirst().allSatisfy({ subtag in
                (1...8).contains(subtag.utf8.count)
                    && subtag.utf8.allSatisfy(isASCIIAlphaNumeric)
            })
        else {
            throw HLSPlaylistBuilderError.unsafeAttributeValue
        }
        return safeValue
    }

    private func isASCIILetter(_ byte: UInt8) -> Bool {
        (65...90).contains(byte) || (97...122).contains(byte)
    }

    private func isASCIIAlphaNumeric(_ byte: UInt8) -> Bool {
        isASCIILetter(byte) || (48...57).contains(byte)
    }
}
