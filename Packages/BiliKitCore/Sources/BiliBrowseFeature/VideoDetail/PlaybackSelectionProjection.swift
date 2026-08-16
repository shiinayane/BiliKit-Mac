import BiliApplication
import BiliModels

enum PlaybackCollectionEpisodeResolver {
    static func resolve(
        episodes: [VideoCollectionEpisode],
        explicitlySelectedID: VideoCollectionEpisodeIdentity?,
        bvid: String,
        cid: Int64?
    ) -> VideoCollectionEpisode? {
        let eligibleEpisodes = episodes.filter {
            $0.isIdentityConsistent
                && $0.bvid?.isEmpty == false
                && $0.knownPages != []
        }
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

public struct PlaybackEpisodeOption: Identifiable, Sendable, Equatable {
    public let id: VideoCollectionEpisodeIdentity
    public let sectionID: VideoCollectionSectionIdentity
    public let title: String
    public let bvid: String?
    public let preferredCID: Int64?
    public let isEnabled: Bool
}

public struct PlaybackEpisodeSectionPresentation: Identifiable, Sendable, Equatable {
    public let id: VideoCollectionSectionIdentity
    public let title: String
    public let episodes: [PlaybackEpisodeOption]
}

public struct PlaybackPageOption: Identifiable, Sendable, Equatable {
    public var id: Int64 { cid }

    public let cid: Int64
    public let index: Int
    public let title: String
    public let durationSeconds: Int
}

public enum PlaybackSelectedEpisodePagesPresentation: Sendable, Equatable {
    case ready([PlaybackPageOption])
    case loading
    case failed
    case empty
}

/// 把真实 collection/page 状态投影为紧凑 Picker 所需的稳定语义，不拥有网络或播放状态。
public struct PlaybackSelectionProjection: Sendable, Equatable {
    public let collectionTitle: String?
    public let episodeSections: [PlaybackEpisodeSectionPresentation]
    public let selectedEpisodeID: VideoCollectionEpisodeIdentity?
    public let selectedEpisodeTitle: String?
    public let episodePositionText: String?
    public let episodePlaceholder: String?
    public let selectedPages: PlaybackSelectedEpisodePagesPresentation
    public let selectedPageCID: Int64?

    public var episodeCount: Int {
        episodeSections.reduce(into: 0) { $0 += $1.episodes.count }
    }

    public var showsEpisodePicker: Bool { episodeCount > 1 }

    public var showsStaticEpisodeTitle: Bool {
        episodeCount == 1 && selectedEpisodeTitle != nil
    }

    public var showsPagePicker: Bool {
        guard case .ready(let pages) = selectedPages else { return false }
        return pages.count > 1
    }

    public var isHidden: Bool {
        collectionTitle == nil && !showsPagePicker
    }

    public init(
        context: GuestVideoContext,
        selectedEpisodeID requestedEpisodeID: VideoCollectionEpisodeIdentity?,
        requestedBVID: String?,
        requestedCID: Int64?,
        presentedIdentity: PlaybackItemIdentity?,
        pageStates: [VideoCollectionEpisodeIdentity: CollectionEpisodePagesState],
        pagesByEpisode: [VideoCollectionEpisodeIdentity: [VideoPage]]
    ) {
        let collection = context.detail.collection
        collectionTitle = collection?.title
        episodeSections =
            collection?.sections.map { section in
                PlaybackEpisodeSectionPresentation(
                    id: section.id,
                    title: section.title,
                    episodes: section.episodes.map { episode in
                        PlaybackEpisodeOption(
                            id: episode.id,
                            sectionID: section.id,
                            title: episode.title.isEmpty
                                ? "无法识别的选集" : episode.title,
                            bvid: episode.bvid,
                            preferredCID: episode.defaultCID,
                            isEnabled: episode.isIdentityConsistent
                                && episode.bvid?.isEmpty == false
                                && episode.knownPages != []
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
        selectedEpisodeTitle = selectedEpisode?.title.nonempty
        episodePositionText = selectedEpisode.flatMap { episode in
            episodes.firstIndex(where: { $0.id == episode.id }).map {
                "\($0 + 1)/\(episodes.count)"
            }
        }
        episodePlaceholder =
            collection == nil || selectedEpisode != nil
            ? nil : "当前视频不在合集目录中"

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

extension String {
    fileprivate var nonempty: String? { isEmpty ? nil : self }
}
