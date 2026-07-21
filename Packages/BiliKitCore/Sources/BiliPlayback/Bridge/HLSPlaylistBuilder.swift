import BiliModels
import Foundation

public enum HLSPlaylistBuilderError: Error, Sendable, Equatable {
    case noMediaSegments
    case invalidTimescale
    case invalidMediaKind(expected: MediaKind, actual: MediaKind)
    case missingBandwidth(representationID: Int)
    case invalidBandwidth(representationID: Int)
    case bandwidthOverflow
    case unsafeAttributeValue
    case unsafeURI
}

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
        let maximumDuration = index.references
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

public struct HLSMasterPlaylistBuilder: Sendable {
    public init() {}

    public func build(
        video: MediaRepresentation,
        videoPlaylistURI: URL,
        audio: MediaRepresentation,
        audioPlaylistURI: URL
    ) throws -> String {
        guard video.kind == .video else {
            throw HLSPlaylistBuilderError.invalidMediaKind(
                expected: .video,
                actual: video.kind
            )
        }
        guard audio.kind == .audio else {
            throw HLSPlaylistBuilderError.invalidMediaKind(
                expected: .audio,
                actual: audio.kind
            )
        }

        let videoBandwidth = try bandwidth(for: video)
        let audioBandwidth = try bandwidth(for: audio)
        let (combinedBandwidth, overflow) = videoBandwidth.addingReportingOverflow(
            audioBandwidth
        )
        guard !overflow else {
            throw HLSPlaylistBuilderError.bandwidthOverflow
        }

        let videoURI = try safeURI(videoPlaylistURI)
        let audioURI = try safeURI(audioPlaylistURI)
        let videoCodecs = try safeAttribute(video.codecs)
        let audioCodecs = try safeAttribute(audio.codecs)
        let audioGroupID = "audio-\(audio.id)"

        return [
            "#EXTM3U",
            "#EXT-X-VERSION:7",
            "#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"\(audioGroupID)\",NAME=\"Audio \(audio.id)\",DEFAULT=YES,AUTOSELECT=YES,URI=\"\(audioURI)\"",
            "#EXT-X-STREAM-INF:BANDWIDTH=\(combinedBandwidth),CODECS=\"\(videoCodecs),\(audioCodecs)\",AUDIO=\"\(audioGroupID)\"",
            videoURI,
        ].joined(separator: "\n") + "\n"
    }

    private func bandwidth(for representation: MediaRepresentation) throws -> Int {
        guard let bandwidth = representation.bandwidth else {
            throw HLSPlaylistBuilderError.missingBandwidth(
                representationID: representation.id
            )
        }
        guard bandwidth > 0 else {
            throw HLSPlaylistBuilderError.invalidBandwidth(
                representationID: representation.id
            )
        }
        return bandwidth
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
