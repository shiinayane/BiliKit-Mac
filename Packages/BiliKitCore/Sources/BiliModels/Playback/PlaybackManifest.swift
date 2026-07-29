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

public struct PlaybackManifest: Sendable, Equatable {
    public let videoRepresentations: [MediaRepresentation]
    public let audioRepresentations: [MediaRepresentation]

    public init(
        videoRepresentations: [MediaRepresentation],
        audioRepresentations: [MediaRepresentation]
    ) {
        self.videoRepresentations = videoRepresentations
        self.audioRepresentations = audioRepresentations
    }
}
