import BiliApplication
import BiliModels
import Foundation

struct PopularPayload: Decodable, Sendable {
    let list: [PopularVideoPayload]
    let noMore: Bool

    private enum CodingKeys: String, CodingKey {
        case list
        case noMore = "no_more"
    }
}

struct PopularVideoPayload: Decodable, Sendable {
    let bvid: String
    let title: String
    let pic: String
    let owner: OwnerPayload
    let stat: StatisticsPayload
    let duration: Int
    let pubdate: Int64

    func model() throws -> PopularVideo {
        guard bvid.hasPrefix("BV"), !title.isEmpty, duration >= 0, pubdate >= 0 else {
            throw BiliAPIError.decodingFailed
        }
        return PopularVideo(
            bvid: bvid,
            title: title,
            coverURL: WebImageURL.parse(pic),
            owner: owner.model(),
            statistics: stat.model(),
            durationSeconds: duration,
            publishedAt: Date(timeIntervalSince1970: TimeInterval(pubdate))
        )
    }
}

struct RelatedVideoPayload: Decodable, Sendable {
    let bvid: String?
    let title: String?
    let pic: String?
    let owner: RelatedVideoOwnerPayload?
    let stat: RelatedVideoStatisticsPayload?
    let duration: Int?

    func model() throws -> RelatedVideo {
        guard let bvid,
            let title,
            let owner,
            let stat,
            bvid.hasPrefix("BV"),
            bvid.count == 12,
            !title.isEmpty,
            !owner.name.isEmpty,
            stat.view >= 0,
            stat.danmaku >= 0,
            duration.map({ $0 >= 0 }) ?? true
        else {
            throw BiliAPIError.decodingFailed
        }
        return RelatedVideo(
            bvid: bvid,
            title: title,
            coverURL: pic.flatMap(WebImageURL.parse),
            ownerName: owner.name,
            viewCount: stat.view,
            danmakuCount: stat.danmaku,
            durationSeconds: duration
        )
    }
}

struct RelatedVideoOwnerPayload: Decodable, Sendable {
    let name: String
}

struct RelatedVideoStatisticsPayload: Decodable, Sendable {
    let view: Int64
    let danmaku: Int64
}

struct OwnerPayload: Decodable, Sendable {
    let mid: Int64
    let name: String
    let face: String?

    func model() -> VideoOwner {
        VideoOwner(
            id: mid,
            name: name,
            avatarURL: face.flatMap(WebImageURL.parse)
        )
    }
}

struct UploaderCardDataPayload: Decodable, Sendable {
    let card: UploaderCardPayload
}

struct UploaderCardPayload: Decodable, Sendable {
    let mid: Int64
    let sign: String

    private enum CodingKeys: String, CodingKey {
        case mid
        case sign
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let numericMID = try? container.decode(Int64.self, forKey: .mid) {
            mid = numericMID
        } else {
            let stringMID = try container.decode(String.self, forKey: .mid)
            guard let numericMID = Int64(stringMID) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .mid,
                    in: container,
                    debugDescription: "Uploader MID is not an integer"
                )
            }
            mid = numericMID
        }
        sign = try container.decode(String.self, forKey: .sign)
    }
}

struct StatisticsPayload: Decodable, Sendable {
    let view: Int64
    let danmaku: Int64
    let like: Int64

    func model() -> VideoStatistics {
        VideoStatistics(viewCount: view, danmakuCount: danmaku, likeCount: like)
    }
}

struct VideoDetailPayload: Decodable, Sendable {
    let aid: Int64?
    let bvid: String
    let title: String
    let desc: String
    let pic: String
    let owner: OwnerPayload
    let stat: StatisticsPayload
    let duration: Int
    let pubdate: Int64
    let dimension: DimensionPayload?
    let pages: [PagePayload]?
    let ugcSeason: UGCSeasonPayload?

    private enum CodingKeys: String, CodingKey {
        case aid, bvid, title, desc, pic, owner, stat, duration, pubdate, dimension, pages
        case ugcSeason = "ugc_season"
    }

    func model() throws -> VideoDetail {
        guard aid.map({ $0 > 0 }) ?? true,
            bvid.hasPrefix("BV"),
            !title.isEmpty,
            duration >= 0,
            pubdate >= 0
        else {
            throw BiliAPIError.decodingFailed
        }
        let resolvedPages = try validatedPageModels(pages ?? [])
        return VideoDetail(
            bvid: bvid,
            title: title,
            summary: desc,
            coverURL: WebImageURL.parse(pic),
            owner: owner.model(),
            statistics: stat.model(),
            durationSeconds: duration,
            publishedAt: Date(timeIntervalSince1970: TimeInterval(pubdate)),
            dimension: dimension?.model(),
            aid: aid,
            pages: resolvedPages,
            collection: ugcSeason?.model()
        )
    }
}

struct PagePayload: Decodable, Sendable {
    let cid: Int64
    let page: Int
    let part: String
    let duration: Int
    let dimension: DimensionPayload?

    func model() throws -> VideoPage {
        guard cid > 0, page > 0, !part.isEmpty, duration >= 0 else {
            throw BiliAPIError.decodingFailed
        }
        return VideoPage(
            cid: cid,
            index: page,
            title: part,
            durationSeconds: duration,
            dimension: dimension?.model()
        )
    }
}

struct UGCSeasonPayload: Decodable, Sendable {
    let id: Int64?
    let title: String?
    let epCount: Int?
    let sections: [UGCSeasonSectionPayload]?

    private enum CodingKeys: String, CodingKey {
        case id, title, sections
        case epCount = "ep_count"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try? container.decodeIfPresent(Int64.self, forKey: .id)
        title = try? container.decodeIfPresent(String.self, forKey: .title)
        epCount = try? container.decodeIfPresent(Int.self, forKey: .epCount)
        sections = try? container.decodeIfPresent([UGCSeasonSectionPayload].self, forKey: .sections)
    }

    func model() -> VideoCollection? {
        guard let id,
            id > 0,
            let title,
            !title.isEmpty,
            epCount.map({ $0 >= 0 }) ?? true
        else {
            return nil
        }
        let resolvedSections = sections ?? []
        let sectionIDCounts = Dictionary(grouping: resolvedSections, by: \.resolvedID)
            .mapValues(\.count)
        return VideoCollection(
            id: id,
            title: title,
            reportedEpisodeCount: epCount,
            sections: resolvedSections.enumerated().map { ordinal, section in
                section.model(
                    seasonID: id,
                    ordinal: ordinal,
                    needsOccurrenceIdentity: sectionIDCounts[section.resolvedID, default: 0] > 1
                )
            }
        )
    }
}

struct UGCSeasonSectionPayload: Decodable, Sendable {
    let id: Int64?
    let sectionIDAlias: Int64?
    let seasonID: Int64?
    let title: String?
    let episodes: [UGCSeasonEpisodePayload]?

    private enum CodingKeys: String, CodingKey {
        case id, title, episodes
        case sectionIDAlias = "section_id"
        case seasonID = "season_id"
    }

    var resolvedID: Int64? { id ?? sectionIDAlias }

    init(from decoder: any Decoder) throws {
        guard let container = try? decoder.container(keyedBy: CodingKeys.self) else {
            id = nil
            seasonID = nil
            sectionIDAlias = nil
            title = nil
            episodes = nil
            return
        }
        id = try? container.decodeIfPresent(Int64.self, forKey: .id)
        seasonID = try? container.decodeIfPresent(Int64.self, forKey: .seasonID)
        sectionIDAlias = try? container.decodeIfPresent(Int64.self, forKey: .sectionIDAlias)
        title = try? container.decodeIfPresent(String.self, forKey: .title)
        episodes = try? container.decodeIfPresent([UGCSeasonEpisodePayload].self, forKey: .episodes)
    }

    func model(
        seasonID expectedSeasonID: Int64,
        ordinal: Int,
        needsOccurrenceIdentity: Bool
    ) -> VideoCollectionSection {
        let sectionIDFieldsAreConsistent =
            id == nil || sectionIDAlias == nil || id == sectionIDAlias
        let resolvedID = resolvedID ?? 0
        let identityIsConsistent =
            resolvedID > 0
            && sectionIDFieldsAreConsistent
            && (seasonID.map { $0 == expectedSeasonID } ?? true)
        let resolvedEpisodes = episodes ?? []
        let episodeIDCounts = Dictionary(
            grouping: resolvedEpisodes.compactMap(\.id),
            by: { $0 }
        ).mapValues(\.count)
        return VideoCollectionSection(
            id: VideoCollectionSectionIdentity(
                seasonID: expectedSeasonID,
                sectionID: resolvedID,
                occurrenceOrdinal: needsOccurrenceIdentity ? ordinal : nil
            ),
            ordinal: ordinal,
            title: title ?? "",
            episodes: resolvedEpisodes.enumerated().map { episodeOrdinal, episode in
                episode.model(
                    seasonID: expectedSeasonID,
                    sectionID: resolvedID,
                    sectionOccurrenceOrdinal: needsOccurrenceIdentity ? ordinal : nil,
                    ordinal: episodeOrdinal,
                    parentIdentityIsConsistent: identityIsConsistent,
                    needsOccurrenceIdentity: episode.id == nil
                        || episodeIDCounts[episode.id ?? 0, default: 0] > 1
                )
            },
            isIdentityConsistent: identityIsConsistent
        )
    }
}

struct UGCSeasonEpisodePayload: Decodable, Sendable {
    let id: Int64?
    let seasonID: Int64?
    let sectionID: Int64?
    let aid: Int64?
    let bvid: String?
    let cid: Int64?
    let title: String?
    let arc: UGCSeasonEpisodeArcPayload?
    let page: PagePayload?
    let pages: [PagePayload]?

    private enum CodingKeys: String, CodingKey {
        case id, aid, bvid, cid, title, arc, page, pages
        case seasonID = "season_id"
        case sectionID = "section_id"
    }

    init(from decoder: any Decoder) throws {
        guard let container = try? decoder.container(keyedBy: CodingKeys.self) else {
            id = nil
            seasonID = nil
            sectionID = nil
            aid = nil
            bvid = nil
            cid = nil
            title = nil
            arc = nil
            page = nil
            pages = nil
            return
        }
        id = try? container.decodeIfPresent(Int64.self, forKey: .id)
        seasonID = try? container.decodeIfPresent(Int64.self, forKey: .seasonID)
        sectionID = try? container.decodeIfPresent(Int64.self, forKey: .sectionID)
        aid = try? container.decodeIfPresent(Int64.self, forKey: .aid)
        bvid = try? container.decodeIfPresent(String.self, forKey: .bvid)
        cid = try? container.decodeIfPresent(Int64.self, forKey: .cid)
        title = try? container.decodeIfPresent(String.self, forKey: .title)
        arc = try? container.decodeIfPresent(UGCSeasonEpisodeArcPayload.self, forKey: .arc)
        page = try? container.decodeIfPresent(PagePayload.self, forKey: .page)
        pages = try? container.decodeIfPresent([PagePayload].self, forKey: .pages)
    }

    func model(
        seasonID expectedSeasonID: Int64,
        sectionID expectedSectionID: Int64,
        sectionOccurrenceOrdinal: Int?,
        ordinal: Int,
        parentIdentityIsConsistent: Bool,
        needsOccurrenceIdentity: Bool
    ) -> VideoCollectionEpisode {
        let aidIsConsistent = aid == nil || arc?.aid == nil || aid == arc?.aid
        let bvidIsConsistent = bvid == nil || arc?.bvid == nil || bvid == arc?.bvid
        let resolvedAID = aidIsConsistent ? (aid ?? arc?.aid) : nil
        let resolvedBVID = bvidIsConsistent ? (bvid ?? arc?.bvid) : nil
        let resolvedTitle = title ?? arc?.title ?? ""
        let resolvedPage = page.flatMap { try? $0.model() }
        let knownPages = pages.flatMap { try? validatedPageModels($0) }
        let pageDataIsValid = page == nil || resolvedPage != nil
        let pagesDataIsValid = pages == nil || knownPages != nil
        let candidateCID = cid ?? resolvedPage?.cid ?? knownPages?.first?.cid
        let cidIsConsistent =
            (cid == nil || resolvedPage?.cid == nil || cid == resolvedPage?.cid)
            && (knownPages.map { pages in
                guard let candidateCID else { return true }
                return pages.contains(where: { $0.cid == candidateCID })
            } ?? true)
        let identityIsConsistent =
            parentIdentityIsConsistent
            && (id.map { $0 > 0 } ?? true)
            && (seasonID.map { $0 == expectedSeasonID } ?? true)
            && (sectionID.map { $0 == expectedSectionID } ?? true)
            && aidIsConsistent
            && bvidIsConsistent
            && (resolvedAID.map { $0 > 0 } ?? true)
            && (resolvedBVID.map { $0.hasPrefix("BV") && $0.count == 12 } ?? true)
            && !resolvedTitle.isEmpty
            && (cid.map { $0 > 0 } ?? true)
            && pageDataIsValid
            && pagesDataIsValid
            && cidIsConsistent
            && (arc?.duration.map { $0 >= 0 } ?? true)
        return VideoCollectionEpisode(
            id: VideoCollectionEpisodeIdentity(
                seasonID: expectedSeasonID,
                sectionID: expectedSectionID,
                sectionOccurrenceOrdinal: sectionOccurrenceOrdinal,
                episodeID: id,
                occurrenceOrdinal: needsOccurrenceIdentity ? ordinal : nil
            ),
            ordinal: ordinal,
            aid: resolvedAID,
            bvid: resolvedBVID,
            title: resolvedTitle,
            coverURL: arc?.pic.flatMap(WebImageURL.parse),
            durationSeconds: arc?.duration,
            defaultCID: cidIsConsistent ? candidateCID : nil,
            knownPages: knownPages,
            isIdentityConsistent: identityIsConsistent
        )
    }
}

struct UGCSeasonEpisodeArcPayload: Decodable, Sendable {
    let aid: Int64?
    let bvid: String?
    let title: String?
    let pic: String?
    let duration: Int?
}

func validatedPageModels(_ payloads: [PagePayload]) throws -> [VideoPage] {
    let pages = try payloads.map { try $0.model() }
    guard Set(pages.map(\.cid)).count == pages.count,
        Set(pages.map(\.index)).count == pages.count
    else {
        throw BiliAPIError.decodingFailed
    }
    return pages.sorted(by: { $0.index < $1.index })
}

struct DimensionPayload: Decodable, Sendable {
    let width: Int
    let height: Int
    let rotate: Int

    func model() -> VideoDimension {
        VideoDimension(width: width, height: height, rotation: rotate)
    }
}
