import BiliApplication
import BiliModels
import Foundation
import Testing

@testable import BiliBrowseFeature

/// 热搜词刷新期间与刷新失败时保留已显示的词。
///
/// 首次加载失败给出失败态，再次刷新可恢复；`reset` 清空。
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct TrendingSearchViewModelTests {
    @Test
    func firstLoadFailureIsPresentedAndRetryLoads() async {
        let repository = TrendingSearchRepositoryStub(results: [
            .failure(ContentApplicationError.transportFailure),
            .success([.fixture("词一")])
        ])
        let model = TrendingSearchViewModel(
            useCase: TrendingSearchUseCase(repository: repository)
        )

        model.refresh()
        #expect(model.state == .loading)
        await waitForObservedState { model.state != .loading }
        #expect(model.state == .failed(.transportFailure))

        model.refresh()
        #expect(model.state == .loading)
        await waitForObservedState { model.state != .loading }
        #expect(model.state == .loaded([.fixture("词一")]))
    }

    @Test
    func refreshKeepsShowingLoadedKeywordsWhileReloading() async {
        let repository = TrendingSearchRepositoryStub(results: [
            .success([.fixture("词一")]),
            .success([.fixture("词二")])
        ])
        let model = TrendingSearchViewModel(
            useCase: TrendingSearchUseCase(repository: repository)
        )
        model.refresh()
        await waitForObservedState { model.state == .loaded([.fixture("词一")]) }

        model.refresh()

        #expect(model.state == .loaded([.fixture("词一")]))
        await waitForObservedState { model.state == .loaded([.fixture("词二")]) }
    }

    @Test
    func refreshFailureNeverReplacesAvailableKeywords() {
        let loaded = TrendingSearchViewModel.State.loaded([.fixture("词一")])

        #expect(
            TrendingSearchViewModel.state(after: .failure(.transportFailure), replacing: loaded)
                == loaded
        )
        #expect(
            TrendingSearchViewModel.state(after: .failure(.transportFailure), replacing: .loading)
                == .failed(.transportFailure)
        )
        #expect(
            TrendingSearchViewModel.state(after: .success([]), replacing: loaded)
                == .loaded([])
        )
    }

    @Test
    func resetDiscardsKeywords() async {
        let repository = TrendingSearchRepositoryStub(results: [.success([.fixture("词一")])])
        let model = TrendingSearchViewModel(
            useCase: TrendingSearchUseCase(repository: repository)
        )
        model.refresh()
        await waitForObservedState { model.state == .loaded([.fixture("词一")]) }

        model.reset()

        #expect(model.state == .idle)
    }
}

/// 按调用顺序返回预设结果；用完后重复最后一个。
private actor TrendingSearchRepositoryStub: TrendingSearchRepository {
    private var results: [Result<[TrendingSearchKeyword], ContentApplicationError>]

    init(results: [Result<[TrendingSearchKeyword], ContentApplicationError>]) {
        self.results = results
    }

    func trendingSearchKeywords(limit: Int) async throws -> [TrendingSearchKeyword] {
        let result = results.count > 1 ? results.removeFirst() : results[0]
        return try result.get()
    }
}

extension TrendingSearchKeyword {
    fileprivate static func fixture(_ keyword: String) -> TrendingSearchKeyword {
        TrendingSearchKeyword(keyword: keyword, displayName: keyword, iconURL: nil)
    }
}
