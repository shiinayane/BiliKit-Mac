import BiliApplication
import BiliModels

extension VideoViewModel {
    /// 侧栏分 P 条目与播放页合集横排共用的选集投影：同一份“当前是哪一集”的判断。
    func selectionProjection(for context: VideoContext) -> PlaybackSelectionProjection {
        let episodes = context.detail.collection?.sections.flatMap(\.episodes) ?? []
        let pagesByEpisode = Dictionary(
            uniqueKeysWithValues: episodes.compactMap { episode in
                collectionEpisodePages(for: episode.id).map {
                    (episode.id, $0)
                }
            }
        )
        return PlaybackSelectionProjection(
            context: context,
            selectedEpisodeID: selectedCollectionEpisode,
            requestedBVID: requestedSelectionBVID,
            requestedCID: requestedPreferredCID,
            presentedIdentity: presentedPlaybackIdentity,
            pageStates: collectionEpisodePageStates,
            pagesByEpisode: pagesByEpisode
        )
    }

    /// 在正在呈现的合集里按身份找到一集；横排选集与侧栏分 P 重试共用。
    func presentedCollectionEpisode(
        _ identity: VideoCollectionEpisodeIdentity
    ) -> VideoCollectionEpisode? {
        presentedContext?.detail.collection?.sections
            .flatMap(\.episodes)
            .first(where: { $0.id == identity })
    }
}
