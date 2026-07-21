import BiliApplication
import BiliModels
import Foundation
import Testing

struct WatchHistoryUseCaseTests {
    @Test
    func forwardsCursorAndPageSizeToRepository() async throws {
        let repository = WatchHistoryRepositoryStub()
        let useCase = WatchHistoryUseCase(repository: repository)
        let cursor = WatchHistoryCursor(
            maximum: 123,
            viewedAt: 456,
            business: "archive"
        )

        _ = try await useCase.load(after: cursor, pageSize: 30)

        #expect(await repository.requests() == [
            Request(cursor: cursor, pageSize: 30),
        ])
    }

    @Test
    func rejectsInvalidPageSizeBeforeCallingRepository() async {
        let repository = WatchHistoryRepositoryStub()
        let useCase = WatchHistoryUseCase(repository: repository)

        await #expect(throws: WatchHistoryError.invalidResponse) {
            try await useCase.load(pageSize: 0)
        }
        #expect(await repository.requests().isEmpty)
    }
}

private struct Request: Sendable, Equatable {
    let cursor: WatchHistoryCursor?
    let pageSize: Int
}

private actor WatchHistoryRepositoryStub: WatchHistoryRepository {
    private var observedRequests: [Request] = []

    func watchHistory(
        after cursor: WatchHistoryCursor?,
        pageSize: Int
    ) -> WatchHistoryPage {
        observedRequests.append(Request(cursor: cursor, pageSize: pageSize))
        return WatchHistoryPage(items: [], nextCursor: nil)
    }

    func requests() -> [Request] {
        observedRequests
    }
}
