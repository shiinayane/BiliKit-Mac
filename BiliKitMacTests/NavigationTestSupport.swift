import BiliVideoDetailFeature

@testable import BiliKit

/// 导航协调器的测试构造：转场默认同步换页并立即完成（与生产里找不到分栏时的退路一致），暂停与停止由调用方记录。
@MainActor
func makeNavigationCoordinator(
    startPlayback: @escaping (PlaybackSelectionIntent) -> Void = { _ in },
    stopPlayback: @escaping () -> Void = {},
    pausePlayback: @escaping () -> Bool = { true },
    transitionPage:
        @escaping (
            AppPageTransition, _ change: () -> Void, _ completion: @escaping () -> Void
        ) -> Void = { _, change, completion in
            change()
            completion()
        },
    uploaderSpace: UploaderSpaceViewModel = makeUploaderSpace()
) -> AppNavigationCoordinator {
    AppNavigationCoordinator(
        startPlayback: startPlayback,
        stopPlayback: stopPlayback,
        pausePlayback: pausePlayback,
        transitionPage: transitionPage,
        uploaderSpace: uploaderSpace
    )
}
