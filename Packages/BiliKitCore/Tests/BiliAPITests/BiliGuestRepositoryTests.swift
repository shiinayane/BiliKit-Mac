import BiliAPI
import BiliApplication
import BiliModels
import Testing

struct BiliGuestRepositoryTests {
    @Test(arguments: [
        (BiliAPIError.invalidRequest, GuestApplicationError.invalidRequest),
        (BiliAPIError.nonJSONResponse, GuestApplicationError.requestRestricted),
        (BiliAPIError.noAVCVideo, GuestApplicationError.unsupportedMedia),
        (BiliAPIError.decodingFailed, GuestApplicationError.invalidResponse),
    ])
    func mapsAPIErrorAtAdapterBoundary(
        apiError: BiliAPIError,
        expected: GuestApplicationError
    ) async {
        let repository = BiliGuestRepository(
            service: FailingAPIService(error: apiError)
        )

        await #expect(throws: expected) {
            try await repository.popular(page: 1, pageSize: 20)
        }
    }

    @Test
    func preservesCancellationAtAdapterBoundary() async {
        let repository = BiliGuestRepository(
            service: FailingAPIService(error: CancellationError())
        )

        await #expect(throws: CancellationError.self) {
            try await repository.popular(page: 1, pageSize: 20)
        }
    }
}

private struct FailingAPIService: BiliAPIService {
    let error: any Error & Sendable

    func popular(page: Int, pageSize: Int) async throws -> PopularPage {
        throw error
    }

    func searchVideos(keyword: String, page: Int) async throws -> SearchPage {
        throw error
    }

    func videoDetail(for bvid: String) async throws -> VideoDetail {
        throw error
    }

    func pages(for bvid: String) async throws -> [VideoPage] {
        throw error
    }

    func playback(
        for bvid: String,
        cid: Int64,
        quality: Int
    ) async throws -> VideoPlayback {
        throw error
    }
}
