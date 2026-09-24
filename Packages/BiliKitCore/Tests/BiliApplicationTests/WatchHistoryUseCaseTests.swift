import BiliApplication
import BiliModels
import Foundation
import Testing

@Suite(.timeLimit(.minutes(1)))
struct WatchHistoryUseCaseTests {
    @Test
    func skipsFilteredEmptyPagesUntilItemsAreDisplayable() async throws {
        let repository = WatchHistoryRepositoryStub(
            pages: [
                WatchHistoryPage(items: [], continuation: token(1)),
                WatchHistoryPage(items: [], continuation: token(2)),
                WatchHistoryPage(items: [item("BV1HistoryA1")], continuation: nil)
            ]
        )

        let page = try await WatchHistoryUseCase(repository: repository).load()

        #expect(page.items.map(\.bvid) == ["BV1HistoryA1"])
        #expect(await repository.continuations == [nil, token(1), token(2)])
    }

    @Test
    func boundedEmptyPageScanPreservesManualContinuation() async throws {
        let repository = WatchHistoryRepositoryStub(
            pages: (1...5).map { WatchHistoryPage(items: [], continuation: token($0)) }
        )

        let page = try await WatchHistoryUseCase(repository: repository).load()

        #expect(page.items.isEmpty)
        #expect(page.continuation == token(4))
        #expect(await repository.continuations == [nil, token(1), token(2), token(3)])
    }

    @Test(arguments: [[], ["BV1HistoryA1"]])
    func rejectsNonAdvancingCursor(bvids: [String]) async {
        let repeatedToken = token(1)
        let repository = WatchHistoryRepositoryStub(
            pages: [WatchHistoryPage(items: bvids.map(item), continuation: repeatedToken)]
        )

        await #expect(throws: WatchHistoryError.invalidResponse) {
            try await WatchHistoryUseCase(repository: repository).load(after: repeatedToken)
        }
    }
}

private func token(_ value: Int) -> WatchHistoryContinuation {
    WatchHistoryContinuation(rawValue: "fixture-\(value)")
}

private func item(_ bvid: String) -> WatchHistoryItem {
    WatchHistoryItem(
        bvid: bvid,
        title: "手写历史条目",
        coverURL: nil,
        owner: VideoOwner(id: 1, name: "测试作者"),
        progressSeconds: 10,
        durationSeconds: 100,
        viewedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
}

private actor WatchHistoryRepositoryStub: WatchHistoryRepository {
    private(set) var continuations: [WatchHistoryContinuation?] = []
    private var pages: [WatchHistoryPage]

    init(pages: [WatchHistoryPage]) {
        self.pages = pages
    }

    func watchHistory(
        after continuation: WatchHistoryContinuation?,
        pageSize: Int
    ) throws -> WatchHistoryPage {
        continuations.append(continuation)
        guard !pages.isEmpty else {
            throw WatchHistoryError.invalidResponse
        }
        return pages.removeFirst()
    }
}
