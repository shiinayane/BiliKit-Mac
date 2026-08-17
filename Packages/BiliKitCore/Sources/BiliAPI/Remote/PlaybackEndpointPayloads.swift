import BiliApplication
import BiliModels
import Foundation

struct PlayURLPayload: Decodable, Sendable {
    let dash: DASHPayload
    let currentLanguage: String?
    let currentProductionType: Int?
    let languageCatalog: AudioLanguageCatalogPayload?
    let lastPlayTime: Int64?
    let lastPlayCID: Int64?

    private enum CodingKeys: String, CodingKey {
        case dash
        case currentLanguage = "cur_language"
        case currentProductionType = "cur_production_type"
        case languageCatalog = "language"
        case lastPlayTime = "last_play_time"
        case lastPlayCID = "last_play_cid"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        dash = try container.decode(DASHPayload.self, forKey: .dash)
        currentLanguage = try? container.decode(
            String.self,
            forKey: .currentLanguage
        )
        currentProductionType = try? container.decode(
            Int.self,
            forKey: .currentProductionType
        )
        languageCatalog = try? container.decode(
            AudioLanguageCatalogPayload.self,
            forKey: .languageCatalog
        )
        lastPlayTime = try? container.decode(Int64.self, forKey: .lastPlayTime)
        lastPlayCID = try? container.decode(Int64.self, forKey: .lastPlayCID)
    }

    var resumeMetadata: PlaybackResumeMetadata? {
        guard let lastPlayCID, let lastPlayTime else { return nil }
        return PlaybackResumeMetadata(
            lastPlayedCID: lastPlayCID,
            positionMilliseconds: lastPlayTime
        )
    }
}

struct AudioLanguageCatalogPayload: Decodable, Sendable {
    let support: Bool
    let items: [AudioLanguageItemPayload]

    func validatedMachineGeneratedItems() -> [AudioLanguageItemPayload] {
        guard support, (1...8).contains(items.count) else { return [] }
        var languages = Set<String>()
        for item in items {
            guard item.productionType == 2,
                let languageTag = item.validatedLanguageTag,
                item.validatedDisplayName != nil,
                languages.insert(languageTag).inserted
            else {
                return []
            }
        }
        return items
    }
}

struct AudioLanguageItemPayload: Decodable, Sendable {
    let languageCode: String
    let title: String
    let productionType: Int

    var validatedLanguageTag: String? {
        let value = languageCode.replacingOccurrences(of: "_", with: "-")
        let subtags = value.split(
            separator: "-",
            omittingEmptySubsequences: false
        )
        guard value.count <= 35, let primary = subtags.first,
            (2...3).contains(primary.count),
            primary.allSatisfy({
                $0.isASCII && $0.isLetter && $0.isLowercase
            }),
            subtags.dropFirst().allSatisfy({ subtag in
                (1...8).contains(subtag.count)
                    && subtag.allSatisfy {
                        $0.isASCII && ($0.isLetter || $0.isNumber)
                    }
            })
        else {
            return nil
        }
        return subtags.joined(separator: "-")
    }

    var validatedDisplayName: String? {
        let value = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.count <= 128,
            !value.contains("\""),
            !value.contains("\\"),
            !value.unicodeScalars.contains(where: {
                CharacterSet.controlCharacters.contains($0)
            })
        else {
            return nil
        }
        return value
    }

    private enum CodingKeys: String, CodingKey {
        case languageCode = "lang"
        case title
        case productionType = "production_type"
    }
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
                let attributes = try? VideoRepresentationAttributes(
                    width: width,
                    height: height,
                    frameRate: BiliFrameRateNormalizer.normalizedValue(
                        from: frameRate
                    )
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
