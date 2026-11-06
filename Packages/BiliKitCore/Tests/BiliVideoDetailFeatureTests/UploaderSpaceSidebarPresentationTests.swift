import BiliApplication
import BiliModels
import Foundation
import Testing

@testable import BiliVideoDetailFeature

/// 空间层的状态覆盖与头部投稿数只按空间状态呈现；搜索没有结果单独说明；未登录也能读取，没有登录提示。
struct UploaderSpaceSidebarPresentationTests {
    @Test(
        arguments: [
            (UploaderSpaceState.closed, UploaderSpaceSidebarPresentation.Overlay.none),
            (.loading, .loading),
            (.loaded(videos(1)), .none),
            (.loaded(videos(0)), .empty),
            // 失败带上原因，由视图分开说明风控、凭据与网络。
            (.failed(.authenticationInvalid), .failure(.authenticationInvalid)),
            (.failed(.requestRestricted), .failure(.requestRestricted)),
            (.failed(.transportFailure), .failure(.transportFailure))
        ]
    )
    func overlayFollowsTheSpaceState(
        state: UploaderSpaceState,
        expected: UploaderSpaceSidebarPresentation.Overlay
    ) {
        let presentation = UploaderSpaceSidebarPresentation(
            state: state,
            totalCount: 61,
            isSearching: false
        )
        #expect(presentation.overlay == expected)
    }

    /// 空间内搜索没有结果与空间本来没有投稿说法不同。
    @Test
    func emptySearchSaysNoResults() {
        #expect(
            UploaderSpaceSidebarPresentation(state: .loaded([]), totalCount: 0, isSearching: true)
                .overlay == .noResults
        )
    }

    @Test
    func headerHidesAnUnknownOrZeroTotal() {
        #expect(
            UploaderSpaceSidebarPresentation(state: .loading, totalCount: nil, isSearching: false)
                .headerTotalCount
                == nil
        )
        #expect(
            UploaderSpaceSidebarPresentation(state: .loaded([]), totalCount: 0, isSearching: false)
                .headerTotalCount
                == nil
        )
        #expect(
            UploaderSpaceSidebarPresentation(
                state: .loaded(videos(1)),
                totalCount: 61,
                isSearching: false
            )
            .headerTotalCount == 61
        )
    }
}

private func videos(_ count: Int) -> [UploaderVideo] {
    (0..<count).map { index in
        .testFixture(bvid: "BV1Fixture\(index)", title: "投稿 \(index)")
    }
}
