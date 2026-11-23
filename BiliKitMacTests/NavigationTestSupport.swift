import BiliApplication
import BiliBrowseFeature
import BiliVideoDetailFeature

@testable import BiliKit

/// 导航协调器的测试构造：转场默认同步换页并立即完成（与生产里找不到分栏时的退路一致），播放默认有画面且在播放；
/// 开始、暂停、继续与停止由调用方记录。
@MainActor
func makeNavigationCoordinator(
    startPlayback: @escaping (PlaybackSelectionIntent) -> Void = { _ in },
    stopPlayback: @escaping () -> Void = {},
    pausePlayback: @escaping () -> Bool = { true },
    isPlaying: @escaping () -> Bool = { true },
    resumePlayback: @escaping () -> Void = {},
    presentedPosition: @escaping () -> Double? = { nil },
    resumePoint: @escaping () -> PlaybackSelectionIntent? = { nil },
    recentlyWatchedEntry:
        @escaping (PlaybackSelectionIntent) -> RecentlyWatchedVideo? = { _ in nil },
    isPictureInPictureActive: @escaping () -> Bool = { false },
    transitionPage:
        @escaping (
            AppPageTransition, _ change: () -> Void, _ completion: @escaping () -> Void
        ) -> Void = { _, change, completion in
            change()
            completion()
        },
    transitionSidebarContext:
        @escaping (AppPageTransition, _ change: () -> Void) -> Void = { _, change in change() },
    uploaderSpace: UploaderSpaceViewModel = makeUploaderSpace(),
    uploaderSpacePage: UploaderSpaceViewModel = makeUploaderSpace(),
    searchPage: SearchPageModel = makeSearchPage()
) -> AppNavigationCoordinator {
    AppNavigationCoordinator(
        playback: AppPlaybackSession(
            start: startPlayback,
            stop: stopPlayback,
            pauseKeepingPicture: pausePlayback,
            isPlaying: isPlaying,
            resume: resumePlayback,
            presentedPosition: presentedPosition,
            resumePoint: resumePoint,
            recentlyWatchedEntry: recentlyWatchedEntry,
            isPictureInPictureActive: isPictureInPictureActive
        ),
        transitionPage: transitionPage,
        transitionSidebarContext: transitionSidebarContext,
        uploaderSpace: uploaderSpace,
        uploaderSpacePage: uploaderSpacePage,
        searchPage: searchPage
    )
}

/// 压栈搜索页的测试构造：搜索请求按 `FeedRepositoryStub` 的默认结果完成，搜索历史的写入交给 `recordHistory`。
@MainActor
func makeSearchPage(
    recordHistory: @escaping @MainActor (String) -> Void = { _ in }
) -> SearchPageModel {
    let browseModel = BrowseViewModel(useCase: FeedUseCase(repository: FeedRepositoryStub()))
    return SearchPageModel(
        session: VideoSearchSession(browseModel: browseModel, recordHistory: recordHistory),
        browseModel: browseModel
    )
}
