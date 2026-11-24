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

    /// 正在播放的分 P 是合集里的哪一集；认不出时为 nil。
    ///
    /// 选集菜单的选择只在同一 BV 时才算数：另选的一集可能还在解析或已失败，不代表正在播放的这一集。同一 BV 的各集
    /// 各是一个分 P 时，按 CID 认出的那一集优先：在当前视频里换分 P 不更新选择，否则会一直按进入时的那一集算，
    /// 播完最后一个分 P 又跳回已经播过的分 P。
    func currentCollectionEpisode(
        for identity: PlaybackItemIdentity,
        in context: VideoContext
    ) -> VideoCollectionEpisode? {
        guard let collection = context.detail.collection else { return nil }
        let episodes = collection.sections.flatMap(\.episodes)
        let byCID = episodes.filter { $0.bvid == identity.bvid && $0.defaultCID == identity.cid }
        if byCID.count == 1 { return byCID[0] }
        let explicit = selectedCollectionEpisode.flatMap { id in
            episodes.first(where: { $0.id == id && $0.bvid == identity.bvid })?.id
        }
        return PlaybackCollectionEpisodeResolver.resolve(
            episodes: episodes,
            explicitlySelectedID: explicit,
            bvid: identity.bvid,
            cid: identity.cid
        )
    }
}
