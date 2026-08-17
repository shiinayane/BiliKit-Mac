import BiliApplication
import BiliModels
import Foundation
import Testing

@testable import BiliBrowseFeature

struct PlaybackSelectionProjectionTests {
    @Test
    func noCollectionSinglePageHidesSelectionAndMultiplePagesShowOnlyPagePicker() {
        let single = projection(context: context(pages: [page(1)]))
        let multiple = projection(context: context(pages: [page(1), page(2)]))

        #expect(single.isHidden)
        #expect(!single.showsEpisodePicker)
        #expect(!single.showsPagePicker)
        #expect(!multiple.isHidden)
        #expect(!multiple.showsEpisodePicker)
        #expect(multiple.showsPagePicker)
    }

    @Test
    func singleEpisodeCollectionUsesPickerAndShowsPagePickerOnlyForMultiplePages() {
        let onePage = [page(1)]
        let twoPages = [page(1), page(2)]
        let episode = episode(ordinal: 0, bvid: "BVCurrent", pages: twoPages)
        let collection = collection(sections: [[episode]])

        let single = projection(
            context: context(pages: onePage, collection: collection)
        )
        let multiple = projection(
            context: context(pages: twoPages, collection: collection)
        )

        #expect(single.collectionTitle == "合集")
        #expect(single.showsEpisodePicker)
        #expect(!single.showsSectionPicker)
        #expect(!single.showsPagePicker)
        #expect(multiple.showsEpisodePicker)
        #expect(multiple.showsPagePicker)
    }

    @Test
    func emptyRemoteSectionDoesNotBecomeAnEpisodePickerGroup() {
        let episode = episode(
            ordinal: 0,
            bvid: "BVCurrent",
            pages: [page(1)],
            section: 1
        )
        let projection = projection(
            context: context(
                pages: [page(1)],
                collection: collection(sections: [[], [episode]])
            )
        )

        #expect(projection.showsEpisodePicker)
        #expect(projection.episodeCount == 1)
        #expect(projection.episodeSections.map(\.title) == ["分区 2"])
    }

    @Test
    func eightyEpisodesPreserveSectionsAndUnavailableOptionsRemainVisibleDisabled() {
        let sections = (0..<4).map { section in
            (0..<20).map { item in
                episode(
                    ordinal: section * 20 + item,
                    bvid: item == 19 && section == 3
                        ? nil
                        : "BV\(section)-\(item)",
                    pages: [page(1)],
                    isConsistent: !(item == 19 && section == 3),
                    section: section
                )
            }
        }
        let projection = projection(
            context: context(
                pages: [page(1)],
                collection: collection(sections: sections)
            )
        )

        #expect(projection.episodeCount == 80)
        #expect(projection.episodeSections.count == 4)
        #expect(projection.showsEpisodePicker)
        #expect(projection.showsSectionPicker)
        #expect(projection.episodeSections.last?.episodes.last?.isEnabled == false)
    }

    @Test
    func missingCurrentEpisodeAndPendingPagesNeverFabricateEpisodeOrCID() {
        let remote = episode(
            ordinal: 0,
            bvid: "BVRemote",
            pages: nil
        )
        let collection = collection(sections: [[remote]])
        let missing = projection(
            context: context(pages: [page(1)], collection: collection)
        )
        let pending = projection(
            context: context(pages: [page(1)], collection: collection),
            selectedEpisodeID: remote.id,
            requestedBVID: "BVRemote",
            requestedCID: 99,
            pageStates: [remote.id: .loading]
        )

        #expect(missing.selectedEpisodeID == nil)
        #expect(missing.episodePositionText == nil)
        #expect(missing.episodePlaceholder != nil)
        #expect(missing.selectedPageCID == nil)
        #expect(pending.selectedEpisodeID == remote.id)
        #expect(pending.episodePositionText == "1/1")
        #expect(pending.selectedPages == .loading)
        #expect(pending.selectedPageCID == nil)
    }

    @Test
    func currentEpisodePositionUsesItsSectionOrder() {
        let episodes = (0..<10).map { ordinal in
            episode(
                ordinal: ordinal,
                bvid: ordinal == 4 ? "BVCurrent" : "BV\(ordinal)",
                pages: [page(1)]
            )
        }
        let projection = projection(
            context: context(
                pages: [page(1)],
                collection: collection(sections: [
                    Array(episodes[0..<3]),
                    Array(episodes[3..<10]),
                ])
            )
        )

        #expect(projection.selectedEpisodeSectionID == projection.episodeSections[1].id)
        #expect(projection.episodePositionText == "2/7")
    }

    @Test
    func duplicateBVIDUsesCIDToResolveOccurrenceAndDoesNotGuessWhenAmbiguous() {
        let first = episode(
            ordinal: 0,
            bvid: "BVCurrent",
            pages: [page(1), page(2)]
        )
        let second = episode(
            ordinal: 1,
            bvid: "BVCurrent",
            pages: [page(2), page(1)]
        )
        let duplicateCollection = collection(sections: [[first, second]])
        let resolved = projection(
            context: context(
                pages: [page(1), page(2)],
                collection: duplicateCollection
            ),
            requestedBVID: "BVCurrent",
            requestedCID: page(2).cid
        )
        let ambiguousEpisode = episode(
            ordinal: 1,
            bvid: "BVCurrent",
            pages: [page(1)]
        )
        let ambiguous = projection(
            context: context(
                pages: [page(1)],
                collection: collection(sections: [[first, ambiguousEpisode]])
            )
        )

        #expect(resolved.selectedEpisodeID == second.id)
        #expect(resolved.episodePositionText == "2/2")
        #expect(ambiguous.selectedEpisodeID == nil)
        #expect(ambiguous.episodePositionText == nil)
        #expect(ambiguous.episodePlaceholder != nil)
    }

    @Test
    func explicitDuplicateBVIDOccurrenceAlwaysWinsOverAutomaticMatching() {
        let first = episode(
            ordinal: 0,
            bvid: "BVCurrent",
            pages: [page(1)]
        )
        let second = episode(
            ordinal: 1,
            bvid: "BVCurrent",
            pages: [page(1)]
        )
        let projection = projection(
            context: context(
                pages: [page(1)],
                collection: collection(sections: [[first, second]])
            ),
            selectedEpisodeID: second.id
        )

        #expect(projection.selectedEpisodeID == second.id)
        #expect(projection.episodePositionText == "2/2")
    }

    private func projection(
        context: GuestVideoContext,
        selectedEpisodeID: VideoCollectionEpisodeIdentity? = nil,
        requestedBVID: String? = nil,
        requestedCID: Int64? = nil,
        pageStates: [VideoCollectionEpisodeIdentity: CollectionEpisodePagesState] = [:],
        pagesByEpisode: [VideoCollectionEpisodeIdentity: [VideoPage]] = [:]
    ) -> PlaybackSelectionProjection {
        PlaybackSelectionProjection(
            context: context,
            selectedEpisodeID: selectedEpisodeID,
            requestedBVID: requestedBVID,
            requestedCID: requestedCID,
            presentedIdentity: nil,
            pageStates: pageStates,
            pagesByEpisode: pagesByEpisode
        )
    }

    private func context(
        pages: [VideoPage],
        collection: VideoCollection? = nil
    ) -> GuestVideoContext {
        let detail = VideoDetail(
            bvid: "BVCurrent",
            title: "当前视频",
            summary: "说明",
            coverURL: nil,
            owner: VideoOwner(id: 1, name: "作者"),
            statistics: VideoStatistics(
                viewCount: 1,
                danmakuCount: 1,
                likeCount: 1
            ),
            durationSeconds: 10,
            publishedAt: Date(timeIntervalSince1970: 1_700_000_000),
            pages: pages,
            collection: collection
        )
        return GuestVideoContext(
            detail: detail,
            pages: pages,
            selectedPage: pages[0],
            playback: VideoPlayback(
                manifest: PlaybackManifest(
                    videoRepresentations: [],
                    originalAudioRepresentations: []
                ),
                mediaHeaders: [:]
            )
        )
    }

    private func page(_ index: Int) -> VideoPage {
        VideoPage(
            cid: Int64(1_000 + index),
            index: index,
            title: "P\(index)",
            durationSeconds: 10
        )
    }

    private func episode(
        ordinal: Int,
        bvid: String?,
        pages: [VideoPage]?,
        isConsistent: Bool = true,
        section: Int = 0
    ) -> VideoCollectionEpisode {
        VideoCollectionEpisode(
            id: VideoCollectionEpisodeIdentity(
                seasonID: 1,
                sectionID: Int64(section + 10),
                episodeID: Int64(ordinal + 100)
            ),
            ordinal: ordinal,
            aid: nil,
            bvid: bvid,
            title: "第 \(ordinal + 1) 集",
            coverURL: nil,
            durationSeconds: 10,
            defaultCID: pages?.first?.cid,
            knownPages: pages,
            isIdentityConsistent: isConsistent
        )
    }

    private func collection(
        sections: [[VideoCollectionEpisode]]
    ) -> VideoCollection {
        VideoCollection(
            id: 1,
            title: "合集",
            reportedEpisodeCount: sections.reduce(0) { $0 + $1.count },
            sections: sections.enumerated().map { ordinal, episodes in
                VideoCollectionSection(
                    id: VideoCollectionSectionIdentity(
                        seasonID: 1,
                        sectionID: Int64(ordinal + 10)
                    ),
                    ordinal: ordinal,
                    title: "分区 \(ordinal + 1)",
                    episodes: episodes
                )
            }
        )
    }
}
