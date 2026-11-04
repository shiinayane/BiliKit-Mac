import AppKit
import BiliApplication
import Testing

@testable import BiliVideoDetailFeature

/// 评论区的加载只用转圈、不画骨架：状态行与页脚的转圈在加载开始时先不露出，过了统一的延迟仍在加载才露出；
/// 其他状态与条目复用后停止并隐藏，转圈不单独读屏；加载中的行高等于对应的说明行与“加载更多”行，切换时不改变
/// 文档高度。
@Suite(.serialized, .timeLimit(.minutes(1)))
struct NativePlaybackCommentsLoadingTests {
    @Test
    @MainActor
    func stateRowSpinsOnlyWhileLoading() async throws {
        let item = NativePlaybackCommentsStateItem()
        item.configure(kind: .loading, onRetry: {})
        let spinner = try onlySpinner(in: item.view)
        #expect(spinner.isHidden)
        await waitUntilShown(spinner)
        #expect(!spinner.isAccessibilityElement())
        #expect(item.view.accessibilityLabel() == VideoDetailFeatureStrings.localized("评论加载中"))

        for kind in [
            NativePlaybackCommentsStateKind.idle,
            .empty,
            .closed,
            .failed(.transportFailure)
        ] {
            item.configure(kind: .loading, onRetry: {})
            item.configure(kind: kind, onRetry: {})
            #expect(spinner.isHidden)
        }

        item.configure(kind: .loading, onRetry: {})
        item.prepareForReuse()
        #expect(spinner.isHidden)
    }

    @Test
    @MainActor
    func footerSpinsOnlyWhileLoadingMore() async throws {
        let item = NativePlaybackCommentsFooterItem()
        item.configure(footer: .loading, onRetry: {}, onLoadMore: {})
        let spinner = try onlySpinner(in: item.view)
        #expect(spinner.isHidden)
        await waitUntilShown(spinner)
        #expect(!spinner.isAccessibilityElement())

        for footer in [
            NativePlaybackCommentsFooter.loadMore,
            .failed(.transportFailure),
            .stopped,
            .end(memoryLimited: false)
        ] {
            item.configure(footer: .loading, onRetry: {}, onLoadMore: {})
            item.configure(footer: footer, onRetry: {}, onLoadMore: {})
            #expect(spinner.isHidden)
        }

        item.configure(footer: .loading, onRetry: {}, onLoadMore: {})
        item.prepareForReuse()
        #expect(spinner.isHidden)
    }

    @Test
    @MainActor
    func loadingRowsKeepTheHeightOfTheRowsTheyTurnInto() {
        let loadingHeight = NativePlaybackCommentsItemMeasurement.state(.loading, width: 320)
        for kind in [NativePlaybackCommentsStateKind.idle, .empty, .closed] {
            #expect(NativePlaybackCommentsItemMeasurement.state(kind, width: 320) == loadingHeight)
        }
        #expect(
            NativePlaybackCommentsItemMeasurement.footer(.loading)
                == NativePlaybackCommentsItemMeasurement.footer(.loadMore)
        )
    }

    /// 等转圈露出；露不出来时由 Suite 的时限判失败。
    @MainActor
    private func waitUntilShown(_ spinner: NSProgressIndicator) async {
        while spinner.isHidden {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    /// 条目里唯一的转圈；找不到或多于一个都说明加载呈现不再是单个转圈。
    @MainActor
    private func onlySpinner(in view: NSView) throws -> NSProgressIndicator {
        let spinners = descendants(of: view).compactMap { $0 as? NSProgressIndicator }
        try #require(spinners.count == 1)
        return spinners[0]
    }
}
