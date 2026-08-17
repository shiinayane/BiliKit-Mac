import BiliModels
import Foundation

public enum HLSPlaylistBuilderError: Error, Sendable, Equatable {
    case noMediaSegments
    case noVideoVariants
    case nonIndependentIFrameSegments
    case duplicateIFrameVariant(Int)
    case unknownIFrameVariant(Int)
    case unsupportedAudioRenditionCount(Int)
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

/// 复用普通 fMP4 fragment 的完整字节范围提供一个 I-frame rendition。
public struct HLSIFrameVariant: Sendable, Equatable {
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
        guard
            index.references.allSatisfy({ reference in
                reference.startsWithSAP
                    && reference.sapType == 1
                    && reference.sapDeltaTime == 0
            })
        else {
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
            "#EXT-X-MAP:URI=\"\(uri)\",BYTERANGE=\"\(byteRangeValue(initialization))\"",
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

/// 一条语义音轨在本次 master playlist 中选定的媒体 rendition。
public struct HLSAudioRendition: Sendable, Equatable {
    public let selectedTrack: SelectedPlaybackAudioTrack
    public let channelCount: Int?
    public let bitDepth: Int?
    public let sampleRate: Int?
    public let index: SegmentIndex
    public let playlistURI: URL

    public init(
        selectedTrack: SelectedPlaybackAudioTrack,
        channelCount: Int? = nil,
        bitDepth: Int? = nil,
        sampleRate: Int? = nil,
        index: SegmentIndex,
        playlistURI: URL
    ) {
        self.selectedTrack = selectedTrack
        self.channelCount = channelCount
        self.bitDepth = bitDepth
        self.sampleRate = sampleRate
        self.index = index
        self.playlistURI = playlistURI
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
        let formattedDuration = String(
            format: "%.6f",
            locale: Locale(identifier: "en_US_POSIX"),
            duration
        )
        return [
            "#EXTM3U",
            "#EXT-X-VERSION:7",
            "#EXT-X-TARGETDURATION:\(targetDuration)",
            "#EXT-X-MEDIA-SEQUENCE:0",
            "#EXT-X-PLAYLIST-TYPE:VOD",
            "#EXTINF:\(formattedDuration),",
            uri,
            "#EXT-X-ENDLIST",
            "",
        ].joined(separator: "\n")
    }
}

/// 把一个或多个视频 variant 与语义音轨 rendition 集合组合成 AVPlayer 的 ABR master playlist。
///
/// Builder 从真实分段计算带宽并验证媒体类型、视频属性与可嵌入字符串，不决定 CDN 或会话生命周期。
public struct HLSMasterPlaylistBuilder: Sendable {
    public init() {}

    public func build(
        videoVariants: [HLSVideoVariant],
        audioRenditions: [HLSAudioRendition],
        subtitleRenditions: [HLSSubtitleRendition] = [],
        iFrameVariants: [HLSIFrameVariant] = [],
        localizedRenditionNamesURI: URL? = nil
    ) throws -> String {
        guard !videoVariants.isEmpty else {
            throw HLSPlaylistBuilderError.noVideoVariants
        }
        guard !audioRenditions.isEmpty else {
            throw HLSPlaylistBuilderError.unsupportedAudioRenditionCount(
                audioRenditions.count
            )
        }
        let defaultCount = audioRenditions.filter {
            $0.selectedTrack.track.isDefault
        }.count
        guard defaultCount == 1 else {
            throw HLSPlaylistBuilderError.invalidDefaultAudioRenditionCount(
                defaultCount
            )
        }
        let audioGroupID =
            audioRenditions.count == 1
            ? "audio-\(audioRenditions[0].selectedTrack.representation.id)"
            : "audio"
        var audioTrackIDs = Set<String>()
        var audioNames = Set<String>()
        var audioCodecs: [String] = []
        var audioCodecSet = Set<String>()
        var audioPeakBitRate = 0
        var audioAverageBitRate = 0
        var lines = [
            "#EXTM3U",
            "#EXT-X-VERSION:7",
        ]
        let allIndices = videoVariants.map(\.index) + audioRenditions.map(\.index)
        if allIndices.allSatisfy(isIndependent) {
            lines.append("#EXT-X-INDEPENDENT-SEGMENTS")
        }
        if let localizedRenditionNamesURI {
            lines.append(
                "#EXT-X-SESSION-DATA:DATA-ID=\"_hls.localized-rendition-names\",URI=\"\(try safeURI(localizedRenditionNamesURI))\""
            )
        }
        for rendition in audioRenditions {
            let selectedAudio = rendition.selectedTrack
            guard audioTrackIDs.insert(selectedAudio.track.id).inserted else {
                throw HLSPlaylistBuilderError.duplicateAudioTrackID(
                    selectedAudio.track.id
                )
            }
            guard audioNames.insert(selectedAudio.track.displayName).inserted else {
                throw HLSPlaylistBuilderError.duplicateAudioRenditionName(
                    selectedAudio.track.displayName
                )
            }
            guard
                !selectedAudio.track.isDefault
                    || selectedAudio.track.isAutoselect,
                selectedAudio.track.representations.contains(
                    selectedAudio.representation
                )
            else {
                throw HLSPlaylistBuilderError.invalidAudioTrackSelection(
                    trackID: selectedAudio.track.id,
                    representationID: selectedAudio.representation.id
                )
            }
            let audio = selectedAudio.representation
            guard audio.kind == .audio else {
                throw HLSPlaylistBuilderError.invalidMediaKind(
                    expected: .audio,
                    actual: audio.kind
                )
            }
            try validateAudioFormat(rendition)
            let codec = try safeAttribute(audio.codecs)
            if audioCodecSet.insert(codec).inserted {
                audioCodecs.append(codec)
            }
            let audioBitRates = try bitRates(for: rendition.index)
            audioPeakBitRate = max(audioPeakBitRate, audioBitRates.peak)
            audioAverageBitRate = max(
                audioAverageBitRate,
                audioBitRates.average
            )
            let audioName = try safeAttribute(selectedAudio.track.displayName)
            let audioLanguage = try safeLanguageTag(
                selectedAudio.track.languageTag ?? "und"
            )
            let audioCharacteristics = try characteristics(
                for: selectedAudio.track.role
            )
            var audioLine =
                "#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"\(audioGroupID)\",NAME=\"\(audioName)\",LANGUAGE=\"\(audioLanguage)\",CHARACTERISTICS=\"\(audioCharacteristics)\""
            if let channelCount = rendition.channelCount {
                audioLine += ",CHANNELS=\"\(channelCount)\""
            }
            if let bitDepth = rendition.bitDepth {
                audioLine += ",BIT-DEPTH=\(bitDepth)"
            }
            if let sampleRate = rendition.sampleRate {
                audioLine += ",SAMPLE-RATE=\(sampleRate)"
            }
            audioLine +=
                ",DEFAULT=\(yesNo(selectedAudio.track.isDefault)),AUTOSELECT=\(yesNo(selectedAudio.track.isAutoselect)),URI=\"\(try safeURI(rendition.playlistURI))\""
            lines.append(audioLine)
        }

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
            let uri = try safeURI(rendition.playlistURI)
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
            let frameRate = attributes.frameRate.map {
                String(
                    format: "%.3f",
                    locale: Locale(identifier: "en_US_POSIX"),
                    $0
                )
            }

            let videoBitRates = try bitRates(for: variant.index)
            let bandwidth = try adding(
                videoBitRates.peak,
                audioPeakBitRate
            )
            let averageBandwidth = try adding(
                videoBitRates.average,
                audioAverageBitRate
            )
            let videoURI = try safeURI(variant.playlistURI)
            let videoCodecs = try safeAttribute(video.codecs)
            let codecs = try safeAttribute(
                ([videoCodecs] + audioCodecs).joined(separator: ",")
            )
            var streamAttributes =
                "#EXT-X-STREAM-INF:BANDWIDTH=\(bandwidth),AVERAGE-BANDWIDTH=\(averageBandwidth),RESOLUTION=\(attributes.width)x\(attributes.height)"
            if let frameRate {
                streamAttributes += ",FRAME-RATE=\(frameRate)"
            }
            streamAttributes += ",CODECS=\"\(codecs)\",AUDIO=\"\(audioGroupID)\""
            if !subtitleRenditions.isEmpty {
                streamAttributes += ",SUBTITLES=\"\(subtitleGroupID)\""
            }
            streamAttributes += ",CLOSED-CAPTIONS=NONE"
            lines.append(streamAttributes)
            lines.append(videoURI)
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
            guard
                variant.index.references.allSatisfy({ reference in
                    reference.startsWithSAP
                        && reference.sapType == 1
                        && reference.sapDeltaTime == 0
                })
            else {
                throw HLSPlaylistBuilderError.nonIndependentIFrameSegments
            }
            let bitRates = try bitRates(for: variant.index)
            let uri = try safeURI(variant.playlistURI)
            let codecs = try safeAttribute(video.codecs)
            lines.append(
                "#EXT-X-I-FRAME-STREAM-INF:BANDWIDTH=\(bitRates.peak),AVERAGE-BANDWIDTH=\(bitRates.average),RESOLUTION=\(attributes.width)x\(attributes.height),CODECS=\"\(codecs)\",URI=\"\(uri)\""
            )
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
        let maximumPeakWindow = 1.5 * targetDuration
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

    private func validateAudioFormat(
        _ rendition: HLSAudioRendition
    ) throws {
        if let channelCount = rendition.channelCount,
            !(1...128).contains(channelCount)
        {
            throw HLSPlaylistBuilderError.invalidAudioFormatMetadata
        }
        if let bitDepth = rendition.bitDepth,
            !(1...64).contains(bitDepth)
        {
            throw HLSPlaylistBuilderError.invalidAudioFormatMetadata
        }
        if let sampleRate = rendition.sampleRate,
            !(1...768_000).contains(sampleRate)
        {
            throw HLSPlaylistBuilderError.invalidAudioFormatMetadata
        }
    }

    private func characteristics(
        for role: PlaybackAudioTrack.Role
    ) throws -> String {
        switch role {
        case .original:
            try safeCharacteristics(["public.original-content"])
        case .machineGenerated:
            try safeCharacteristics(["public.machine-generated"])
        }
    }

    private func isIndependent(_ index: SegmentIndex) -> Bool {
        !index.references.isEmpty
            && index.references.allSatisfy {
                $0.startsWithSAP
                    && $0.sapType == 1
                    && $0.sapDeltaTime == 0
            }
    }

    private func yesNo(_ value: Bool) -> String {
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

    private func safeAttribute(_ value: String) throws -> String {
        guard !value.isEmpty,
            value.utf8.count <= 128,
            !value.contains("\""),
            !value.contains("\\"),
            !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else {
            throw HLSPlaylistBuilderError.unsafeAttributeValue
        }
        return value
    }

    private func safeCharacteristics(_ values: [String]) throws -> String {
        guard !values.isEmpty,
            values.allSatisfy({ !$0.contains(",") })
        else {
            throw HLSPlaylistBuilderError.unsafeAttributeValue
        }
        return try safeAttribute(values.joined(separator: ","))
    }

    private func safeLanguageTag(_ value: String) throws -> String {
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

    private func safeURI(_ url: URL) throws -> String {
        try safePlaylistURI(url)
    }
}

private func safePlaylistURI(_ url: URL) throws -> String {
    let value = url.absoluteString
    guard !value.isEmpty,
        !value.contains("\""),
        !value.contains("\\"),
        !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    else {
        throw HLSPlaylistBuilderError.unsafeURI
    }
    return value
}

private func byteRangeValue(_ range: MediaByteRange) -> String {
    let length = UInt64(range.endInclusive - range.start) + 1
    return "\(length)@\(range.start)"
}

private func formattedPlaylistDuration(_ duration: Double) -> String {
    String(
        format: "%.6f",
        locale: Locale(identifier: "en_US_POSIX"),
        duration
    )
}
