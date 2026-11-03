import BiliApplication
import BiliModels
import Foundation
import Testing

@testable import BiliLibraryFeature

/// 稍后再看的乐观移除先在本地删掉、总数减一，失败时放回原位；列表被整体替换后旧的移除不再放回；别处写入只标记过期，
/// 下一次页面出现时原地刷新一次。
@Suite(.timeLimit(.minutes(1)))
struct WatchLaterRemovalTests {
    @Test
    @MainActor
    func optimisticRemovalRollsBackToTheSamePosition() async throws {
        let model = try await loadedModel(["BV1LaterA1", "BV1LaterB2", "BV1LaterC3"], total: 3)

        let removal = try #require(model.removeItem(bvid: "BV1LaterB2"))
        #expect(model.loadedBVIDs == ["BV1LaterA1", "BV1LaterC3"])
        #expect(model.totalCount == 2)
        #expect(model.removeItem(bvid: "BV1LaterMissing") == nil)

        model.restoreItem(removal)
        #expect(model.loadedBVIDs == ["BV1LaterA1", "BV1LaterB2", "BV1LaterC3"])
        #expect(model.totalCount == 3)

        model.restoreItem(removal)
        #expect(model.loadedBVIDs == ["BV1LaterA1", "BV1LaterB2", "BV1LaterC3"])
        #expect(model.totalCount == 3)
    }

    /// 移除之后刷新成功或账户变化（`reset`）替换了内容：旧的移除不再放回，不与新内容或新账户的列表混排。
    @Test
    @MainActor
    func rollbackAfterContentReplacementIsDropped() async throws {
        let repository = WatchLaterRepositoryStub(
            results: [
                laterPage(["BV1LaterA1", "BV1LaterB2"], page: 1, next: nil, total: 2),
                laterPage(["BV1LaterA1"], page: 1, next: nil, total: 1)
            ]
        )
        let model = WatchLaterViewModel(useCase: WatchLaterUseCase(repository: repository))
        model.loadIfNeeded()
        await model.waitForCurrentTask()

        let removal = try #require(model.removeItem(bvid: "BV1LaterB2"))
        model.reload()
        await model.waitForCurrentTask()
        model.restoreItem(removal)

        #expect(model.loadedBVIDs == ["BV1LaterA1"])
        #expect(model.totalCount == 1)

        let second = try #require(model.removeItem(bvid: "BV1LaterA1"))
        model.reset()
        model.restoreItem(second)
        #expect(model.state == .idle)
    }

    @Test
    @MainActor
    func removalNeedsLoadedContent() {
        let model = WatchLaterViewModel(
            useCase: WatchLaterUseCase(repository: WatchLaterRepositoryStub(results: []))
        )

        #expect(model.removeItem(bvid: "BV1LaterA1") == nil)
    }

    /// 别处的写入只标记过期：不立即读取，下一次页面出现时原地刷新一次，之后不再重复。
    @Test
    @MainActor
    func externalWritesReloadOnTheNextAppearanceOnly() async {
        let repository = WatchLaterRepositoryStub(
            results: [
                laterPage(["BV1LaterA1"], page: 1, next: nil, total: 1),
                laterPage(["BV1LaterB2", "BV1LaterA1"], page: 1, next: nil, total: 2)
            ]
        )
        let model = WatchLaterViewModel(useCase: WatchLaterUseCase(repository: repository))
        model.loadIfNeeded()
        await model.waitForCurrentTask()

        model.markNeedsReload()
        #expect(await repository.requestedPages == [1])

        model.loadIfNeeded()
        await model.waitForCurrentTask()
        #expect(model.loadedBVIDs == ["BV1LaterB2", "BV1LaterA1"])

        model.loadIfNeeded()
        await model.waitForCurrentTask()
        #expect(await repository.requestedPages == [1, 1])
    }

    @MainActor
    private func loadedModel(_ bvids: [String], total: Int) async throws -> WatchLaterViewModel {
        let model = WatchLaterViewModel(
            useCase: WatchLaterUseCase(
                repository: WatchLaterRepositoryStub(
                    results: [laterPage(bvids, page: 1, next: nil, total: total)]
                )
            )
        )
        model.loadIfNeeded()
        await model.waitForCurrentTask()
        return model
    }
}

extension LibraryVideoListModel where Item == WatchLaterItem {
    /// 当前显示条目的 BVID，按顺序。
    fileprivate var loadedBVIDs: [String] {
        switch state {
        case .loaded(let items, _, _), .loadingMore(let items, _):
            items.map(\.bvid)
        case .idle, .loading, .failed:
            []
        }
    }
}
