import Observation

enum AppSection: Hashable {
    case search
    case popular
    case history
}

enum AppRoute: Hashable {
    case section(AppSection)
    case playback(bvid: String)
}

struct AppReturnSnapshot: Equatable {
    let sourceSection: AppSection
    let searchQuery: String
    let selectedBVID: String
}

@MainActor
@Observable
final class AppNavigationModel {
    private(set) var route: AppRoute = .section(.popular)
    private(set) var returnSnapshot: AppReturnSnapshot?
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

    var selectedSection: AppSection? {
        get {
            guard case let .section(section) = route else { return nil }
            return section
        }
        set {
            guard let newValue else { return }
            selectSection(newValue)
        }
    }

    func selectSection(_ section: AppSection) {
        if case .playback = route {
            stopPlayback()
        }
        route = .section(section)
        returnSnapshot = nil
    }

    func openPlayback(_ bvid: String) {
        guard !bvid.isEmpty else { return }
        switch route {
        case let .section(section):
            returnSnapshot = AppReturnSnapshot(
                sourceSection: section,
                searchQuery: searchQuery,
                selectedBVID: bvid
            )
        case let .playback(currentBVID):
            guard currentBVID != bvid else { return }
            stopPlayback()
        }
        route = .playback(bvid: bvid)
        startPlayback(bvid)
    }

    func returnFromPlayback() {
        guard case .playback = route else { return }
        stopPlayback()
        if let returnSnapshot {
            searchQuery = returnSnapshot.searchQuery
            route = .section(returnSnapshot.sourceSection)
        } else {
            route = .section(.popular)
        }
    }

    func retryPlayback() {
        guard case let .playback(bvid) = route else { return }
        startPlayback(bvid)
    }

    func authenticationDidBecomeSignedOut() {
        if returnSnapshot?.sourceSection == .history {
            returnSnapshot = nil
        }
    }

    func closeWindow() {
        if case .playback = route {
            stopPlayback()
        }
        route = .section(.popular)
        returnSnapshot = nil
        searchQuery = ""
    }
}
