import BiliApplication
import BiliModels
import BiliUI
import Foundation
import Observation

@testable import BiliBrowseFeature

/// 本 target 共用的等待、闸门与 Feed 替身；各测试文件不再各自复制。

/// 等待 `@Observable` 状态满足条件：每次被追踪属性变化后才重新判断，超时由测试的 time limit 兜底。
@MainActor
func waitForObservedState(_ condition: @escaping @MainActor () -> Bool) async {
    while !condition() {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            withObservationTracking {
                _ = condition()
            } onChange: {
                continuation.resume()
            }
        }
    }
}

/// 让替身中的请求挂起到测试放行；放行后后续请求直接通过。
///
/// 挂起期间忽略取消以模拟迟到结果，但记录取消事件，测试据此确认旧意图已被新意图取消。
///
/// 使用约定：请求进入后到 `open()` 之前，只用不会 throw 的断言或本闸门自己的等待（它们失败时先放行）；
/// 其他会 throw 的步骤放到 `open()` 之后，否则测试提前结束会让挂起的请求永不恢复。
actor TestGate {
    private let entries = TestEventCounter()
    private let cancellations = TestEventCounter()
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func pass() async {
        await entries.signal()
        guard !isOpen else { return }
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                waiters.append(continuation)
            }
        } onCancel: {
            Task { await self.cancellations.signal() }
        }
    }

    /// 等到第 `count` 个请求进入；等待失败时先放行，避免挂起的请求拖住测试。
    func waitForEntries(_ count: Int = 1) async throws {
        do {
            try await entries.wait(until: count)
        } catch {
            open()
            throw error
        }
    }

    /// 等到第 `count` 个挂起中的请求被取消；等待失败时先放行。
    func waitForCancellations(_ count: Int = 1) async throws {
        do {
            try await cancellations.wait(until: count)
        } catch {
            open()
            throw error
        }
    }

    func open() {
        isOpen = true
        waiters.resumeAll()
    }
}

actor TestEventCounter {
    private struct Waiter {
        let expectedCount: Int
        let continuation: CheckedContinuation<Void, any Error>
    }

    private var count = 0
    private var waiters: [UUID: Waiter] = [:]

    func signal() {
        count += 1
        let ready = waiters.filter { count >= $0.value.expectedCount }
        for (id, waiter) in ready where waiters.removeValue(forKey: id) != nil {
            waiter.continuation.resume()
        }
    }

    func wait(until expectedCount: Int) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if count >= expectedCount {
                    continuation.resume()
                } else if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiters[id] = Waiter(
                        expectedCount: expectedCount,
                        continuation: continuation
                    )
                }
            }
        } onCancel: {
            Task {
                await self.cancelWaiter(id)
            }
        }
    }

    private func cancelWaiter(_ id: UUID) {
        waiters.removeValue(forKey: id)?.continuation.resume(
            throwing: CancellationError()
        )
    }
}

extension Array where Element == CheckedContinuation<Void, Never> {
    /// 放行并清空全部挂起者。
    mutating func resumeAll() {
        let pending = self
        removeAll()
        for continuation in pending {
            continuation.resume()
        }
    }
}

/// 由闭包回答的仓库请求；`attempt` 是同一请求第几次到达（从 1 开始），用于表达“首次失败、重试成功”。
typealias ScriptedResponse<Request, Value> =
    @Sendable (Request, _ attempt: Int) async throws -> Value

/// 单个视频在推荐、热门与搜索里的合成条目，以及据此拼出的各来源分页。
struct ContentFixtures: Sendable {
    let bvid: String
    let title: String
    let owner = VideoOwner(id: 10_001, name: "测试 UP 主")

    init(
        bvid: String = "BV1FixtureA1",
        title: String = "测试视频"
    ) {
        self.bvid = bvid
        self.title = title
    }

    var popularVideo: PopularVideo {
        PopularVideo(
            bvid: bvid,
            title: title,
            coverURL: nil,
            owner: owner,
            statistics: VideoStatistics(viewCount: 10, danmakuCount: 2, likeCount: 3),
            durationSeconds: 120,
            publishedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    var recommendedVideo: RecommendedVideo {
        RecommendedVideo(
            bvid: bvid,
            title: title,
            coverURL: nil,
            owner: owner,
            viewCount: popularVideo.statistics.viewCount,
            danmakuCount: popularVideo.statistics.danmakuCount,
            durationSeconds: popularVideo.durationSeconds,
            publishedAt: popularVideo.publishedAt,
            recommendationReason: "正在流行"
        )
    }

    var searchVideo: SearchVideo {
        SearchVideo(
            bvid: bvid,
            title: title,
            coverURL: nil,
            owner: owner,
            statistics: popularVideo.statistics,
            durationSeconds: popularVideo.durationSeconds,
            publishedAt: popularVideo.publishedAt
        )
    }

    func popularPage(
        _ request: FeedRepositoryStub.PopularRequest,
        hasMore: Bool = false
    ) -> PopularPage {
        PopularPage(
            videos: [popularVideo],
            pageNumber: request.page,
            pageSize: request.pageSize,
            hasMore: hasMore
        )
    }

    func searchPage(page: Int = 1) -> SearchPage {
        SearchPage(
            videos: [searchVideo],
            pageNumber: page,
            pageSize: 20,
            totalResults: 1,
            totalPages: 1
        )
    }

    var recommendationPage: RecommendationPage {
        RecommendationPage(
            videos: [recommendedVideo],
            continuation: nil,
            nextContinuation: RecommendationContinuation(index: 2)
        )
    }
}

/// 游客 Feed port 的共享替身：每个方法由闭包回答，并按到达顺序记录请求。
///
/// 闭包的 `attempt` 是同一请求第几次到达（从 1 开始），用于表达“首次失败、重试成功”。
actor FeedRepositoryStub: FeedRepository {
    typealias Response<Request, Value> = ScriptedResponse<Request, Value>
    typealias PopularRequest = (page: Int, pageSize: Int)

    private let recommendationResponse: Response<RecommendationContinuation?, RecommendationPage>
    private let popularResponse: Response<PopularRequest, PopularPage>
    private let searchResponse: Response<VideoSearchRequest, SearchPage>
    private(set) var recommendationRequests: [RecommendationContinuation?] = []
    private(set) var popularPages: [Int] = []
    private(set) var searchRequests: [VideoSearchRequest] = []

    /// 未配置的推荐请求视为不可用，热门与搜索返回空页。
    init(
        recommendations: Response<RecommendationContinuation?, RecommendationPage>? = nil,
        popular: Response<PopularRequest, PopularPage>? = nil,
        search: Response<VideoSearchRequest, SearchPage>? = nil
    ) {
        recommendationResponse =
            recommendations ?? { _, _ in throw ContentApplicationError.unavailable }
        popularResponse =
            popular ?? { request, _ in
                PopularPage(videos: [], pageNumber: request.page, pageSize: request.pageSize)
            }
        searchResponse =
            search ?? { request, _ in
                SearchPage(
                    videos: [],
                    pageNumber: request.page,
                    pageSize: 20,
                    totalResults: 0,
                    totalPages: 0
                )
            }
    }

    func recommendations(
        after continuation: RecommendationContinuation?
    ) async throws -> RecommendationPage {
        recommendationRequests.append(continuation)
        let attempt = recommendationRequests.filter { $0 == continuation }.count
        return try await recommendationResponse(continuation, attempt)
    }

    func popular(page: Int, pageSize: Int) async throws -> PopularPage {
        popularPages.append(page)
        let attempt = popularPages.filter { $0 == page }.count
        return try await popularResponse((page, pageSize), attempt)
    }

    func searchVideos(request: VideoSearchRequest) async throws -> SearchPage {
        searchRequests.append(request)
        let attempt = searchRequests.filter { $0 == request }.count
        return try await searchResponse(request, attempt)
    }
}

extension FeedRepositoryStub {
    /// 两页热门或搜索：第 1 页含重复卡片，第 2 页补上 `second`，可让第 2 页首次失败。
    static func pagination(
        _ feed: BrowseFeed,
        first: ContentFixtures,
        second: ContentFixtures,
        failsFirstSecondPage: Bool = false
    ) -> FeedRepositoryStub {
        let pageVideos: @Sendable (Int, Int) throws -> [ContentFixtures] = { page, attempt in
            switch page {
            case 1: return [first, first]
            case 2:
                if failsFirstSecondPage, attempt == 1 {
                    throw ContentApplicationError.transportFailure
                }
                return [first, second]
            default: throw ContentApplicationError.invalidRequest
            }
        }
        switch feed {
        case .recommendation:
            preconditionFailure("推荐使用 continuation 分页")
        case .popular:
            return FeedRepositoryStub(popular: { request, attempt in
                PopularPage(
                    videos: try pageVideos(request.page, attempt).map(\.popularVideo),
                    pageNumber: request.page,
                    pageSize: request.pageSize,
                    hasMore: request.page == 1
                )
            })
        case .search:
            return FeedRepositoryStub(search: { request, attempt in
                SearchPage(
                    videos: try pageVideos(request.page, attempt).map(\.searchVideo),
                    pageNumber: request.page,
                    pageSize: 20,
                    totalResults: 2,
                    totalPages: 2
                )
            })
        }
    }
}

/// 把推荐、热门与搜索三条 feed 的相同操作映射到各自 API，供结构相同的参数化测试共用。
enum BrowseFeed: Sendable {
    case recommendation
    case popular
    case search

    static let searchCriteria = VideoSearchCriteria(
        query: "Swift",
        order: .mostFavorited,
        duration: .thirtyToSixtyMinutes,
        publicationRange: VideoPublicationTimeRange(beginTimestamp: 100, endTimestamp: 200)
    )
    private static let popularRequest = FeedRequest.popular(page: 1, pageSize: 50)

    @MainActor
    func activate(_ model: BrowseViewModel) {
        switch self {
        case .recommendation: model.activateRecommendation()
        case .popular: model.activatePopular(pageSize: 50)
        case .search: model.activateSearch(Self.searchCriteria)
        }
    }

    var source: FeedSource {
        switch self {
        case .recommendation: .recommendation
        case .popular: .popular
        case .search: .search
        }
    }

    private var firstPageRequest: FeedRequest {
        switch self {
        case .recommendation: .recommendation(continuation: nil)
        case .popular: Self.popularRequest
        case .search: .search(VideoSearchRequest(criteria: Self.searchCriteria, page: 1))
        }
    }

    @MainActor
    func refresh(_ model: BrowseViewModel) {
        switch self {
        case .recommendation: model.refreshRecommendation()
        case .popular: model.refreshPopular(pageSize: 50)
        case .search: model.search(Self.searchCriteria)
        }
    }

    @MainActor
    func loadMore(_ model: BrowseViewModel) {
        model.loadMore(source)
    }

    @MainActor
    func pagination(
        _ model: BrowseViewModel
    ) -> (canLoadMore: Bool, tailIdentity: UInt64?, loadMoreError: ContentApplicationError?) {
        let pagination = model.pagination(for: firstPageRequest)
        return (pagination.canLoadMore, pagination.tailIdentity, pagination.loadMoreError)
    }

    @MainActor
    func loadedBVIDs(_ model: BrowseViewModel) -> [String] {
        loadedBVIDs(in: model.state)
    }

    /// 本来源已加载的卡片 BVID；状态不是本来源的已加载内容时为空。
    func loadedBVIDs(in state: FeedState) -> [String] {
        switch (self, state) {
        case (.recommendation, .loaded(.recommendation(let listing))): listing.items.map(\.bvid)
        case (.popular, .loaded(.popular(let list))): list.items.map(\.bvid)
        case (.search, .loaded(.search(_, let list))): list.items.map(\.bvid)
        default: []
        }
    }
}

extension FeedRepositoryStub {
    /// 推荐没有页码，按请求序号计数。
    func requestedPages(_ feed: BrowseFeed) -> [Int] {
        switch feed {
        case .recommendation: recommendationRequests.indices.map { $0 + 1 }
        case .popular: popularPages
        case .search: searchRequests.map(\.page)
        }
    }
}

/// 卡片写入口 `VideoCardAccountWriting` 的记录替身（本 target 唯一一份）：写入门槛恒满足，按到达顺序记录加入稍后再看的
/// BVID、「不感兴趣」与撤销；闭包在主线程调用。
@MainActor
final class RecordedWrites {
    var addedToWatchLater: [String] = []
    var disliked: [RecommendationFeedback] = []
    var cancelled: [RecommendationFeedback] = []

    var writing: VideoCardAccountWriting {
        VideoCardAccountWriting(
            isAvailable: { true },
            addToWatchLater: { [weak self] in self?.addedToWatchLater.append($0) },
            removeFromWatchLater: { _ in },
            chooseFavoriteFolders: { _ in },
            removeFromFavoriteFolder: { _ in },
            dislikeRecommendation: { [weak self] in self?.disliked.append($0) },
            cancelRecommendationDislike: { [weak self] in self?.cancelled.append($0) }
        )
    }
}
