import BiliApplication
import BiliModels
import Foundation
import Testing

@testable import BiliVideoDetailFeature

/// 空间层的状态覆盖与头部投稿数只按空间状态呈现；未登录也能读取，没有登录提示。
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
        let presentation = UploaderSpaceSidebarPresentation(state: state, totalCount: 61)
        #expect(presentation.overlay == expected)
    }

    @Test
    func headerHidesAnUnknownOrZeroTotal() {
        #expect(
            UploaderSpaceSidebarPresentation(state: .loading, totalCount: nil).headerTotalCount
                == nil
        )
        #expect(
            UploaderSpaceSidebarPresentation(state: .loaded([]), totalCount: 0).headerTotalCount
                == nil
        )
        #expect(
            UploaderSpaceSidebarPresentation(state: .loaded(videos(1)), totalCount: 61)
                .headerTotalCount == 61
        )
    }
}

private func videos(_ count: Int) -> [UploaderVideo] {
    (0..<count).map { index in
        .testFixture(bvid: "BV1Fixture\(index)", title: "投稿 \(index)")
    }
}
