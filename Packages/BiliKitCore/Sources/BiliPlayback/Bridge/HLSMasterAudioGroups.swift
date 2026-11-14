import BiliModels
import Foundation

/// 音频组里的一条 rendition：语义音轨、它在这一组里的版本、音频格式属性、SIDX 与本机 playlist URI。
///
/// `isJointObjectCoded` 为真时是杜比全景声（E-AC-3 JOC），`channelCount` 是 JOC 复杂度，写成
/// `CHANNELS="<n>/JOC"`；调用方只在这一组的 init 确实带 JOC 标记时设它，master 不能对没有标记的 init
/// 声明全景声。
public struct HLSAudioRendition: Sendable, Equatable {
    public let track: PlaybackAudioTrack
    public let representation: MediaRepresentation
    public let channelCount: Int?
    public let isJointObjectCoded: Bool
    public let bitDepth: Int?
    public let sampleRate: Int?
    public let index: SegmentIndex
    public let playlistURI: URL

    public init(
        track: PlaybackAudioTrack,
        representation: MediaRepresentation,
        channelCount: Int? = nil,
        isJointObjectCoded: Bool = false,
        bitDepth: Int? = nil,
        sampleRate: Int? = nil,
        index: SegmentIndex,
        playlistURI: URL
    ) {
        self.track = track
        self.representation = representation
        self.channelCount = channelCount
        self.isJointObjectCoded = isJointObjectCoded
        self.bitDepth = bitDepth
        self.sampleRate = sampleRate
        self.index = index
        self.playlistURI = playlistURI
    }
}

/// master 里的一个 AUDIO group：原声的一个版本（某档 AAC、杜比或无损）加上全部配音。
///
/// 同类型的各组成员集合必须相同（RFC 8216bis §4.4.6.1.1），只有原声的版本不同；配音在每组里引用同一个
/// URI。原声在每组里同名，系统菜单把它们合并成一项，组之间由 AVPlayer 的 ABR 与 `variantPreferences`
/// 选择（见 ARCHITECTURE 的音频组一节）。
public struct HLSAudioGroup: Sendable, Equatable {
    public let renditions: [HLSAudioRendition]

    public init(renditions: [HLSAudioRendition]) {
        self.renditions = renditions
    }
}

extension HLSMasterPlaylistBuilder {
    /// 一个已写进 master 的音频组：GROUP-ID、组内 codec（按出现顺序去重）与组内最高的峰值、平均码率。
    ///
    /// 组内任一成员都可能被选中，所以引用这一组的视频档按组内最高码率计带宽、列出组内全部 codec。
    struct AudioGroupSummary {
        let id: String
        let codecs: [String]
        let peakBitRate: Int
        let averageBitRate: Int
    }

    /// 校验各音频组并生成 `EXT-X-MEDIA:TYPE=AUDIO` 行。
    ///
    /// 每组恰好一条默认 rendition，组内音轨 ID 与 NAME 唯一，各组的音轨 ID 集合相同；GROUP-ID 取
    /// `audio-` 加该组默认 rendition 的 representation ID，必须互不相同。
    func audioGroupLines(
        _ groups: [HLSAudioGroup]
    ) throws -> (lines: [String], summaries: [AudioGroupSummary]) {
        var lines: [String] = []
        var summaries: [AudioGroupSummary] = []
        var groupIDs = Set<String>()
        var memberIDs: Set<String>?
        for group in groups {
            let defaults = group.renditions.filter(\.track.isDefault)
            guard defaults.count == 1 else {
                throw HLSPlaylistBuilderError.invalidDefaultAudioRenditionCount(defaults.count)
            }
            let groupID = "audio-\(defaults[0].representation.id)"
            guard groupIDs.insert(groupID).inserted else {
                throw HLSPlaylistBuilderError.duplicateAudioGroup(groupID)
            }
            var trackIDs = Set<String>()
            var names = Set<String>()
            var codecs: [String] = []
            var peakBitRate = 0
            var averageBitRate = 0
            for rendition in group.renditions {
                guard trackIDs.insert(rendition.track.id).inserted else {
                    throw HLSPlaylistBuilderError.duplicateAudioTrackID(rendition.track.id)
                }
                guard names.insert(rendition.track.displayName).inserted else {
                    throw HLSPlaylistBuilderError.duplicateAudioRenditionName(
                        rendition.track.displayName
                    )
                }
                let codec = try validatedCodec(rendition)
                if !codecs.contains(codec) {
                    codecs.append(codec)
                }
                let bitRates = try bitRates(for: rendition.index)
                peakBitRate = max(peakBitRate, bitRates.peak)
                averageBitRate = max(averageBitRate, bitRates.average)
                lines.append(try mediaLine(rendition, groupID: groupID))
            }
            guard memberIDs == nil || memberIDs == trackIDs else {
                throw HLSPlaylistBuilderError.inconsistentAudioGroupMembers
            }
            memberIDs = trackIDs
            summaries.append(
                AudioGroupSummary(
                    id: groupID,
                    codecs: codecs,
                    peakBitRate: peakBitRate,
                    averageBitRate: averageBitRate
                )
            )
        }
        return (lines, summaries)
    }

    private func validatedCodec(_ rendition: HLSAudioRendition) throws -> String {
        guard !rendition.track.isDefault || rendition.track.isAutoselect,
            rendition.track.offers(rendition.representation)
        else {
            throw HLSPlaylistBuilderError.invalidAudioTrackSelection(
                trackID: rendition.track.id,
                representationID: rendition.representation.id
            )
        }
        guard rendition.representation.kind == .audio else {
            throw HLSPlaylistBuilderError.invalidMediaKind(
                expected: .audio,
                actual: rendition.representation.kind
            )
        }
        if let channelCount = rendition.channelCount, !(1...128).contains(channelCount) {
            throw HLSPlaylistBuilderError.invalidAudioFormatMetadata
        }
        // JOC 只属于 E-AC-3，且必须带复杂度。
        if rendition.isJointObjectCoded,
            rendition.representation.codecs.lowercased() != "ec-3" || rendition.channelCount == nil
        {
            throw HLSPlaylistBuilderError.invalidAudioFormatMetadata
        }
        if let bitDepth = rendition.bitDepth, !(1...64).contains(bitDepth) {
            throw HLSPlaylistBuilderError.invalidAudioFormatMetadata
        }
        if let sampleRate = rendition.sampleRate, !(1...768_000).contains(sampleRate) {
            throw HLSPlaylistBuilderError.invalidAudioFormatMetadata
        }
        return try safeAttribute(rendition.representation.codecs)
    }

    private func mediaLine(_ rendition: HLSAudioRendition, groupID: String) throws -> String {
        let track = rendition.track
        // macOS 27 的音轨菜单不显示音频的 NAME，B 站的配音标题在这里只用于 NAME 唯一性；原声在每组
        // 同名，菜单把它们合并成一项。
        let name = try safeAttribute(track.displayName)
        // 没有语言标记的音轨（原声）不写 LANGUAGE：写 `und` 时系统菜单会附上“未知语言”。
        // 这样原声在菜单里的名字只来自 `_hls.localized-rendition-names`，缺这份会话数据时只剩
        // 系统加的“（原始）”标注；DASHToHLSBridge 生成的每份 master 都必须带它。
        var language = ""
        if let languageTag = track.languageTag {
            language = ",LANGUAGE=\"\(try safeLanguageTag(languageTag))\""
        }
        var line =
            "#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"\(groupID)\",NAME=\"\(name)\"\(language),CHARACTERISTICS=\"\(try characteristics(for: track.role))\""
        if let channelCount = rendition.channelCount {
            // Apple HLS Authoring Spec：全景声的 CODECS 仍是 `ec-3`，CHANNELS 写 JOC 复杂度加 `/JOC`。
            let objectCoding = rendition.isJointObjectCoded ? "/JOC" : ""
            line += ",CHANNELS=\"\(channelCount)\(objectCoding)\""
        }
        if let bitDepth = rendition.bitDepth {
            line += ",BIT-DEPTH=\(bitDepth)"
        }
        if let sampleRate = rendition.sampleRate {
            line += ",SAMPLE-RATE=\(sampleRate)"
        }
        line +=
            ",DEFAULT=\(yesNo(track.isDefault)),AUTOSELECT=\(yesNo(track.isAutoselect)),URI=\"\(try safePlaylistURI(rendition.playlistURI))\""
        return line
    }

    /// 写进 HLS `CHARACTERISTICS` 的音轨角色。
    ///
    /// macOS 27 的音轨菜单给原声加“（原始）”并排在最前，给机器配音显示语言名加“生成”。音频不写
    /// `public.translation`：拿不到原声语言，就无法确认配音与原声语言不同。
    private func characteristics(for role: PlaybackAudioTrack.Role) throws -> String {
        switch role {
        case .original: try safeCharacteristics(["public.original-content"])
        case .machineGenerated: try safeCharacteristics(["public.machine-generated"])
        }
    }
}
