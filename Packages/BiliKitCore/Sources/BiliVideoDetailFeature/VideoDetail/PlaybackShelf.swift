import BiliModels
import BiliUI
import BiliVideoCollectionUI
import SwiftUI

/// 播放页下方横排显示什么；声明顺序就是分页顺序。
enum PlaybackShelfTab: Hashable, CaseIterable {
    case related
    case recent
    case chapters
    case collection
}

/// 播放页下方的横排：「相关视频」「刚才看过」「章节」「合集」分页，默认相关视频；没有分段章节时没有「章节」，视频不属于
/// 合集时没有「合集」。
///
/// 持有用户选的分页、正在浏览的分区、“再点一次当前分页”的滚动请求与换视频途中停住的「刚才看过」（都是视图状态）；
/// 不拥有推荐请求、「刚才看过」列表、章节读取、选集分 P 解析、跳转或导航，选择意图经回调交出。用户选的分页在下一个视频
/// 没有时显示相关视频，但选择保留，到有这一页的视频时回到它。合集只读选集投影，章节只读章节模型，“当前是哪一集”“当前是
/// 哪一章”都不在这里另算。
struct PlaybackShelf: View {
    private typealias Shelf = VideoCardShelfGeometry

    /// 选集投影；视频不属于合集（`showsCollection` 为 false）时由调用方传 nil。
    let collection: PlaybackSelectionProjection?
    /// 当前分 P 的分段章节；没有章节时为 nil，「章节」分页不出现。
    let chapters: ChapterShelfInput?
    /// 「刚才看过」的全部卡片，第一项是正在播放的视频。
    let recentlyWatched: [RecentlyWatchedVideo]
    /// 已请求另一个视频、详情还是旧的：这段时间「刚才看过」停在换之前的样子。
    let isReplacingVideo: Bool
    let relatedState: RelatedVideoShelfState
    let relatedContentIdentity: String
    let onSelectRelated: (String) -> Void
    let onRetryRelated: () -> Void
    let onSelectRecent: (PlaybackSelectionIntent) -> Void
    let onSelectEpisode: (VideoCollectionEpisodeIdentity) -> Void
    let imageLoader: any NativeVideoImageLoading

    @State private var chosenTab: PlaybackShelfTab?
    /// 用户在分区菜单里选的分区。
    ///
    /// nil 表示跟随当前一集所在的分区；当前一集变了就回到跟随。
    @State private var browsedSectionID: VideoCollectionSectionIdentity?
    /// 再点一次当前分页时递增；横排按序号判断是不是新的请求。
    @State private var scrollCommand: NativeVideoShelfScrollCommand?
    /// 最近一次不在换视频途中的「刚才看过」。
    ///
    /// 协调器在请求新视频时就改了列表，正在播放的那一项却要等新详情到了才换；
    /// 不停在这里，卡片会先少一张、详情到了再插回来，横排动两次。
    @State private var settledRecent: [RecentlyWatchedVideo] = []
    /// 用户切过分页之后新建的一排淡入；换视频时清掉，加载完出现的相关视频照常直接显示。
    @State private var fadesInNewShelf = false

    var body: some View {
        RelatedVideoShelfFrame {
            header
        } content: {
            content
        }
        .onChange(
            of: RecentSettlement(entries: recentlyWatched, isReplacing: isReplacingVideo),
            initial: true
        ) { _, settlement in
            if !settlement.isReplacing { settledRecent = settlement.entries }
        }
        .onChange(of: relatedContentIdentity) {
            fadesInNewShelf = false
        }
        .onChange(of: collection?.selectedEpisodeID) {
            browsedSectionID = nil
        }
        // 换到另一个合集时分区回到跟随当前一集；用户选的分页保留（在「刚才看过」里点到别的合集不跳回相关视频），
        // 新视频没有合集时「合集」分页不在，`tab` 自然落到相关视频。
        .onChange(of: collection?.collectionID) {
            browsedSectionID = nil
        }
    }

    private var availableTabs: [PlaybackShelfTab] {
        PlaybackShelfTab.allCases.filter { tab in
            switch tab {
            case .related: true
            case .recent: !shownRecent.isEmpty
            case .chapters: chapters != nil
            case .collection: collection != nil
            }
        }
    }

    private var shownRecent: [RecentlyWatchedVideo] {
        isReplacingVideo && !settledRecent.isEmpty ? settledRecent : recentlyWatched
    }

    private var tab: PlaybackShelfTab {
        guard let chosenTab, availableTabs.contains(chosenTab) else { return .related }
        return chosenTab
    }

    /// 「刚才看过」总带着正在播放的这一项，所以分页至少两个，标题行总是分段控件。
    private var header: some View {
        HStack(spacing: 12) {
            PlaybackShelfTabControl(
                tabs: availableTabs,
                selection: tab,
                onSelect: {
                    fadesInNewShelf = true
                    chosenTab = $0
                },
                onReselect: reselectCurrentTab
            )
            .fixedSize()

            if tab == .collection, let collection {
                collectionHeaderDetails(collection)
            } else {
                Spacer(minLength: 0)
            }
        }
    }

    /// 合集分页的标题行右半：合集名紧跟分页，多分区时接分区弹出菜单，位置靠右。
    ///
    /// 浏览的不是当前一集所在的分区时，位置换成这个分区的集数，不显示与眼前内容无关的「21/24」。
    @ViewBuilder
    private func collectionHeaderDetails(_ projection: PlaybackSelectionProjection) -> some View {
        let section = displayedSection(projection)
        if let title = projection.collectionTitle {
            Text(title)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(title)
                .layoutPriority(-1)
        }

        if projection.showsSectionPicker, let section {
            Picker(
                VideoDetailFeatureStrings.localized("分区"),
                selection: Binding(
                    get: { section.id },
                    set: { browsedSectionID = $0 }
                )
            ) {
                ForEach(Array(projection.episodeSections.enumerated()), id: \.element.id) {
                    index,
                    candidate in
                    Text(Self.sectionTitle(candidate, index: index)).tag(candidate.id)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
        }

        Spacer(minLength: 8)

        if let section {
            Text(positionText(projection, section: section))
                .font(.callout.monospacedDigit())
                .foregroundStyle(.tertiary)
                .fixedSize()
        }
    }

    private static func sectionTitle(
        _ section: PlaybackEpisodeSectionPresentation,
        index: Int
    ) -> String {
        section.title.isEmpty
            ? VideoDetailFeatureStrings.localized("分区 \(index + 1)") : section.title
    }

    private func positionText(
        _ projection: PlaybackSelectionProjection,
        section: PlaybackEpisodeSectionPresentation
    ) -> String {
        if section.id == projection.selectedEpisodeSectionID,
            let positionText = projection.episodePositionText
        {
            return positionText
        }
        return String(
            format: VideoDetailFeatureStrings.localized("共 %lld 集"),
            Int64(section.episodes.count)
        )
    }

    /// 再点一次当前分页：合集分页且看的是当前一集所在的分区时回到当前一集，章节分页回到当前章节（还在第一章之前时回到
    /// 开头），其余回到开头，都用翻页同一份动画。
    private func reselectCurrentTab() {
        let target: NativeVideoShelfScrollCommand.Target
        if tab == .collection, let collection,
            let section = displayedSection(collection),
            section.id == collection.selectedEpisodeSectionID
        {
            target = .anchor
        } else if tab == .chapters {
            target = .anchor
        } else {
            target = .leading
        }
        scrollCommand = NativeVideoShelfScrollCommand(
            serial: (scrollCommand?.serial ?? 0) + 1,
            target: target
        )
    }

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .collection:
            if let collection {
                collectionContent(collection)
            }
        case .chapters:
            if let chapters {
                ChapterShelfContent(
                    input: chapters,
                    imageLoader: imageLoader,
                    scrollCommand: scrollCommand,
                    fadesInOnCreation: fadesInNewShelf
                )
            }
        case .recent:
            recentContent
        case .related:
            RelatedVideoShelf(
                state: relatedState,
                onSelect: onSelectRelated,
                onRetry: onRetryRelated,
                contentIdentity: relatedContentIdentity,
                imageLoader: imageLoader,
                scrollCommand: scrollCommand,
                fadesInOnCreation: fadesInNewShelf
            )
        }
    }

    private var recentContent: some View {
        let cards = RecentlyWatchedShelfCards(entries: shownRecent)
        return NativeVideoShelfView(
            contentIdentity: "recently-watched",
            items: cards.presentations,
            accessibilityLabel: PlaybackShelfTab.recent.title,
            imagePipeline: imageLoader,
            onSelect: { cardID in
                guard let resumePoint = cards.resumePoint(forCardID: cardID) else { return }
                onSelectRecent(resumePoint)
            },
            cardMenu: { _ in nil },
            scrollCommand: scrollCommand,
            fadesInOnCreation: fadesInNewShelf
        )
        .ignoresSafeArea(.container, edges: .horizontal)
        .frame(height: Shelf.viewportHeight)
    }

    @ViewBuilder
    private func collectionContent(_ projection: PlaybackSelectionProjection) -> some View {
        if let section = displayedSection(projection) {
            let cards = CollectionShelfCards(
                section: section,
                selectedEpisodeID: projection.selectedEpisodeID
            )
            NativeVideoShelfView(
                contentIdentity: cards.contentIdentity,
                items: cards.presentations,
                accessibilityLabel: PlaybackShelfTab.collection.title,
                imagePipeline: imageLoader,
                onSelect: { cardID in
                    guard let episodeID = cards.episodeID(forCardID: cardID) else { return }
                    onSelectEpisode(episodeID)
                },
                cardMenu: { _ in nil },
                anchorID: cards.anchorID,
                scrollCommand: scrollCommand,
                fadesInOnCreation: fadesInNewShelf
            )
            .ignoresSafeArea(.container, edges: .horizontal)
            .frame(height: Shelf.viewportHeight)
        }
    }

    /// 显示的分区：用户选过且仍存在的分区，否则当前一集所在的分区，再否则第一个分区（投影已去掉空分区）。
    private func displayedSection(
        _ projection: PlaybackSelectionProjection
    ) -> PlaybackEpisodeSectionPresentation? {
        let sections = projection.episodeSections
        let preferredID = browsedSectionID ?? projection.selectedEpisodeSectionID
        return sections.first(where: { $0.id == preferredID }) ?? sections.first
    }
}

private struct RecentSettlement: Equatable {
    let entries: [RecentlyWatchedVideo]
    let isReplacing: Bool
}
