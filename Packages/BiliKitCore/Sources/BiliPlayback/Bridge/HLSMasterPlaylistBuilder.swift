import BiliModels
import Foundation

/// master playlist 的一个视频档：representation、它的 SIDX 与本机 media playlist URI。
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

/// 把一个或多个视频 variant 与语义音轨 rendition 集合（稿件没有声音时为空）组合成 AVPlayer 的 ABR master playlist。
///
/// Builder 从真实分段计算带宽并验证媒体类型、视频属性与可嵌入字符串，不决定 CDN 或会话生命周期。
public struct HLSMasterPlaylistBuilder: Sendable {
    public init() {}

    public func build(
        videoVariants: [HLSVideoVariant],
        audioRenditions: [HLSAudioRendition],
        subtitleRenditions: [HLSSubtitleRendition] = [],
        iFrameVariants: [HLSIFrameVariant] = [],
        localizedRenditionNamesURI: URL? = nil,
        startOffsetSeconds: Double? = nil
    ) throws -> String {
        guard !videoVariants.isEmpty else {
            throw HLSPlaylistBuilderError.noVideoVariants
        }
        // 没有声音的稿件没有音频 rendition：master 只写视频 variant，不声明 AUDIO group。
        let defaultCount = audioRenditions.filter {
            $0.selectedTrack.track.isDefault
        }.count
        guard audioRenditions.isEmpty || defaultCount == 1 else {
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
            "#EXT-X-VERSION:7"
        ]
        let allIndices = videoVariants.map(\.index) + audioRenditions.map(\.index)
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
            // macOS 27 的音轨菜单不显示音频的 NAME，B 站的配音标题在这里只用于 NAME 唯一性。
            let audioName = try safeAttribute(selectedAudio.track.displayName)
            // 没有语言标记的音轨（原声）不写 LANGUAGE：写 `und` 时系统菜单会附上“未知语言”。
            // 这样原声在菜单里的名字只来自 `_hls.localized-rendition-names`，缺这份会话数据时只剩
            // 系统加的“（原始）”标注；DASHToHLSBridge 生成的每份 master 都必须带它。
            var audioLanguage = ""
            if let languageTag = selectedAudio.track.languageTag {
                audioLanguage = ",LANGUAGE=\"\(try safeLanguageTag(languageTag))\""
            }
            let audioCharacteristics = try characteristics(
                for: selectedAudio.track.role
            )
            var audioLine =
                "#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"\(audioGroupID)\",NAME=\"\(audioName)\"\(audioLanguage),CHARACTERISTICS=\"\(audioCharacteristics)\""
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
                ",DEFAULT=\(yesNo(selectedAudio.track.isDefault)),AUTOSELECT=\(yesNo(selectedAudio.track.isAutoselect)),URI=\"\(try safePlaylistURI(rendition.playlistURI))\""
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
            // 带宽取视频加 AUDIO group 内最高的音频码率，CODECS 也列出全部音频 codec：
            // 组内任一音轨都可能被选中。
            let bandwidth = try adding(
                videoBitRates.peak,
                audioPeakBitRate
            )
            let averageBandwidth = try adding(
                videoBitRates.average,
                audioAverageBitRate
            )
            let videoURI = try safePlaylistURI(variant.playlistURI)
            let videoCodecs = try safeAttribute(video.codecs)
            let codecs = try safeAttribute(
                ([videoCodecs] + audioCodecs).joined(separator: ",")
            )
            var streamAttributes =
                "#EXT-X-STREAM-INF:BANDWIDTH=\(bandwidth),AVERAGE-BANDWIDTH=\(averageBandwidth),RESOLUTION=\(attributes.width)x\(attributes.height)"
            if let frameRate {
                streamAttributes += ",FRAME-RATE=\(frameRate)"
            }
            streamAttributes += ",CODECS=\"\(codecs)\""
            if !audioRenditions.isEmpty {
                streamAttributes += ",AUDIO=\"\(audioGroupID)\""
            }
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
            // 空索引不在这里拒绝，交给下面 `bitRates(for:)` 报 `noMediaSegments`。
            guard variant.index.allReferencesStartWithType1SAP else {
                throw HLSPlaylistBuilderError.nonIndependentIFrameSegments
            }
            let bitRates = try bitRates(for: variant.index)
            let uri = try safePlaylistURI(variant.playlistURI)
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
        return (
            peak: try HLSPeakBitRate.peak(of: index),
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

    /// 写进 HLS `CHARACTERISTICS` 的音轨角色。
    ///
    /// macOS 27 的音轨菜单给原声加“（原始）”并排在最前，给机器配音显示语言名加“生成”。音频不写
    /// `public.translation`：拿不到原声语言，就无法确认配音与原声语言不同。
    private func characteristics(
        for role: PlaybackAudioTrack.Role
    ) throws -> String {
        switch role {
        case .original: try safeCharacteristics(["public.original-content"])
        case .machineGenerated: try safeCharacteristics(["public.machine-generated"])
        }
    }

    /// 空索引没有可声明独立的分段，不算独立。
    private func isIndependent(_ index: SegmentIndex) -> Bool {
        !index.references.isEmpty && index.allReferencesStartWithType1SAP
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

    /// 写进引号属性的文本（显示名、codecs、语言等，部分来自远端）必须通过 `isPlaylistSafeText`
    /// 且不超过 128 字节，不能注入新属性或新行。
    private func safeAttribute(_ value: String) throws -> String {
        guard isPlaylistSafeText(value), value.utf8.count <= 128 else {
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
}
