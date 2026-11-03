import BiliApplication
import BiliModels
import Foundation
import Testing

@testable import BiliVideoDetailFeature

/// 相关推荐与 UP 主名片是不阻塞播放的增强：失败只隐藏自己并可单独重试，旧结果按身份丢弃，同一 UP 主的名片在播放期间复用。
@Suite(.timeLimit(.minutes(1)))
struct VideoViewModelEnhancementTests {
    @Test(.timeLimit(.minutes(1)))
    @MainActor
    func relatedVideoABARejectsOldSameBVIDResult() async throws {
        let fixture = ContentFixtures()
        let relatedRepository = RelatedRepositoryStub()
        let model = makeVideoViewModel(
            useCase: VideoUseCase(
                repository: VideoRepositoryStub(fixture)
            ),
            playback: PlayerStub(),
            relatedVideoUseCase: RelatedVideoUseCase(
                repository: relatedRepository
            )
        )

        let staleA = SpawnedTasks { model.loadVideo("BV1RelatedAA") }
        await relatedRepository.waitForRequestCount(1)
        let staleB = SpawnedTasks { model.loadVideo("BV1RelatedBB") }
        await relatedRepository.waitForRequestCount(2)
        model.loadVideo("BV1RelatedAA")
        await relatedRepository.waitForRequestCount(3)

        let newResult = RelatedVideo.testFixture(bvid: "BV1CurrentAA1")
        await relatedRepository.releaseRequest(2, videos: [newResult])
        await waitForObservedState {
            model.relatedVideoState
                == .loaded(bvid: "BV1RelatedAA", videos: [newResult])
        }

        await relatedRepository.releaseRequest(
            0,
            videos: [.testFixture(bvid: "BV1StaleAAA1")]
        )
        await relatedRepository.releaseRequest(1, videos: [])
        await staleA.finished()
        await staleB.finished()

        #expect(
            model.relatedVideoState
                == .loaded(bvid: "BV1RelatedAA", videos: [newResult])
        )
    }

    @Test
    @MainActor
    func relatedVideoFailureRetriesWithoutReloadingPlayback() async {
        let fixture = ContentFixtures()
        let relatedRepository = RelatedRepositoryStub(
            responses: [
                .failure(.transportFailure),
                .success([.testFixture(bvid: "BV1RetryVid1")])
            ]
        )
        let player = PlayerStub()
        let model = makeVideoViewModel(
            useCase: VideoUseCase(
                repository: VideoRepositoryStub(fixture)
            ),
            playback: player,
            relatedVideoUseCase: RelatedVideoUseCase(
                repository: relatedRepository
            )
        )

        model.loadVideo(fixture.bvid)
        await waitUntilSettled(model)
        await waitForObservedState {
            model.relatedVideoState
                == .failed(bvid: fixture.bvid, error: .transportFailure)
        }

        model.retryRelatedVideos()
        await waitForObservedState {
            model.relatedVideoState
                == .loaded(
                    bvid: fixture.bvid,
                    videos: [.testFixture(bvid: "BV1RetryVid1")]
                )
        }

        #expect(player.loadedPlaybacks.count == 1)
        #expect(await relatedRepository.callCount == 2)
    }

    @Test(.timeLimit(.minutes(1)))
    @MainActor
    func uploaderProfileLoadsWithoutBlockingReadyDetail() async throws {
        let fixture = ContentFixtures()
        let profileRepository = ProfileRepositoryStub()
        let model = makeVideoViewModel(
            useCase: VideoUseCase(
                repository: VideoRepositoryStub(fixture)
            ),
            playback: PlayerStub(),
            uploaderProfileUseCase: UploaderProfileUseCase(
                repository: profileRepository
            )
        )

        model.loadVideo(fixture.bvid)
        await waitUntilSettled(model)
        await profileRepository.waitForRequestCount(1)

        #expect(model.presentedContext?.detail == fixture.detail)
        #expect(model.uploaderProfileState == .loading)

        await profileRepository.releaseRequest(
            0,
            profile: UploaderProfile(signature: "公开签名", isVIP: true)
        )
        await waitForObservedState {
            model.uploaderProfileState
                == .loaded(UploaderProfile(signature: "公开签名", isVIP: true))
        }
    }

    @Test
    @MainActor
    func uploaderProfileFailureHidesOnlyEnhancement() async {
        let fixture = ContentFixtures()
        let model = makeVideoViewModel(
            useCase: VideoUseCase(
                repository: VideoRepositoryStub(fixture)
            ),
            playback: PlayerStub(),
            uploaderProfileUseCase: UploaderProfileUseCase(
                repository: ProfileRepositoryStub(immediate: .failure(.transportFailure))
            )
        )

        model.loadVideo(fixture.bvid)
        await waitUntilSettled(model)
        await waitForObservedState { model.uploaderProfileState != .loading }

        #expect(
            model.state
                == .ready(
                    VideoContext(
                        detail: fixture.detail,
                        pages: [fixture.page],
                        selectedPage: fixture.page,
                        playback: fixture.playback
                    )
                )
        )
        #expect(model.uploaderProfileState == .loaded(UploaderProfile()))
    }

    /// 相关推荐与 UP 主名片只是增强，但凭据失效仍要交给窗口复核。
    @Test
    @MainActor
    func enhancementCredentialInvalidationRequestsRevalidation() async {
        let fixture = ContentFixtures()
        let model = makeVideoViewModel(
            useCase: VideoUseCase(
                repository: VideoRepositoryStub(fixture)
            ),
            playback: PlayerStub(),
            relatedVideoUseCase: RelatedVideoUseCase(
                repository: RelatedRepositoryStub(responses: [.failure(.authenticationInvalid)])
            ),
            uploaderProfileUseCase: UploaderProfileUseCase(
                repository: ProfileRepositoryStub(immediate: .failure(.authenticationInvalid))
            )
        )

        model.loadVideo(fixture.bvid)
        await waitUntilSettled(model)
        await waitForObservedState {
            model.uploaderProfileState != .loading
                && model.relatedVideoState != .loading(bvid: fixture.bvid)
        }

        #expect(model.authenticationRevalidationGeneration == 2)
        #expect(model.uploaderProfileState == .loaded(UploaderProfile()))
    }

    @Test
    @MainActor
    func pageSwitchDoesNotReloadUploaderProfile() async {
        let fixture = ContentFixtures()
        let profileRepository = ProfileRepositoryStub(
            immediate: .success(UploaderProfile(signature: "公开签名"))
        )
        let model = makeVideoViewModel(
            useCase: VideoUseCase(
                repository: VideoRepositoryStub(fixture, pages: fixture.twoPages)
            ),
            playback: PlayerStub(),
            uploaderProfileUseCase: UploaderProfileUseCase(
                repository: profileRepository
            )
        )

        model.loadVideo(fixture.bvid)
        await waitUntilSettled(model)
        await waitForObservedState { model.uploaderProfileState != .loading }
        model.selectPage(cid: 900_002)
        await waitUntilSettled(model)

        #expect(model.uploaderProfileState == .loaded(UploaderProfile(signature: "公开签名")))
        #expect(await profileRepository.callCount == 1)
    }

    /// 同一 UP 主的下一个视频直接沿用名片，不再请求；离开播放后重新请求。
    @Test
    @MainActor
    func sameOwnerNextVideoReusesLoadedProfileUntilReset() async {
        let first = ContentFixtures(bvid: "BV1SameOwnerA", title: "视频 A")
        let second = ContentFixtures(bvid: "BV1SameOwnerB", title: "视频 B")
        let profile = UploaderProfile(signature: "公开签名", isVIP: true)
        let profileRepository = ProfileRepositoryStub(immediate: .success(profile))
        let model = makeVideoViewModel(
            useCase: VideoUseCase(
                repository: VideoRepositoryStub(fixtures: [first, second])
            ),
            playback: PlayerStub(),
            uploaderProfileUseCase: UploaderProfileUseCase(
                repository: profileRepository
            )
        )

        model.loadVideo(first.bvid)
        await waitUntilSettled(model)
        await waitForObservedState { model.uploaderProfileState == .loaded(profile) }
        model.loadVideo(second.bvid)
        await waitUntilSettled(model)

        #expect(model.presentedContext?.detail.bvid == second.bvid)
        #expect(model.uploaderProfileState == .loaded(profile))
        #expect(await profileRepository.callCount == 1)

        model.reset()
        model.loadVideo(first.bvid)
        await waitUntilSettled(model)
        await waitForObservedState { model.uploaderProfileState == .loaded(profile) }

        #expect(await profileRepository.callCount == 2)
    }

    @Test
    @MainActor
    func failedProfileIsNotReusedForTheSameOwner() async {
        let first = ContentFixtures(bvid: "BV1FailedOwnerA", title: "视频 A")
        let second = ContentFixtures(bvid: "BV1FailedOwnerB", title: "视频 B")
        let profileRepository = ProfileRepositoryStub(
            immediate: .failure(.transportFailure)
        )
        let model = makeVideoViewModel(
            useCase: VideoUseCase(
                repository: VideoRepositoryStub(fixtures: [first, second])
            ),
            playback: PlayerStub(),
            uploaderProfileUseCase: UploaderProfileUseCase(
                repository: profileRepository
            )
        )

        model.loadVideo(first.bvid)
        await waitUntilSettled(model)
        await waitForObservedState { model.uploaderProfileState != .loading }
        model.loadVideo(second.bvid)
        await waitUntilSettled(model)
        await waitForObservedState { model.uploaderProfileState != .loading }

        #expect(model.uploaderProfileState == .loaded(UploaderProfile()))
        #expect(await profileRepository.callCount == 2)
    }

    @Test(.timeLimit(.minutes(1)))
    @MainActor
    func uploaderProfileABARejectsOldSameOwnerResult() async throws {
        let first = ContentFixtures(bvid: "BV1SignatureA", title: "视频 A")
        let second = ContentFixtures(bvid: "BV1SignatureB", title: "视频 B")
        let profileRepository = ProfileRepositoryStub()
        let model = makeVideoViewModel(
            useCase: VideoUseCase(
                repository: VideoRepositoryStub(fixtures: [first, second])
            ),
            playback: PlayerStub(),
            uploaderProfileUseCase: UploaderProfileUseCase(
                repository: profileRepository
            )
        )

        let staleA = SpawnedTasks { model.loadVideo(first.bvid) }
        await waitUntilSettled(model)
        await profileRepository.waitForRequestCount(1)

        let staleB = SpawnedTasks { model.loadVideo(second.bvid) }
        await waitUntilSettled(model)
        await profileRepository.waitForRequestCount(2)
        model.loadVideo(first.bvid)
        await waitUntilSettled(model)
        await profileRepository.waitForRequestCount(3)

        await profileRepository.releaseRequest(2, profile: UploaderProfile(signature: "新 A 签名"))
        await waitForObservedState {
            model.uploaderProfileState == .loaded(UploaderProfile(signature: "新 A 签名"))
        }
        await profileRepository.releaseRequest(0, profile: UploaderProfile(signature: "旧 A 签名"))
        await profileRepository.releaseRequest(1, profile: UploaderProfile(signature: "旧 B 签名"))
        await staleA.finished()
        await staleB.finished()

        #expect(model.presentedContext?.detail.bvid == first.bvid)
        #expect(model.uploaderProfileState == .loaded(UploaderProfile(signature: "新 A 签名")))
    }

    @Test(.timeLimit(.minutes(1)))
    @MainActor
    func resetCancelsAndIsolatesLateUploaderProfile() async throws {
        let fixture = ContentFixtures()
        let profileRepository = ProfileRepositoryStub()
        let model = makeVideoViewModel(
            useCase: VideoUseCase(
                repository: VideoRepositoryStub(fixture)
            ),
            playback: PlayerStub(),
            uploaderProfileUseCase: UploaderProfileUseCase(
                repository: profileRepository
            )
        )

        let stale = SpawnedTasks { model.loadVideo(fixture.bvid) }
        await waitUntilSettled(model)
        await profileRepository.waitForRequestCount(1)
        model.reset()
        await profileRepository.releaseRequest(0, profile: UploaderProfile(signature: "迟到签名"))
        await stale.finished()

        #expect(model.state == .idle)
        #expect(model.presentedContext == nil)
        #expect(model.uploaderProfileState == .loaded(UploaderProfile()))
    }
}
