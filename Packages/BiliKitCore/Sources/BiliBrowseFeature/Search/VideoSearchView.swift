import SwiftUI

struct VideoSearchView: View {
    let model: GuestFeedViewModel
    @Binding var searchText: String
    @Binding var selectedBVID: String?
    let onSubmit: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                TextField("搜索 B 站视频", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(onSubmit)
                    .accessibilityIdentifier("search.field")

                Button("搜索", action: onSubmit)
                    .buttonStyle(.borderedProminent)
                    .disabled(normalizedSearchText.isEmpty)
                    .accessibilityIdentifier("search.submit")
            }
            .padding(12)

            Divider()
            results
        }
    }

    @ViewBuilder
    private var results: some View {
        switch model.state {
        case let .loading(.search(query, _)):
            ProgressView("正在搜索“\(query)”…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("search.loading")
        case let .loaded(.search(query, page)) where page.videos.isEmpty:
            ContentUnavailableView.search(text: query)
                .accessibilityIdentifier("search.empty")
        case let .loaded(.search(query, page)):
            VStack(spacing: 0) {
                HStack {
                    Text("“\(query)”")
                    Spacer()
                    Text("约 \(page.totalResults.formatted()) 条结果")
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

                List(page.videos, selection: $selectedBVID) { video in
                    GuestVideoRow(video: video)
                        .tag(video.bvid)
                }
                .listStyle(.inset)
                .accessibilityIdentifier("search.results")
                .refreshable {
                    model.search(query, page: page.pageNumber)
                    await model.waitForCurrentTask()
                }
            }
        case let .failed(request: .search(_, _), error: error):
            BrowseFailureView(
                title: error.guestTitle,
                message: error.guestMessage,
                retry: model.retry
            )
            .accessibilityIdentifier("search.failure")
        default:
            ContentUnavailableView(
                "搜索视频",
                systemImage: "magnifyingglass",
                description: Text("输入关键词后按下 Return 或点击搜索。")
            )
            .accessibilityIdentifier("search.prompt")
        }
    }

    private var normalizedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
