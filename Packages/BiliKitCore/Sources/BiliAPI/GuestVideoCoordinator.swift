import Foundation

public struct GuestVideoContext: Sendable, Equatable {
    public let detail: VideoDetail
    public let pages: [VideoPage]
    public let selectedPage: VideoPage
    public let playback: VideoPlayback

    public init(
        detail: VideoDetail,
        pages: [VideoPage],
        selectedPage: VideoPage,
        playback: VideoPlayback
    ) {
        self.detail = detail
        self.pages = pages
        self.selectedPage = selectedPage
        self.playback = playback
    }
}

public enum GuestVideoState: Sendable, Equatable {
    case idle
    case loading(bvid: String)
    case ready(GuestVideoContext)
    case failed(bvid: String, error: BiliAPIError)
}

public actor GuestVideoCoordinator {
    public private(set) var state: GuestVideoState = .idle

    private let api: any BiliAPIService
    private var generation = 0
    private var loadTask: Task<GuestVideoContext, any Error>?

    public init(api: any BiliAPIService) {
        self.api = api
    }

    public func selectVideo(_ bvid: String, quality: Int = 32) async {
        generation += 1
        let currentGeneration = generation
        loadTask?.cancel()
        state = .loading(bvid: bvid)

        let api = self.api
        let task = Task<GuestVideoContext, any Error> {
            async let detail = api.videoDetail(for: bvid)
            async let pages = api.pages(for: bvid)
            let (resolvedDetail, resolvedPages) = try await (detail, pages)
            try Task.checkCancellation()
            guard let selectedPage = resolvedPages.min(by: { $0.index < $1.index }) else {
                throw BiliAPIError.missingData
            }
            let playback = try await api.playback(
                for: bvid,
                cid: selectedPage.cid,
                quality: quality
            )
            try Task.checkCancellation()
            return GuestVideoContext(
                detail: resolvedDetail,
                pages: resolvedPages.sorted(by: { $0.index < $1.index }),
                selectedPage: selectedPage,
                playback: playback
            )
        }
        loadTask = task

        do {
            let context = try await task.value
            guard generation == currentGeneration else { return }
            state = .ready(context)
            loadTask = nil
        } catch is CancellationError {
            guard generation == currentGeneration else { return }
            state = .idle
            loadTask = nil
        } catch let error as BiliAPIError {
            guard generation == currentGeneration else { return }
            state = .failed(bvid: bvid, error: error)
            loadTask = nil
        } catch {
            guard generation == currentGeneration else { return }
            state = .failed(bvid: bvid, error: .transportFailure)
            loadTask = nil
        }
    }

    public func cancel() {
        generation += 1
        loadTask?.cancel()
        loadTask = nil
        state = .idle
    }
}
