import BiliApplication
import BiliModels
import BiliUI
import BiliVideoCollectionUI
import SwiftUI

/// 「章节」分页的输入：正在呈现的分 P 的章节、当前章节的来源与跳转；没有章节时调用方传 nil，分页不出现。
struct ChapterShelfInput {
    let list: VideoChapterList
    /// 当前章节由章节模型按播放时间线维护；`list` 取自同一个模型，当前章节总是对着这份列表。
    let model: VideoChapterModel
    let onSeek: @MainActor (Int) -> Void
}

/// 「章节」分页的横排：标出当前章节，横排停在它上面并随播放跟过去（用户自己滚过之后不再拉回）。
///
/// 当前章节只在 body 里读，跨章时只有这个分页重新求值。
struct ChapterShelfContent: View {
    private typealias Shelf = VideoCardShelfGeometry

    let input: ChapterShelfInput
    let imageLoader: any NativeVideoImageLoading
    let scrollCommand: NativeVideoShelfScrollCommand?
    let fadesInOnCreation: Bool

    var body: some View {
        let identity = input.list.identity
        let cards = ChapterShelfCards(
            chapters: input.list.chapters,
            currentIndex: input.model.currentIndex
        )
        NativeVideoShelfView(
            contentIdentity: "chapters-\(identity.bvid)-\(identity.cid)",
            items: cards.presentations,
            accessibilityLabel: PlaybackShelfTab.chapters.title,
            imagePipeline: imageLoader,
            onSelect: { cardID in
                guard let chapter = cards.chapter(forCardID: cardID) else { return }
                input.onSeek(chapter.startSeconds)
            },
            cardMenu: { _ in nil },
            anchorID: cards.anchorID,
            scrollCommand: scrollCommand,
            fadesInOnCreation: fadesInOnCreation
        )
        .ignoresSafeArea(.container, edges: .horizontal)
        .frame(height: Shelf.viewportHeight)
    }
}

/// 章节卡片：章节封面（缩略图）、标题、起点与时长，当前章节画正在播放外观并作停靠锚点。
///
/// 卡片 ID 用起点秒数：解码时已去掉起点重复的章节（`VideoChapterCatalogPayload`），ID 不会撞。
struct ChapterShelfCards {
    let chapters: [VideoChapter]
    let presentations: [NativeVideoCardPresentation]
    let anchorID: String?

    init(chapters: [VideoChapter], currentIndex: Int?) {
        self.chapters = chapters
        let nowPlaying = VideoDetailFeatureStrings.localized("正在播放")
        presentations = chapters.enumerated().map { index, chapter in
            let isCurrent = index == currentIndex
            let start = VideoDurationFormatting.string(seconds: chapter.startSeconds)
            let number = VideoDetailFeatureStrings.localized("第 \(index + 1) 章")
            return NativeVideoCardPresentation(
                id: Self.cardID(chapter),
                title: chapter.title,
                coverURL: BiliImageThumbnail.url(chapter.coverURL, size: .videoCover),
                avatarURL: nil,
                showsAvatar: false,
                coverTrailingText: VideoDurationFormatting.string(
                    seconds: chapter.endSeconds - chapter.startSeconds
                ),
                footerLeadingText: "\(number) · \(start)",
                accessibilityLabel: ListFormatter.localizedString(
                    byJoining: [number, chapter.title, start] + (isCurrent ? [nowPlaying] : [])
                ),
                accessibilityHelp: VideoDetailFeatureStrings.localized("跳到这一章"),
                nowPlayingText: isCurrent ? nowPlaying : nil
            )
        }
        anchorID = currentIndex.flatMap {
            chapters.indices.contains($0) ? Self.cardID(chapters[$0]) : nil
        }
    }

    func chapter(forCardID cardID: String) -> VideoChapter? {
        chapters.first { Self.cardID($0) == cardID }
    }

    private static func cardID(_ chapter: VideoChapter) -> String {
        "chapter-\(chapter.startSeconds)"
    }
}
