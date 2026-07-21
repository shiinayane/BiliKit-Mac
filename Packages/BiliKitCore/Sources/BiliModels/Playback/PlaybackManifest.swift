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

public struct MediaRepresentation: Sendable, Equatable {
    public let id: Int
    public let kind: MediaKind
    public let codecs: String
    public let mimeType: String
    public let bandwidth: Int?
    public let primaryURL: URL
    public let backupURLs: [URL]
    public let segmentBase: SegmentBase

    public init(
        id: Int,
        kind: MediaKind,
        codecs: String,
        mimeType: String,
        bandwidth: Int? = nil,
        primaryURL: URL,
        backupURLs: [URL] = [],
        segmentBase: SegmentBase
    ) {
        self.id = id
        self.kind = kind
        self.codecs = codecs
        self.mimeType = mimeType
        self.bandwidth = bandwidth
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
