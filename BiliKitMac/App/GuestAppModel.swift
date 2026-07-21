import BiliAPI
import BiliPlayback
import Foundation
import Observation

enum GuestFeedRequest: Sendable, Equatable {
    case popular(page: Int, pageSize: Int)
    case search(query: String, page: Int)
}

enum GuestFeedContent: Sendable, Equatable {
    case popular(PopularPage)
    case search(query: String, page: SearchPage)
}

enum GuestFeedState: Sendable, Equatable {
    case idle
    case loading(GuestFeedRequest)
    case loaded(GuestFeedContent)
    case failed(request: GuestFeedRequest, error: BiliAPIError)
}

enum GuestFlowFailure: Sendable, Equatable {
    case api(BiliAPIError)
    case playback
}

enum GuestSelectionState: Sendable, Equatable {
    case idle
    case loading(bvid: String)
    case preparingPlayback(GuestVideoContext)
    case ready(GuestVideoContext)
    case failed(bvid: String, failure: GuestFlowFailure)
}

@MainActor
@Observable
final class GuestAppModel {
    private(set) var feedState: GuestFeedState = .idle
    private(set) var selectionState: GuestSelectionState = .idle

    @ObservationIgnored private let api: any BiliAPIService
    @ObservationIgnored private let coordinator: GuestVideoCoordinator
    @ObservationIgnored private let playerEngine: any PlayerEngine
    @ObservationIgnored private let makePlaybackRequest: @Sendable (VideoPlayback) -> PlaybackRequest
    @ObservationIgnored private var feedTask: Task<Void, Never>?
    @ObservationIgnored private var selectionTask: Task<Void, Never>?
    @ObservationIgnored private var feedGeneration = 0
    @ObservationIgnored private var selectionGeneration = 0

    init(
        api: any BiliAPIService,
        playerEngine: any PlayerEngine,
        makePlaybackRequest: @escaping @Sendable (VideoPlayback) -> PlaybackRequest
    ) {
        self.api = api
        coordinator = GuestVideoCoordinator(api: api)
        self.playerEngine = playerEngine
        self.makePlaybackRequest = makePlaybackRequest
    }

    func loadPopular(page: Int = 1, pageSize: Int = 20) {
        loadFeed(.popular(page: page, pageSize: pageSize))
    }

    func search(_ query: String, page: Int = 1) {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let request = GuestFeedRequest.search(query: normalizedQuery, page: page)
        guard !normalizedQuery.isEmpty,
              normalizedQuery.count <= 100,
              page > 0
        else {
            failFeed(request: request, error: .invalidRequest)
            return
        }
        loadFeed(request)
    }

    func retryFeed() {
        guard case let .failed(request, _) = feedState else { return }
        loadFeed(request)
    }

    func cancelFeed() {
        feedGeneration += 1
        feedTask?.cancel()
        feedTask = nil
        feedState = .idle
    }

    func resetSelection() async {
        selectionGeneration += 1
        selectionTask?.cancel()
        selectionTask = nil
        selectionState = .idle
        await coordinator.cancel()
        playerEngine.pause()
    }

    private func loadFeed(_ request: GuestFeedRequest) {
        feedGeneration += 1
        let generation = feedGeneration
        feedTask?.cancel()
        feedState = .loading(request)
        feedTask = Task { [weak self] in
            await self?.performFeedLoad(
                request: request,
                generation: generation
            )
        }
    }

    private func failFeed(request: GuestFeedRequest, error: BiliAPIError) {
        feedGeneration += 1
        feedTask?.cancel()
        feedTask = nil
        feedState = .failed(request: request, error: error)
    }

    func selectVideo(_ bvid: String, quality: Int = 32) {
        selectionGeneration += 1
        let generation = selectionGeneration
        selectionTask?.cancel()
        selectionState = .loading(bvid: bvid)
        selectionTask = Task { [weak self] in
            await self?.performSelection(
                bvid: bvid,
                quality: quality,
                generation: generation
            )
        }
    }

    func waitForFeed() async {
        await feedTask?.value
    }

    func waitForSelection() async {
        await selectionTask?.value
    }

    func cancel() async {
        cancelFeed()
        await resetSelection()
    }

    private func performFeedLoad(
        request: GuestFeedRequest,
        generation: Int
    ) async {
        do {
            let content: GuestFeedContent
            switch request {
            case let .popular(page, pageSize):
                content = .popular(
                    try await api.popular(page: page, pageSize: pageSize)
                )
            case let .search(query, page):
                content = .search(
                    query: query,
                    page: try await api.searchVideos(keyword: query, page: page)
                )
            }
            try Task.checkCancellation()
            guard feedGeneration == generation else { return }
            feedState = .loaded(content)
        } catch is CancellationError {
            guard feedGeneration == generation else { return }
            feedState = .idle
        } catch let error as BiliAPIError {
            guard feedGeneration == generation else { return }
            feedState = .failed(request: request, error: error)
        } catch {
            guard feedGeneration == generation else { return }
            feedState = .failed(request: request, error: .transportFailure)
        }
        if feedGeneration == generation {
            feedTask = nil
        }
    }

    private func performSelection(
        bvid: String,
        quality: Int,
        generation: Int
    ) async {
        await coordinator.selectVideo(bvid, quality: quality)
        guard !Task.isCancelled, selectionGeneration == generation else {
            return
        }

        switch await coordinator.state {
        case let .ready(context):
            selectionState = .preparingPlayback(context)
            do {
                try await playerEngine.load(makePlaybackRequest(context.playback))
                try Task.checkCancellation()
                guard selectionGeneration == generation else { return }
                selectionState = .ready(context)
            } catch is CancellationError {
                guard selectionGeneration == generation else { return }
                selectionState = .idle
            } catch {
                guard selectionGeneration == generation else { return }
                selectionState = .failed(bvid: bvid, failure: .playback)
            }
        case let .failed(_, error):
            selectionState = .failed(bvid: bvid, failure: .api(error))
        case .idle:
            selectionState = .idle
        case .loading:
            selectionState = .failed(
                bvid: bvid,
                failure: .api(.transportFailure)
            )
        }

        if selectionGeneration == generation {
            selectionTask = nil
        }
    }
}
