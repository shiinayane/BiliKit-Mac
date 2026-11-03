import BiliApplication
import BiliModels
import Foundation
import Testing

@testable import BiliVideoDetailFeature

/// 播放页的选集投影只呈现能确定的合集与分 P，认不准时不编造。
///
/// 没有合集时只按分 P 数决定显示分 P 选择；有合集时显示选集，分部保留、空分部不成组，不可用的集仍可见但禁用；
/// 位置按当前集所在分部计数；认不出当前集或分 P 尚未加载时不编造集与 CID；重复 BVID 用 CID 区分，区分不了时
/// 不猜，显式选中的那一集优先。
struct PlaybackSelectionProjectionTests {
    @Test
    func noCollectionSinglePageHidesSelectionAndMultiplePagesShowOnlyPagePicker() {
        let single = projection(context: context(pages: [makeTestPage(1)]))
        let multiple = projection(context: context(pages: [makeTestPage(1), makeTestPage(2)]))

        #expect(single.isHidden)
        #expect(!single.showsEpisodePicker)
        #expect(!single.showsPagePicker)
        #expect(!multiple.isHidden)
        #expect(!multiple.showsEpisodePicker)
        #expect(multiple.showsPagePicker)
    }

    @Test
    func singleEpisodeCollectionUsesPickerAndShowsPagePickerOnlyForMultiplePages() {
        let onePage = [makeTestPage(1)]
        let twoPages = [makeTestPage(1), makeTestPage(2)]
        let episode = makeTestEpisode(ordinal: 0, bvid: "BVCurrent", pages: twoPages)
        let collection = makeTestCollection(sections: [[episode]])

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
        let episode = makeTestEpisode(
            ordinal: 0,
            bvid: "BVCurrent",
            pages: [makeTestPage(1)],
            section: 1
        )
        let projection = projection(
            context: context(
                pages: [makeTestPage(1)],
                collection: makeTestCollection(sections: [[], [episode]])
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
                makeTestEpisode(
                    ordinal: section * 20 + item,
                    bvid: item == 19 && section == 3
                        ? nil
                        : "BV\(section)-\(item)",
                    pages: [makeTestPage(1)],
                    isConsistent: !(item == 19 && section == 3),
                    section: section
                )
            }
        }
        let projection = projection(
            context: context(
                pages: [makeTestPage(1)],
                collection: makeTestCollection(sections: sections)
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
        let remote = makeTestEpisode(
            ordinal: 0,
            bvid: "BVRemote",
            pages: nil
        )
        let collection = makeTestCollection(sections: [[remote]])
        let missing = projection(
            context: context(pages: [makeTestPage(1)], collection: collection)
        )
        let pending = projection(
            context: context(pages: [makeTestPage(1)], collection: collection),
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
            makeTestEpisode(
                ordinal: ordinal,
                bvid: ordinal == 4 ? "BVCurrent" : "BV\(ordinal)",
                pages: [makeTestPage(1)]
            )
        }
        let projection = projection(
            context: context(
                pages: [makeTestPage(1)],
                collection: makeTestCollection(sections: [
                    Array(episodes[0..<3]),
                    Array(episodes[3..<10])
                ])
            )
        )

        #expect(projection.selectedEpisodeSectionID == projection.episodeSections[1].id)
        #expect(projection.episodePositionText == "2/7")
    }

    @Test
    func duplicateBVIDUsesCIDToResolveOccurrenceAndDoesNotGuessWhenAmbiguous() {
        let first = makeTestEpisode(
            ordinal: 0,
            bvid: "BVCurrent",
            pages: [makeTestPage(1), makeTestPage(2)]
        )
        let second = makeTestEpisode(
            ordinal: 1,
            bvid: "BVCurrent",
            pages: [makeTestPage(2), makeTestPage(1)]
        )
        let duplicateCollection = makeTestCollection(sections: [[first, second]])
        let resolved = projection(
            context: context(
                pages: [makeTestPage(1), makeTestPage(2)],
                collection: duplicateCollection
            ),
            requestedBVID: "BVCurrent",
            requestedCID: makeTestPage(2).cid
        )
        let ambiguousEpisode = makeTestEpisode(
            ordinal: 1,
            bvid: "BVCurrent",
            pages: [makeTestPage(1)]
        )
        let ambiguous = projection(
            context: context(
                pages: [makeTestPage(1)],
                collection: makeTestCollection(sections: [[first, ambiguousEpisode]])
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
        let first = makeTestEpisode(
            ordinal: 0,
            bvid: "BVCurrent",
            pages: [makeTestPage(1)]
        )
        let second = makeTestEpisode(
            ordinal: 1,
            bvid: "BVCurrent",
            pages: [makeTestPage(1)]
        )
        let projection = projection(
            context: context(
                pages: [makeTestPage(1)],
                collection: makeTestCollection(sections: [[first, second]])
            ),
            selectedEpisodeID: second.id
        )

        #expect(projection.selectedEpisodeID == second.id)
        #expect(projection.episodePositionText == "2/2")
    }

    private func projection(
        context: VideoContext,
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
    ) -> VideoContext {
        makeVideoContext(
            detail: makeVideoDetail(durationSeconds: 10, pages: pages, collection: collection)
        )
    }
}
