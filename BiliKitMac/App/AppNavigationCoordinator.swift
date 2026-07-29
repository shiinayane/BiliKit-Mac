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
            replacePlaybackPath([], for: oldValue)
            reconcilePlayback(from: previousPath, to: [])
        }
    }
    private(set) var searchPlaybackPath: [PlaybackDestination] = []
    private(set) var popularPlaybackPath: [PlaybackDestination] = []
    private(set) var historyPlaybackPath: [PlaybackDestination] = []
    var playbackPath: [PlaybackDestination] {
        get {
            playbackPath(for: selectedTab)
        }
        set {
            updatePlaybackPath(newValue, for: selectedTab)
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
        let previousPath = playbackPath
        replacePlaybackPath([], for: .search)
        replacePlaybackPath([], for: .popular)
        replacePlaybackPath([], for: .history)
        reconcilePlayback(from: previousPath, to: [])
        selectedTab = .popular
        searchDraft = ""
    }

    func updatePlaybackPath(
        _ path: [PlaybackDestination],
        for tab: AppTab
    ) {
        guard selectedTab == tab else { return }
        let previousPath = playbackPath(for: tab)
        guard previousPath != path else { return }
        replacePlaybackPath(path, for: tab)
        reconcilePlayback(from: previousPath, to: path)
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

    private func replacePlaybackPath(
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
