import Observation

enum AppTab: Hashable {
    case search
    case popular
    case history
}

struct PlaybackDestination: Hashable {
    let bvid: String
}

@MainActor
@Observable
final class AppNavigationCoordinator {
    var selectedTab: AppTab = .popular {
        didSet {
            guard selectedTab != oldValue else { return }
            let previousPath = playbackPath(for: oldValue)
            setPlaybackPath([], for: oldValue)
            reconcilePlayback(from: previousPath, to: [])
        }
    }
    var searchPlaybackPath: [PlaybackDestination] = [] {
        didSet {
            guard selectedTab == .search else { return }
            reconcilePlayback(from: oldValue, to: searchPlaybackPath)
        }
    }
    var popularPlaybackPath: [PlaybackDestination] = [] {
        didSet {
            guard selectedTab == .popular else { return }
            reconcilePlayback(from: oldValue, to: popularPlaybackPath)
        }
    }
    var historyPlaybackPath: [PlaybackDestination] = [] {
        didSet {
            guard selectedTab == .history else { return }
            reconcilePlayback(from: oldValue, to: historyPlaybackPath)
        }
    }
    var playbackPath: [PlaybackDestination] {
        get {
            playbackPath(for: selectedTab)
        }
        set {
            setPlaybackPath(newValue, for: selectedTab)
        }
    }
    var searchDraft = ""

    @ObservationIgnored private let startPlayback: (String) -> Void
    @ObservationIgnored private let stopPlayback: () -> Void

    init(
        startPlayback: @escaping (String) -> Void,
        stopPlayback: @escaping () -> Void
    ) {
        self.startPlayback = startPlayback
        self.stopPlayback = stopPlayback
    }

    func openPlayback(_ bvid: String) {
        guard !bvid.isEmpty else { return }
        playbackPath = [PlaybackDestination(bvid: bvid)]
    }

    func retryPlayback() {
        guard let bvid = playbackPath.last?.bvid else { return }
        startPlayback(bvid)
    }

    func resetForWindowClosure() {
        playbackPath.removeAll()
        searchPlaybackPath.removeAll()
        popularPlaybackPath.removeAll()
        historyPlaybackPath.removeAll()
        selectedTab = .popular
        searchDraft = ""
    }

    func playbackPath(for tab: AppTab) -> [PlaybackDestination] {
        switch tab {
        case .search:
            searchPlaybackPath
        case .popular:
            popularPlaybackPath
        case .history:
            historyPlaybackPath
        }
    }

    private func reconcilePlayback(
        from oldPath: [PlaybackDestination],
        to newPath: [PlaybackDestination]
    ) {
        let oldDestination = oldPath.last
        let newDestination = newPath.last
        guard oldDestination != newDestination else { return }

        if oldDestination != nil {
            stopPlayback()
        }
        if let newDestination {
            startPlayback(newDestination.bvid)
        }
    }

    private func setPlaybackPath(
        _ path: [PlaybackDestination],
        for tab: AppTab
    ) {
        switch tab {
        case .search:
            searchPlaybackPath = path
        case .popular:
            popularPlaybackPath = path
        case .history:
            historyPlaybackPath = path
        }
    }
}
