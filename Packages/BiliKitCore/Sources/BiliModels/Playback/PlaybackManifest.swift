import Foundation

/// 媒体文件里的闭区间字节范围，用于 HTTP Range 请求与 HLS byte-range。
///
/// 构造时拒绝负起点与终点小于起点的区间，保证它总能写成合法的单段 Range。
public struct MediaByteRange: Sendable, Equatable {
    public let start: Int64
    public let endInclusive: Int64

    public init(start: Int64, endInclusive: Int64) throws {
        guard start >= 0, endInclusive >= start else {
            throw MediaByteRangeError.invalidBounds(
                start: start,
                endInclusive: endInclusive
            )
        }

        self.start = start
        self.endInclusive = endInclusive
    }
}

/// `MediaByteRange` 构造时区间不合法；BiliAPI 映射把它归为媒体数据无效。
public enum MediaByteRangeError: Error, Sendable, Equatable {
    case invalidBounds(start: Int64, endInclusive: Int64)
}

/// DASH `SegmentBase`：初始化段与 SIDX 索引在同一媒体文件中的字节范围，由 playurl 映射产生。
///
/// 播放桥按 `index` 读取 SIDX 生成 HLS 分段，按 `initialization` 生成 init 段。
public struct SegmentBase: Sendable, Equatable {
    public let initialization: MediaByteRange
    public let index: MediaByteRange

    public init(initialization: MediaByteRange, index: MediaByteRange) {
        self.initialization = initialization
        self.index = index
    }
}

/// 一条媒体表示是视频还是音频；BiliAPI 映射时只对视频要求尺寸属性。
public enum MediaKind: String, Sendable, Equatable {
    case video
    case audio
}

/// 视频表示的尺寸与帧率；构造时拒绝非正宽高和非有限或非正的帧率，帧率缺失时为 nil。
///
/// BiliAPI 映射时视频表示必须带合法属性，否则整份媒体数据无效。
public struct VideoRepresentationAttributes: Sendable, Equatable {
    public let width: Int
    public let height: Int
    public let frameRate: Double?

    public init(
        width: Int,
        height: Int,
        frameRate: Double?
    ) throws {
        guard width > 0,
            height > 0,
            frameRate?.isFinite != false,
            frameRate.map({ $0 > 0 }) != false
        else {
            throw VideoRepresentationAttributesError.invalidValues(
                width: width,
                height: height,
                frameRate: frameRate
            )
        }

        self.width = width
        self.height = height
        self.frameRate = frameRate
    }
}

/// `VideoRepresentationAttributes` 构造时数值不合法。
public enum VideoRepresentationAttributesError: Error, Sendable, Equatable {
    case invalidValues(width: Int, height: Int, frameRate: Double?)
}

/// DASH 里的一条视频或音频表示，由 BiliAPI 的 `DASHRepresentationPayload` 映射产生，
/// 播放桥与线路测速消费。
///
/// `primaryURL` 与 `backupURLs` 映射时都已通过 `BiliMediaCDNURLPolicy` 并去重；线路偏好可能重排或
/// 改写候选，所以播放桥读取 SIDX 前与 loopback 资源构造时仍会再查（见 SECURITY-MODEL §4）。
public struct MediaRepresentation: Sendable, Equatable {
    public let id: Int
    public let kind: MediaKind
    public let codecs: String
    public let mimeType: String
    public let bandwidth: Int?
    public let videoAttributes: VideoRepresentationAttributes?
    public let primaryURL: URL
    public let backupURLs: [URL]
    public let segmentBase: SegmentBase

    public init(
        id: Int,
        kind: MediaKind,
        codecs: String,
        mimeType: String,
        bandwidth: Int? = nil,
        videoAttributes: VideoRepresentationAttributes? = nil,
        primaryURL: URL,
        backupURLs: [URL] = [],
        segmentBase: SegmentBase
    ) {
        self.id = id
        self.kind = kind
        self.codecs = codecs
        self.mimeType = mimeType
        self.bandwidth = bandwidth
        self.videoAttributes = videoAttributes
        self.primaryURL = primaryURL
        self.backupURLs = backupURLs
        self.segmentBase = segmentBase
    }

    public var urlCandidates: [URL] {
        [primaryURL] + backupURLs
    }
}

/// 用户可选择的一条语义音轨；`representations` 是同一声音内容的媒体候选，而不是独立音轨。
///
/// 候选保持 playurl 返回的顺序，不代表码率高低；BiliPlayback 加载时每轨只取码率最高的一条。
public struct PlaybackAudioTrack: Sendable, Equatable, Identifiable {
    /// 音轨来源：`original` 为原声，`machineGenerated` 为 AI 配音。
    ///
    /// 播放桥要求原声同时是默认与自动选择，AI 配音不是默认且带语言标记，否则拒绝选中的音轨。
    /// AI 配音也不是自动选择，只在用户明确选中时播放。
    public enum Role: Sendable, Equatable {
        case original
        case machineGenerated
    }

    public let id: String
    public let displayName: String
    public let languageTag: String?
    public let role: Role
    public let isDefault: Bool
    public let isAutoselect: Bool
    public let representations: [MediaRepresentation]

    public init(
        id: String,
        displayName: String,
        languageTag: String? = nil,
        role: Role,
        isDefault: Bool,
        isAutoselect: Bool,
        representations: [MediaRepresentation]
    ) {
        self.id = id
        self.displayName = displayName
        self.languageTag = languageTag
        self.role = role
        self.isDefault = isDefault
        self.isAutoselect = isAutoselect
        self.representations = representations
    }

    /// 默认原声音轨的显示名；AI 配音的显示名不得与它重复。
    public static let originalDisplayName = "原声"

    /// 默认原声音轨的唯一构造处，BiliAPI 的 playurl 映射经它组装清单。
    ///
    /// 原声同时是默认与自动选择、不带语言标记，满足播放桥对原声音轨的要求。B 站不提供可验证的原声
    /// 语言，写成 HLS 时省略 LANGUAGE，系统菜单的名字来自播放桥提供的本地化显示名。
    public static func original(
        representations: [MediaRepresentation]
    ) -> PlaybackAudioTrack {
        PlaybackAudioTrack(
            id: "original",
            displayName: originalDisplayName,
            role: .original,
            isDefault: true,
            isAutoselect: true,
            representations: representations
        )
    }
}

/// DASH 播放所需的视频表示与语义音轨，由 `BiliAPIClient` 的 playurl 映射组装，`DASHToHLSBridge`
/// 消费。
///
/// 视频阶梯只用一种编码（HEVC 或 AVC，规则见 BiliAPI 的 `DASHVideoLadder`），非空才组装；音频只保留
/// AAC，有音轨时首条是默认原声，已认证时可追加 AI 配音音轨。没有声音的稿件 `audioTracks` 为空，只播视频。
public struct PlaybackManifest: Sendable, Equatable {
    public let videoRepresentations: [MediaRepresentation]
    /// 主阶梯起播失败时 BiliPlayback 换用的同一份 playurl 的 AVC 阶梯，只换一次；主阶梯已是 AVC 时为空。
    public let fallbackVideoRepresentations: [MediaRepresentation]
    public let audioTracks: [PlaybackAudioTrack]

    public init(
        videoRepresentations: [MediaRepresentation],
        fallbackVideoRepresentations: [MediaRepresentation] = [],
        audioTracks: [PlaybackAudioTrack]
    ) {
        self.videoRepresentations = videoRepresentations
        self.fallbackVideoRepresentations = fallbackVideoRepresentations
        self.audioTracks = audioTracks
    }
}

/// 渐进媒体的容器格式；目前只接受 MP4。
public enum ProgressiveMediaContainer: String, Sendable, Equatable {
    case mp4
}

/// 服务端返回的单文件渐进媒体，由 BiliAPI 的 `DURLPayload` 映射产生。
///
/// 映射时候选已通过 `BiliMediaCDNURLPolicy` 并去重，长度与时长只接受正数；
/// 连接前播放桥仍须再次检查来源（见 SECURITY-MODEL §4）。
public struct ProgressivePlaybackSource: Sendable, Equatable {
    public let primaryURL: URL
    public let backupURLs: [URL]
    public let contentLength: Int64
    public let durationMilliseconds: Int64
    public let contentType: String
    public let container: ProgressiveMediaContainer

    public init(
        primaryURL: URL,
        backupURLs: [URL] = [],
        contentLength: Int64,
        durationMilliseconds: Int64,
        contentType: String,
        container: ProgressiveMediaContainer
    ) {
        self.primaryURL = primaryURL
        self.backupURLs = backupURLs
        self.contentLength = contentLength
        self.durationMilliseconds = durationMilliseconds
        self.contentType = contentType
        self.container = container
    }

    public var urlCandidates: [URL] {
        [primaryURL] + backupURLs
    }
}

/// 一次播放只可能持有一种合法媒体，避免空 DASH、双来源或无来源状态。
public enum PlaybackMedia: Sendable, Equatable {
    case dash(PlaybackManifest)
    case progressive(ProgressivePlaybackSource)
}
