import BiliApplication
import BiliModels
import Foundation

/// 在合集里找出当前播放对应的选集：显式选择优先，否则按 BVID 与 CID 唯一匹配，有歧义时返回 nil。
///
/// CID 依次对默认分 P、已知分 P 匹配；都没有命中时，只有该 BVID 唯一的候选且它既无默认 CID、
/// 也无已知分 P（无法判断不匹配）才返回它。
enum PlaybackCollectionEpisodeResolver {
    static func resolve(
        episodes: [VideoCollectionEpisode],
        explicitlySelectedID: VideoCollectionEpisodeIdentity?,
        bvid: String,
        cid: Int64?
    ) -> VideoCollectionEpisode? {
        let eligibleEpisodes = episodes.filter(\.isPlayableSelection)
        if let explicitlySelectedID,
            let explicit = eligibleEpisodes.first(where: {
                $0.id == explicitlySelectedID
            })
        {
            return explicit
        }
        let candidates = eligibleEpisodes.filter { $0.bvid == bvid }
        guard let cid else {
            return candidates.count == 1 ? candidates[0] : nil
        }
        let defaultCIDMatches = candidates.filter { $0.defaultCID == cid }
        if defaultCIDMatches.count == 1 {
            return defaultCIDMatches[0]
        }
        guard defaultCIDMatches.isEmpty else { return nil }
        let knownPageMatches = candidates.filter {
            $0.knownPages?.contains(where: { $0.cid == cid }) == true
        }
        if knownPageMatches.count == 1 {
            return knownPageMatches[0]
        }
        guard knownPageMatches.isEmpty,
            candidates.count == 1,
            candidates[0].defaultCID == nil,
            candidates[0].knownPages == nil
        else { return nil }
        return candidates[0]
    }
}

extension VideoCollectionEpisode {
    /// 能作为播放目标的选集：身份一致、有 BV 号、分 P 不是已知为空。
    ///
    /// 合集横排里这一集能否点、认出当前是哪一集与连播的下一集都按它判断。
    var isPlayableSelection: Bool {
        isIdentityConsistent && bvid?.isEmpty == false && knownPages != []
    }

    /// 合集横排卡片与连播提示里的标题；接口没给标题时用“无法识别的选集”。
    var displayTitle: String {
        title.isEmpty ? VideoDetailFeatureStrings.localized("无法识别的选集") : title
    }
}

extension VideoPage {
    /// 分 P 在分 P 菜单与连播提示里的名字：「P1 · 标题」，标题为空时只有「P1」。
    static func displayLabel(index: Int, title: String) -> String {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return (["P\(index)"] + (title.isEmpty ? [] : [title])).joined(separator: " · ")
    }

    var displayLabel: String {
        Self.displayLabel(index: index, title: title)
    }
}

/// 合集横排里的一集。
public struct PlaybackEpisodeOption: Identifiable, Sendable, Equatable {
    public let id: VideoCollectionEpisodeIdentity
    public let sectionID: VideoCollectionSectionIdentity
    public let title: String
    public let bvid: String?
    public let preferredCID: Int64?
    public let coverURL: URL?
    public let durationSeconds: Int?
    public let isEnabled: Bool
}

/// 合集横排里的一个分区。
public struct PlaybackEpisodeSectionPresentation: Identifiable, Sendable, Equatable {
    public let id: VideoCollectionSectionIdentity
    public let title: String
    public let episodes: [PlaybackEpisodeOption]
}

/// 分 P 菜单里的一项。
public struct PlaybackPageOption: Identifiable, Sendable, Equatable {
    public var id: Int64 { cid }

    public let cid: Int64
    public let index: Int
    public let title: String
    public let durationSeconds: Int
}

/// 当前选集分 P 菜单的形态。
public enum PlaybackSelectedEpisodePagesPresentation: Sendable, Equatable {
    case ready([PlaybackPageOption])
    case loading
    case failed
    case empty
}

/// 把真实 collection/page 状态投影为合集横排与侧栏分 P 菜单所需的稳定语义，不拥有网络或播放状态。
///
/// “当前是哪一集、在哪个分区、第几集”只在这里判断；横排与侧栏都读它，不各自从原始合集再算一遍。
public struct PlaybackSelectionProjection: Sendable, Equatable {
    /// 合集身份；换合集时横排回到默认分页与分区。
    public let collectionID: Int64?
    public let collectionTitle: String?
    public let episodeSections: [PlaybackEpisodeSectionPresentation]
    public let selectedEpisodeID: VideoCollectionEpisodeIdentity?
    public let episodePositionText: String?
    public let selectedPages: PlaybackSelectedEpisodePagesPresentation
    public let selectedPageCID: Int64?

    /// 有可显示的选集：横排出现「合集」分页。
    public var showsCollection: Bool { !episodeSections.isEmpty }

    public var showsSectionPicker: Bool { episodeSections.count > 1 }

    public var selectedEpisodeSectionID: VideoCollectionSectionIdentity? {
        guard let selectedEpisodeID else { return nil }
        return episodeSections.first {
            $0.episodes.contains(where: { $0.id == selectedEpisodeID })
        }?.id
    }

    public var showsPagePicker: Bool {
        guard case .ready(let pages) = selectedPages else { return false }
        return pages.count > 1
    }

    /// 侧栏分 P 这一行是否出现：有多个分 P 可选，或所选选集的分 P 正在读取或读取失败（那里给出重试）。
    public var showsPageRow: Bool {
        switch selectedPages {
        case .ready(let pages): pages.count > 1
        case .loading, .failed: true
        case .empty: false
        }
    }

    public init(
        context: VideoContext,
        selectedEpisodeID requestedEpisodeID: VideoCollectionEpisodeIdentity?,
        requestedBVID: String?,
        requestedCID: Int64?,
        presentedIdentity: PlaybackItemIdentity?,
        pageStates: [VideoCollectionEpisodeIdentity: CollectionEpisodePagesState],
        pagesByEpisode: [VideoCollectionEpisodeIdentity: [VideoPage]]
    ) {
        let collection = context.detail.collection
        collectionID = collection?.id
        collectionTitle = collection?.title
        episodeSections =
            collection?.sections.compactMap { section in
                guard !section.episodes.isEmpty else { return nil }
                return PlaybackEpisodeSectionPresentation(
                    id: section.id,
                    title: section.title,
                    episodes: section.episodes.map { episode in
                        PlaybackEpisodeOption(
                            id: episode.id,
                            sectionID: section.id,
                            title: episode.displayTitle,
                            bvid: episode.bvid,
                            preferredCID: episode.defaultCID,
                            coverURL: episode.coverURL,
                            durationSeconds: episode.durationSeconds,
                            isEnabled: episode.isPlayableSelection
                        )
                    }
                )
            } ?? []

        let episodes = collection?.sections.flatMap(\.episodes) ?? []
        let targetCID =
            requestedBVID == context.detail.bvid
            ? requestedCID ?? context.selectedPage.cid
            : presentedIdentity?.bvid == context.detail.bvid
                ? presentedIdentity?.cid : context.selectedPage.cid
        let selectedEpisode = PlaybackCollectionEpisodeResolver.resolve(
            episodes: episodes,
            explicitlySelectedID: requestedEpisodeID,
            bvid: context.detail.bvid,
            cid: targetCID
        )
        selectedEpisodeID = selectedEpisode?.id
        episodePositionText = selectedEpisode.flatMap { episode in
            collection?.sections.first(where: { section in
                section.episodes.contains(where: { $0.id == episode.id })
            }).flatMap { section in
                section.episodes.firstIndex(where: { $0.id == episode.id }).map {
                    "\($0 + 1)/\(section.episodes.count)"
                }
            }
        }
        let resolvedPages: [VideoPage]?
        if collection == nil || selectedEpisode?.bvid == context.detail.bvid {
            resolvedPages = context.pages
        } else if let selectedEpisode {
            resolvedPages = pagesByEpisode[selectedEpisode.id]
        } else {
            resolvedPages = nil
        }

        if let resolvedPages {
            let pages = resolvedPages.sorted(by: { $0.index < $1.index })
            selectedPages =
                pages.isEmpty
                ? .empty
                : .ready(
                    pages.map {
                        PlaybackPageOption(
                            cid: $0.cid,
                            index: $0.index,
                            title: $0.title,
                            durationSeconds: $0.durationSeconds
                        )
                    }
                )
            let candidateCID: Int64?
            if presentedIdentity?.bvid == selectedEpisode?.bvid
                || (collection == nil
                    && presentedIdentity?.bvid == context.detail.bvid)
            {
                candidateCID = presentedIdentity?.cid
            } else if requestedBVID == selectedEpisode?.bvid {
                candidateCID = requestedCID
            } else {
                candidateCID = selectedEpisode?.defaultCID
            }
            selectedPageCID = candidateCID.flatMap { candidate in
                pages.contains(where: { $0.cid == candidate }) ? candidate : nil
            }
        } else if let selectedEpisode {
            switch pageStates[selectedEpisode.id] ?? .idle {
            case .loading:
                selectedPages = .loading
            case .failed:
                selectedPages = .failed
            case .idle, .loaded:
                selectedPages = .empty
            }
            selectedPageCID = nil
        } else {
            selectedPages = .empty
            selectedPageCID = nil
        }
    }
}
