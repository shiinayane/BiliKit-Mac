import Foundation

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

    public var httpRangeHeaderValue: String {
        "bytes=\(start)-\(endInclusive)"
    }
}

public enum MediaByteRangeError: Error, Sendable, Equatable {
    case invalidBounds(start: Int64, endInclusive: Int64)
}

public struct SegmentBase: Sendable, Equatable {
    public let initialization: MediaByteRange
    public let index: MediaByteRange

    public init(initialization: MediaByteRange, index: MediaByteRange) {
        self.initialization = initialization
        self.index = index
    }
}

public enum MediaKind: String, Sendable, Equatable {
    case video
    case audio
}

/// 服务端对一条语义音轨给出的静态 BS.1770 响度测量与目标。
///
/// 这里不保存 endpoint 专属的 offset 或场景参数；所有值仍会在播放策略边界再次校验。
public struct PlaybackLoudnessMetadata: Sendable, Equatable {
    public let measuredIntegratedLUFS: Double
    public let measuredLoudnessRangeLU: Double
    public let measuredTruePeakDBTP: Double
    public let measuredThresholdLUFS: Double
    public let targetIntegratedLUFS: Double
    public let targetTruePeakDBTP: Double

    public init(
        measuredIntegratedLUFS: Double,
        measuredLoudnessRangeLU: Double,
        measuredTruePeakDBTP: Double,
        measuredThresholdLUFS: Double,
        targetIntegratedLUFS: Double,
        targetTruePeakDBTP: Double
    ) {
        self.measuredIntegratedLUFS = measuredIntegratedLUFS
        self.measuredLoudnessRangeLU = measuredLoudnessRangeLU
        self.measuredTruePeakDBTP = measuredTruePeakDBTP
        self.measuredThresholdLUFS = measuredThresholdLUFS
        self.targetIntegratedLUFS = targetIntegratedLUFS
        self.targetTruePeakDBTP = targetTruePeakDBTP
    }
}

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

public enum VideoRepresentationAttributesError: Error, Sendable, Equatable {
    case invalidValues(width: Int, height: Int, frameRate: Double?)
}

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
public struct PlaybackAudioTrack: Sendable, Equatable, Identifiable {
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
    public let loudnessMetadata: PlaybackLoudnessMetadata?
    public let representations: [MediaRepresentation]

    public init(
        id: String,
        displayName: String,
        languageTag: String? = nil,
        role: Role,
        isDefault: Bool,
        isAutoselect: Bool,
        loudnessMetadata: PlaybackLoudnessMetadata? = nil,
        representations: [MediaRepresentation]
    ) {
        self.id = id
        self.displayName = displayName
        self.languageTag = languageTag
        self.role = role
        self.isDefault = isDefault
        self.isAutoselect = isAutoselect
        self.loudnessMetadata = loudnessMetadata
        self.representations = representations
    }
}

public struct PlaybackManifest: Sendable, Equatable {
    public let videoRepresentations: [MediaRepresentation]
    public let audioTracks: [PlaybackAudioTrack]

    public init(
        videoRepresentations: [MediaRepresentation],
        audioTracks: [PlaybackAudioTrack]
    ) {
        self.videoRepresentations = videoRepresentations
        self.audioTracks = audioTracks
    }

    /// 把现有 DASH AAC 码率梯度迁移为唯一原声音轨；空输入继续表达缺少可播放音频。
    public init(
        videoRepresentations: [MediaRepresentation],
        originalAudioRepresentations: [MediaRepresentation]
    ) {
        self.videoRepresentations = videoRepresentations
        audioTracks =
            originalAudioRepresentations.isEmpty
            ? []
            : [
                PlaybackAudioTrack(
                    id: "original",
                    displayName: "原声",
                    role: .original,
                    isDefault: true,
                    isAutoselect: true,
                    representations: originalAudioRepresentations
                )
            ]
    }
}

public enum ProgressiveMediaContainer: String, Sendable, Equatable {
    case mp4
}

/// 服务端返回的单文件渐进媒体。
///
/// 候选仍是不可信远端输入，连接前必须再次通过媒体 URL policy。
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
