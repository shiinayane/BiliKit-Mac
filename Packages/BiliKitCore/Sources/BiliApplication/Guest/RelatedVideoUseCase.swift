import BiliModels

public struct RelatedVideoUseCase: Sendable {
    private let repository: any RelatedVideoRepository

    public init(repository: any RelatedVideoRepository) {
        self.repository = repository
    }

    public func relatedVideos(to bvid: String) async throws -> [RelatedVideo] {
        guard !bvid.isEmpty else {
            throw GuestApplicationError.invalidRequest
        }
        let videos = try await repository.relatedVideos(to: bvid)
        try Task.checkCancellation()
        var seenBVIDs: Set<String> = []
        return videos.filter { video in
            video.bvid != bvid && seenBVIDs.insert(video.bvid).inserted
        }
    }
}
