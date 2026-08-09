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

public struct VideoRepresentationAttributes: Sendable, Equatable {
    public let width: Int
    public let height: Int
    public let frameRate: Double

    public init(
        width: Int,
        height: Int,
        frameRate: Double
    ) throws {
        guard width > 0,
            height > 0,
            frameRate.isFinite,
            frameRate > 0
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
    case invalidValues(width: Int, height: Int, frameRate: Double)
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
