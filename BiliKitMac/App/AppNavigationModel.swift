import Observation

enum AppSection: Hashable {
    case search
    case popular
    case history
}

struct PlaybackDestination: Hashable {
    let bvid: String
}

@MainActor
@Observable
final class AppNavigationModel {
    var selectedSection: AppSection = .popular {
        didSet {
            guard selectedSection != oldValue else { return }
            playbackPath.removeAll()
        }
    }
    var playbackPath: [PlaybackDestination] = [] {
        didSet {
            reconcilePlayback(from: oldValue, to: playbackPath)
        }
    }
    var searchQuery = ""

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

    func closeWindow() {
        playbackPath.removeAll()
        selectedSection = .popular
        searchQuery = ""
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
}
