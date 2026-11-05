import BiliApplication
import BiliModels
import BiliNetworking
import Foundation

/// playurl（`/x/player/wbi/playurl`）的 `data`，由 `BiliAPIClient` 的播放扩展映射为
/// `VideoPlayback`。
///
/// 有 DASH 时只读 DASH，不解码 `durl`、`format` 与 `support_formats`；
/// 配音语言与断点字段异常时按缺失处理，不阻断播放。线路测速另用只解码视频轨的
/// `CDNBenchmarkPlayURLPayload`。
struct PlayURLPayload: Decodable, Sendable {
    /// 没有 DASH 时 AVPlayer 能直接播放的单段 durl 格式。
    ///
    /// `mp4` 与 `hdmp4`（较早视频的 720P 整段）都是 MP4 容器；`flv*` AVPlayer 不支持。
    static let progressiveMP4Formats: Set<String> = ["mp4", "hdmp4"]

    let dash: DASHPayload?
    let durl: DURLPayloadSelection?
    let format: String?
    /// 没有 DASH 时 `support_formats` 列出的 MP4 整段清晰度；当前格式是 FLV 时据此换清晰度重取。
    let progressiveMP4Qualities: [Int]
    let currentLanguage: String?
    let currentProductionType: Int?
    let languageCatalog: AudioLanguageCatalogPayload?
    let lastPlayTime: Int64?
    let lastPlayCID: Int64?

    private enum CodingKeys: String, CodingKey {
        case dash
        case durl
        case format
        case supportFormats = "support_formats"
        case currentLanguage = "cur_language"
        case currentProductionType = "cur_production_type"
        case languageCatalog = "language"
        case lastPlayTime = "last_play_time"
        case lastPlayCID = "last_play_cid"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        dash = try container.decodeIfPresent(DASHPayload.self, forKey: .dash)
        // 有 DASH 时完全保持既有路径，不让未使用的 durl 漂移阻断正常播放。
        durl =
            dash == nil
            ? try container.decodeIfPresent(DURLPayloadSelection.self, forKey: .durl)
            : nil
        format =
            dash == nil
            ? try container.decodeIfPresent(String.self, forKey: .format)
            : nil
        progressiveMP4Qualities =
            dash == nil
            ? ((try? container.decodeIfPresent(
                [LossyDecodable<SupportFormatPayload>].self,
                forKey: .supportFormats
            )) ?? [])
            .compactMap(\.value)
            .filter { Self.progressiveMP4Formats.contains($0.format.lowercased()) }
            .map(\.quality)
            : []
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

    var hasProgressiveMP4Format: Bool {
        format.map { Self.progressiveMP4Formats.contains($0.lowercased()) } ?? false
    }

    /// 上次播放的分 P 与位置（毫秒）；调用方只在请求实际带凭据发出时采用。
    var resumeMetadata: PlaybackResumeMetadata? {
        guard let lastPlayCID, let lastPlayTime else { return nil }
        return PlaybackResumeMetadata(
            lastPlayedCID: lastPlayCID,
            positionMilliseconds: lastPlayTime
        )
    }
}

/// `support_formats` 的一项：清晰度编号与封装格式，只用于找出 MP4 整段清晰度。
struct SupportFormatPayload: Decodable, Sendable {
    let quality: Int
    let format: String
}

/// 没有 DASH 时 `durl` 的形状：空、单段或多段。
///
/// 只支持单段；多段只记形状、不解码其余分段，由调用方映射为不支持的 progressive 媒体。
enum DURLPayloadSelection: Decodable, Sendable {
    case empty
    case single(DURLPayload)
    case multiple

    init(from decoder: any Decoder) throws {
        var container = try decoder.unkeyedContainer()
        if let count = container.count {
            switch count {
            case 0:
                self = .empty
            case 1:
                self = .single(try container.decode(DURLPayload.self))
            default:
                // 多段本轮明确不支持；不要再解码未使用分段，让其中的字段漂移改写稳定错误语义。
                self = .multiple
            }
            return
        }

        guard !container.isAtEnd else {
            self = .empty
            return
        }
        let first = try container.decode(DURLPayload.self)
        self = container.isAtEnd ? .single(first) : .multiple
    }
}

/// 单段 progressive 媒体：时长（毫秒）、字节数与主备地址，映射为 `ProgressivePlaybackSource`。
struct DURLPayload: Decodable, Sendable {
    let length: Int64
    let size: Int64
    /// 主地址与 `backup_url` 在映射时逐个经 `BiliMediaCDNURLPolicy` 复核并去重，不合规的丢弃，
    /// 全部不合规时失败（见 SECURITY-MODEL §4）。
    let url: String?
    let backupURLs: [String]

    private enum CodingKeys: String, CodingKey {
        case length, size, url
        case backupURLs = "backup_url"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        length = try container.decode(Int64.self, forKey: .length)
        size = try container.decode(Int64.self, forKey: .size)
        url = try container.decodeIfPresent(String.self, forKey: .url)
        backupURLs =
            try container.decodeIfPresent(
                [String].self,
                forKey: .backupURLs
            ) ?? []
    }

    func model() throws -> ProgressivePlaybackSource {
        guard length > 0 else {
            throw BiliAPIError.unsupportedProgressiveMedia(.invalidDuration)
        }
        guard size > 0 else {
            throw BiliAPIError.unsupportedProgressiveMedia(.invalidSize)
        }
        var seen = Set<URL>()
        let candidates = ([url].compactMap { $0 } + backupURLs).compactMap {
            raw -> URL? in
            guard let candidate = URL(string: raw),
                BiliMediaCDNURLPolicy().allows(candidate),
                seen.insert(candidate).inserted
            else { return nil }
            return candidate
        }
        guard let primaryURL = candidates.first else {
            throw BiliAPIError.unsupportedProgressiveMedia(.noSafeURL)
        }
        return ProgressivePlaybackSource(
            primaryURL: primaryURL,
            backupURLs: Array(candidates.dropFirst()),
            contentLength: size,
            durationMilliseconds: length,
            contentType: "video/mp4",
            container: .mp4
        )
    }
}

/// playurl 的 `language`：账户可用的 AI 配音语言目录。
///
/// `validatedMachineGeneratedItems` 要求目录声明支持、1–8 项、全部为机器配音（`production_type` 2）、
/// 语言标签与显示名合规且语言不重复；任一项不符整个目录作废，不请求配音。
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

/// 配音目录的一项：语言代码、显示名与制作类型。
///
/// 语言标签与显示名会写进 loopback HLS 清单的 `LANGUAGE`／`NAME` 属性：标签只接受 BCP 47 形状的
/// ASCII，显示名拒绝引号、反斜杠与控制字符并限 128 字节，避免改写清单结构。
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

/// playurl 的 `dash`：视频与音频 representation 列表；视频按 `DASHVideoLadder` 选编码，音频只取 AAC。
///
/// 没有声音的稿件（录屏之类）`audio` 是 `null`。`video` 逐条宽松解码：请求的档位多于能播放的
/// （8K、HDR、AV1），形状不认识的单条只丢这一条，不让整份响应失败。
struct DASHPayload: Decodable, Sendable {
    let video: [DASHRepresentationPayload]
    let audio: [DASHRepresentationPayload]?

    private enum CodingKeys: String, CodingKey {
        case video
        case audio
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        video = try container.decodeLossyElements(
            DASHRepresentationPayload.self,
            forKey: .video
        )
        audio = try container.decodeIfPresent(
            [DASHRepresentationPayload].self,
            forKey: .audio
        )
    }
}

/// DASH 的一路 representation，映射为 `MediaRepresentation`；snake_case 与 camelCase 字段名都接受。
struct DASHRepresentationPayload: Decodable, Sendable {
    let id: Int
    let codecid: Int?
    let codecs: String
    let mimeType: String
    let bandwidth: Int?
    let width: Int?
    let height: Int?
    let frameRate: String?
    /// `base_url` 与 `backup_url` 在映射时逐个经 `BiliMediaCDNURLPolicy` 复核并去重，
    /// 全部不合规时失败（见 SECURITY-MODEL §4）。
    let baseURL: String
    let backupURLs: [String]
    let segmentBase: DASHSegmentBasePayload

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
            BiliMediaCDNURLPolicy().allows(url)
        else {
            return nil
        }
        return url
    }
}

/// DASH 的 `SegmentBase`：init 与 SIDX 的字节区间文本（`起-止`，闭区间），映射为 `SegmentBase`；
/// 形状或区间不合法时失败。
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
