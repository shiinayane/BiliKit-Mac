import AppKit
import BiliApplication
import BiliModels
import Testing

@testable import BiliVideoDetailFeature

/// 评论列表与分页的失败行只在 `CommentReadError.isRetryable` 时给重试，评论区已关闭是不给重试的终态说明；
/// 不可重试的失败在同一行显示说明，无法发出的请求用与内容页相同的中性说明。
@Suite(.serialized, .timeLimit(.minutes(1)))
struct NativePlaybackCommentsFailureTests {
    @Test(arguments: [
        NativePlaybackCommentsStateKind.failed(.invalidRequest),
        .failed(.authenticationRequired),
        .failed(.transportFailure),
        .closed
    ])
    @MainActor
    func rootFailureOffersRetryOnlyWhenRetryCanHelp(kind: NativePlaybackCommentsStateKind) {
        let texts: [String]
        let offersRetry: Bool
        switch kind {
        case .failed(let error):
            let title =
                switch error {
                case .invalidRequest: VideoDetailFeatureStrings.localized("当前无法完成这次请求。")
                case .authenticationRequired: VideoDetailFeatureStrings.localized("需要登录")
                default: VideoDetailFeatureStrings.localized("评论加载失败")
                }
            texts = [title]
            offersRetry = error.isRetryable
        default:
            // 参数里其余只有 `.closed`。
            texts = [
                VideoDetailFeatureStrings.localized("评论区已关闭"),
                VideoDetailFeatureStrings.localized("这个视频的评论区已关闭。")
            ]
            offersRetry = false
        }
        let item = NativePlaybackCommentsStateItem()
        item.configure(kind: kind, onRetry: {})

        #expect(visibleButtons(in: item.view).isEmpty != offersRetry)
        #expect(Set(visibleLabelTexts(in: item.view)) == Set(texts))
        #expect(item.view.accessibilityLabel() == texts[0])
    }

    @Test(arguments: [CommentReadError.invalidRequest, .transportFailure])
    @MainActor
    func paginationFailureOffersRetryOnlyWhenRetryCanHelp(error: CommentReadError) async {
        let text =
            error.isRetryable
            ? VideoDetailFeatureStrings.localized("后续评论加载失败")
            : VideoDetailFeatureStrings.localized("当前无法完成这次请求。")
        let comments = await liveCommentsPresentation(
            threads: [
                CommentThread(
                    root: Comment(id: CommentID(rawValue: 1), payload: .unavailable(.unavailable))
                )
            ],
            totalCount: 2,
            next: .failed(error)
        )
        let item = NativePlaybackCommentsFooterItem()
        item.configure(footer: comments.footer, onRetry: {}, onLoadMore: {})

        #expect(comments.footer == .failed(error))
        #expect(visibleButtons(in: item.view).isEmpty != error.isRetryable)
        #expect(visibleLabelTexts(in: item.view) == [text])
    }

    @MainActor
    private func visibleButtons(in view: NSView) -> [NSButton] {
        descendants(of: view).compactMap { $0 as? NSButton }.filter { !$0.isHidden }
    }

    @MainActor
    private func visibleLabelTexts(in view: NSView) -> [String] {
        descendants(of: view).compactMap { $0 as? NSTextField }
            .filter { !$0.isHidden && !$0.stringValue.isEmpty }
            .map(\.stringValue)
    }
}
