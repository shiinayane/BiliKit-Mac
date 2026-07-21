import BiliApplication
import BiliModels
import Foundation
import Testing

struct WatchHistoryUseCaseTests {
    @Test
    func forwardsContinuationAndPageSizeToRepository() async throws {
        let repository = WatchHistoryRepositoryStub(
            pages: [WatchHistoryPage(items: [], continuation: nil)]
        )
        let useCase = WatchHistoryUseCase(repository: repository)
        let continuation = token(123)

        _ = try await useCase.load(after: continuation, pageSize: 30)

        #expect(await repository.requests() == [
            Request(continuation: continuation, pageSize: 30),
        ])
    }

    @Test
    func rejectsInvalidPageSizeBeforeCallingRepository() async {
        let repository = WatchHistoryRepositoryStub(pages: [])
        let useCase = WatchHistoryUseCase(repository: repository)

        await #expect(throws: WatchHistoryError.invalidResponse) {
            try await useCase.load(pageSize: 0)
        }
        #expect(await repository.requests().isEmpty)
    }

    @Test
    func skipsFilteredEmptyPagesUntilItemsAreDisplayable() async throws {
        let firstToken = token(1)
        let secondToken = token(2)
        let repository = WatchHistoryRepositoryStub(
            pages: [
                WatchHistoryPage(items: [], continuation: firstToken),
                WatchHistoryPage(items: [], continuation: secondToken),
                WatchHistoryPage(items: [item("BV1HistoryA1")], continuation: nil),
            ]
        )
        let useCase = WatchHistoryUseCase(repository: repository)

        let page = try await useCase.load()

        #expect(page.items.map(\.bvid) == ["BV1HistoryA1"])
        #expect(await repository.requests().map(\.continuation) == [nil, firstToken, secondToken])
    }

    @Test
    func boundedEmptyPageScanPreservesManualContinuation() async throws {
        let firstToken = token(1)
        let secondToken = token(2)
        let repository = WatchHistoryRepositoryStub(
            pages: [
                WatchHistoryPage(items: [], continuation: firstToken),
                WatchHistoryPage(items: [], continuation: secondToken),
            ]
        )
        let useCase = WatchHistoryUseCase(
            repository: repository,
            maximumEmptyPagesToSkip: 1
        )

        let page = try await useCase.load()

        #expect(page.items.isEmpty)
        #expect(page.continuation == secondToken)
        #expect(await repository.requests().map(\.continuation) == [nil, firstToken])
    }

    @Test
    func rejectsNonAdvancingEmptyPageCursor() async {
        let repeatedToken = token(1)
        let repository = WatchHistoryRepositoryStub(
            pages: [WatchHistoryPage(items: [], continuation: repeatedToken)]
        )
        let useCase = WatchHistoryUseCase(repository: repository)

        await #expect(throws: WatchHistoryError.invalidResponse) {
            try await useCase.load(after: repeatedToken)
        }
    }
}

private func token(_ value: Int64) -> WatchHistoryContinuation {
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

private struct Request: Sendable, Equatable {
    let continuation: WatchHistoryContinuation?
    let pageSize: Int
}

private actor WatchHistoryRepositoryStub: WatchHistoryRepository {
    private var observedRequests: [Request] = []
    private var pages: [WatchHistoryPage]

    init(pages: [WatchHistoryPage]) {
        self.pages = pages
    }

    func watchHistory(
        after continuation: WatchHistoryContinuation?,
        pageSize: Int
    ) throws -> WatchHistoryPage {
        observedRequests.append(
            Request(continuation: continuation, pageSize: pageSize)
        )
        guard !pages.isEmpty else {
            throw WatchHistoryError.invalidResponse
        }
        return pages.removeFirst()
    }

    func requests() -> [Request] {
        observedRequests
    }
}
