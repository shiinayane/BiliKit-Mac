import BiliApplication
import Foundation
import SwiftUI

public struct BrowseNavigationView<PlayerContent: View>: View {
    private let feedModel: GuestFeedViewModel
    private let videoModel: GuestVideoViewModel
    private let subtitleModel: SubtitleViewModel
    private let playerContent: () -> PlayerContent
    @Binding private var requestedBVID: String?

    @State private var selectedSection: GuestSection? = .popular
    @State private var selectedBVID: String?
    @State private var searchText = ""
    @State private var submittedQuery: String?
    @State private var searchRevision = 0

    public init(
        feedModel: GuestFeedViewModel,
        videoModel: GuestVideoViewModel,
        subtitleModel: SubtitleViewModel,
        requestedBVID: Binding<String?> = .constant(nil),
        @ViewBuilder playerContent: @escaping () -> PlayerContent
    ) {
        self.feedModel = feedModel
        self.videoModel = videoModel
        self.subtitleModel = subtitleModel
        _requestedBVID = requestedBVID
        self.playerContent = playerContent
    }

    public var body: some View {
        NavigationSplitView {
            List(selection: $selectedSection) {
                Label("热门", systemImage: "flame")
                    .tag(GuestSection.popular)
                    .accessibilityIdentifier("sidebar.popular")
                Label("搜索", systemImage: "magnifyingglass")
                    .tag(GuestSection.search)
                    .accessibilityIdentifier("sidebar.search")
            }
            .navigationTitle("BiliKit")
            .navigationSplitViewColumnWidth(
                min: 160,
                ideal: 180,
                max: 220
            )
        } content: {
            feedColumn
                .navigationTitle(selectedSection?.title ?? "BiliKit")
                .navigationSplitViewColumnWidth(
                    min: 300,
                    ideal: 360,
                    max: 460
                )
        } detail: {
            detailColumn
        }
        .onChange(of: selectedBVID) { _, bvid in
            guard let bvid else { return }
            videoModel.selectVideo(bvid)
        }
        .onChange(of: requestedBVID) { _, bvid in
            guard let bvid else { return }
            if selectedBVID == bvid {
                videoModel.selectVideo(bvid)
            } else {
                selectedBVID = bvid
            }
            requestedBVID = nil
        }
        .task(id: feedTaskID) {
            let intent = feedTaskID
            selectedBVID = nil
            videoModel.reset()
            guard !Task.isCancelled else { return }
            switch intent {
            case .popular:
                feedModel.loadPopular()
                await feedModel.waitForCurrentTask()
            case .search(nil, _), .none:
                feedModel.cancel()
            case let .search(.some(query), _):
                feedModel.search(query)
                await feedModel.waitForCurrentTask()
            }
        }
    }

    @ViewBuilder
    private var feedColumn: some View {
        switch selectedSection {
        case .popular:
            PopularFeedView(
                model: feedModel,
                selectedBVID: $selectedBVID
            )
        case .search:
            VideoSearchView(
                model: feedModel,
                searchText: $searchText,
                selectedBVID: $selectedBVID,
                onSubmit: performSearch
            )
        case nil:
            ContentUnavailableView(
                "选择一个入口",
                systemImage: "sidebar.left"
            )
        }
    }

    private var detailColumn: some View {
        VideoDetailColumn(
            model: videoModel,
            subtitleModel: subtitleModel,
            playerContent: playerContent
        )
    }

    private var normalizedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var feedTaskID: GuestFeedTaskID {
        switch selectedSection {
        case .popular:
            .popular
        case .search:
            .search(query: submittedQuery, revision: searchRevision)
        case nil:
            .none
        }
    }

    private func performSearch() {
        let query = normalizedSearchText
        guard !query.isEmpty else { return }
        searchText = query
        selectedBVID = nil
        submittedQuery = query
        searchRevision += 1
    }
}

private enum GuestFeedTaskID: Hashable {
    case popular
    case search(query: String?, revision: Int)
    case none
}

private enum GuestSection: String, Hashable {
    case popular
    case search

    var title: String {
        switch self {
        case .popular:
            "热门"
        case .search:
            "搜索"
        }
    }
}
