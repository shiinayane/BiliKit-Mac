import BiliApplication
import BiliModels
import Foundation

struct PlayURLPayload: Decodable, Sendable {
    let dash: DASHPayload
}

struct DASHPayload: Decodable, Sendable {
    let video: [DASHRepresentationPayload]
    let audio: [DASHRepresentationPayload]
}

struct DASHRepresentationPayload: Decodable, Sendable {
    let id: Int
    let codecid: Int?
    let codecs: String
    let mimeType: String
    let bandwidth: Int?
    let width: Int?
    let height: Int?
    let frameRate: String?
    let baseURL: String
    let backupURLs: [String]
    let segmentBase: DASHSegmentBasePayload

    var isAVCVideo: Bool {
        mimeType == "video/mp4"
            && (codecid == 7 || codecs.lowercased().hasPrefix("avc1"))
    }

    var isAACAudio: Bool {
        mimeType == "audio/mp4" && codecs.lowercased().hasPrefix("mp4a")
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case codecid
        case codecs
        case mimeType = "mime_type"
        case mimeTypeCamel = "mimeType"
        case bandwidth
        case width
        case height
        case frameRate = "frame_rate"
        case baseURL = "base_url"
        case baseURLCamel = "baseUrl"
        case backupURLs = "backup_url"
        case backupURLsCamel = "backupUrl"
        case segmentBase = "segment_base"
        case segmentBaseCamel = "SegmentBase"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        codecid = try container.decodeIfPresent(Int.self, forKey: .codecid)
        codecs = try container.decode(String.self, forKey: .codecs)
        mimeType =
            try container.decodeIfPresent(String.self, forKey: .mimeType)
            ?? container.decode(String.self, forKey: .mimeTypeCamel)
        bandwidth = try container.decodeIfPresent(Int.self, forKey: .bandwidth)
        width = try container.decodeIfPresent(Int.self, forKey: .width)
        height = try container.decodeIfPresent(Int.self, forKey: .height)
        frameRate = try container.decodeIfPresent(String.self, forKey: .frameRate)
        baseURL =
            try container.decodeIfPresent(String.self, forKey: .baseURL)
            ?? container.decode(String.self, forKey: .baseURLCamel)
        backupURLs =
            try container.decodeIfPresent(
                [String].self,
                forKey: .backupURLs
            ) ?? container.decodeIfPresent(
                [String].self,
                forKey: .backupURLsCamel
            ) ?? []
        segmentBase =
            try container.decodeIfPresent(
                DASHSegmentBasePayload.self,
                forKey: .segmentBase
            ) ?? container.decode(DASHSegmentBasePayload.self, forKey: .segmentBaseCamel)
    }

    func model(kind: MediaKind) throws -> MediaRepresentation {
        var seen = Set<URL>()
        let urls = ([baseURL] + backupURLs)
            .compactMap(Self.validMediaURL)
            .filter { seen.insert($0).inserted }
        guard let primaryURL = urls.first else {
            throw BiliAPIError.invalidMediaData
        }
        let videoAttributes: VideoRepresentationAttributes?
        switch kind {
        case .video:
            guard let width,
                let height,
                let frameRate = Self.videoFrameRate(from: frameRate),
                let attributes = try? VideoRepresentationAttributes(
                    width: width,
                    height: height,
                    frameRate: frameRate
                )
            else {
                throw BiliAPIError.invalidMediaData
            }
            videoAttributes = attributes
        case .audio:
            videoAttributes = nil
        }
        return MediaRepresentation(
            id: id,
            kind: kind,
            codecs: codecs,
            mimeType: mimeType,
            bandwidth: bandwidth,
            videoAttributes: videoAttributes,
            primaryURL: primaryURL,
            backupURLs: Array(urls.dropFirst()),
            segmentBase: try segmentBase.model()
        )
    }

    private static func videoFrameRate(from value: String?) -> Double? {
        guard let value, !value.isEmpty else { return nil }
        let components = value.split(
            separator: "/",
            omittingEmptySubsequences: false
        )
        if components.count == 1 {
            return Double(components[0])
        }
        guard components.count == 2,
            let numerator = Double(components[0]),
            let denominator = Double(components[1]),
            denominator != 0
        else {
            return nil
        }
        return numerator / denominator
    }

    private static func validMediaURL(_ value: String) -> URL? {
        guard let url = URL(string: value),
            BiliMediaURLPolicy().allows(url)
        else {
            return nil
        }
        return url
    }
}

struct DASHSegmentBasePayload: Decodable, Sendable {
    let initialization: String
    let indexRange: String

    private enum CodingKeys: String, CodingKey {
        case initialization
        case indexRange = "index_range"
        case indexRangeCamel = "indexRange"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        initialization = try container.decode(String.self, forKey: .initialization)
        indexRange =
            try container.decodeIfPresent(String.self, forKey: .indexRange)
            ?? container.decode(String.self, forKey: .indexRangeCamel)
    }

    func model() throws -> SegmentBase {
        do {
            return SegmentBase(
                initialization: try byteRange(initialization),
                index: try byteRange(indexRange)
            )
        } catch {
            throw BiliAPIError.invalidMediaData
        }
    }

    private func byteRange(_ value: String) throws -> MediaByteRange {
        let bounds = value.split(
            separator: "-",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        guard bounds.count == 2,
            let start = Int64(bounds[0]),
            let end = Int64(bounds[1])
        else {
            throw BiliAPIError.invalidMediaData
        }
        return try MediaByteRange(start: start, endInclusive: end)
    }
}
