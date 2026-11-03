import BiliModels

/// 合集与分 P 测试共用的分 P：CID 为 1000 加序号，时长 10 秒。
func makeTestPage(_ index: Int) -> VideoPage {
    VideoPage(
        cid: Int64(1_000 + index),
        index: index,
        title: "P\(index)",
        durationSeconds: 10
    )
}

/// 合集测试共用的一集；`pages` 给出时第一页是它的默认 CID，标题缺省为「第 n 集」。
func makeTestEpisode(
    ordinal: Int,
    bvid: String?,
    pages: [VideoPage]?,
    isConsistent: Bool = true,
    section: Int = 0,
    title: String? = nil
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
        title: title ?? "第 \(ordinal + 1) 集",
        coverURL: nil,
        durationSeconds: 10,
        defaultCID: pages?.first?.cid,
        knownPages: pages,
        isIdentityConsistent: isConsistent
    )
}

/// 合集测试共用的合集：每个内层数组是一个分部，季 ID 为 1。
func makeTestCollection(
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
