import BiliModels
import BiliNetworking
import Foundation

public struct CDNBenchmarkDiscoveredSample: Sendable, Equatable {
    public let videoRepresentation: MediaRepresentation
    public let mediaHeaders: [String: String]

    public init(
        videoRepresentation: MediaRepresentation,
        mediaHeaders: [String: String]
    ) {
        self.videoRepresentation = videoRepresentation
        self.mediaHeaders = mediaHeaders
    }
}

/// 只为已登录用户的显式测速发现近期低播放量公开视频；内容 identity 不越过该 adapter。
public actor CDNBenchmarkSampleDiscoverer {
    public static let maximumMetadataCount = 40
    public static let maximumDetailRequestCount = 8
    public static let maximumPlaybackRequestCount = 8
    public static let supportedSampleCounts = 1...3

    private static let regionIDs = [201, 124, 228, 207, 208, 209, 229, 231]
    private static let pageSize = 5
    private static let minimumViewCount: Int64 = 20
    private static let maximumViewCount: Int64 = 9_999
    private static let minimumAge: TimeInterval = 6 * 60 * 60
    private static let maximumAge: TimeInterval = 14 * 24 * 60 * 60
    private static let minimumDuration = 3 * 60
    private static let minimumQualityID = 64
    private static let minimumBandwidth = 500_000
    private static let minimumShortSide = 720

    private let client: BiliAPIClient
    private let now: @Sendable () -> Date
    private let regionIDs: [Int]
    private var seenBVIDs: Set<String> = []

    public init(client: BiliAPIClient) {
        self.client = client
        now = Date.init
        regionIDs = Self.regionIDs
    }

    init(
        client: BiliAPIClient,
        now: @escaping @Sendable () -> Date,
        regionIDs: [Int] = CDNBenchmarkSampleDiscoverer.regionIDs
    ) {
        self.client = client
        self.now = now
        self.regionIDs = Array(regionIDs.prefix(Self.maximumPlaybackRequestCount))
    }

    public func discover(targetCount: Int = 1) async throws -> [CDNBenchmarkDiscoveredSample] {
        guard Self.supportedSampleCounts.contains(targetCount) else {
            throw BiliAPIError.invalidRequest
        }
        var qualified: [(bvid: String, sample: CDNBenchmarkDiscoveredSample)] = []
        var uploaderIDs: Set<Int64> = []
        var metadataCount = 0
        var detailRequestCount = 0
        let dateWindow = try dateWindow(at: now())

        for regionID in regionIDs {
            try Task.checkCancellation()
            guard qualified.count < targetCount,
                metadataCount < Self.maximumMetadataCount,
                detailRequestCount < Self.maximumDetailRequestCount
            else { break }
            let submissions = try await client.recentSubmissions(
                regionID: regionID,
                pageSize: Self.pageSize,
                dateFrom: dateWindow.from,
                dateTo: dateWindow.to
            )
            metadataCount += min(submissions.count, Self.pageSize)

            for submission in submissions
            where isEligible(submission)
                && !seenBVIDs.contains(submission.bvid)
                && !uploaderIDs.contains(submission.mid)
            {
                try Task.checkCancellation()
                guard detailRequestCount < Self.maximumDetailRequestCount,
                    detailRequestCount < Self.maximumPlaybackRequestCount
                else { break }
                detailRequestCount += 1
                do {
                    let detail = try await client.recentSubmissionDetail(
                        for: submission.bvid
                    )
                    guard
                        isEligible(
                            detail,
                            matching: submission,
                            regionID: regionID
                        )
                    else {
                        continue
                    }
                    try Task.checkCancellation()
                    let playback = try await client.authenticatedPlaybackForCDNBenchmark(
                        for: detail.bvid,
                        cid: detail.cid
                    )
                    guard
                        let video = highestConsumableVideo(
                            in: playback.videoRepresentations
                        ), hasComparableOrigins(video)
                    else {
                        continue
                    }
                    uploaderIDs.insert(detail.owner.mid)
                    qualified.append(
                        (
                            detail.bvid,
                            CDNBenchmarkDiscoveredSample(
                                videoRepresentation: video,
                                mediaHeaders: playback.mediaHeaders.filter {
                                    $0.key.caseInsensitiveCompare("Cookie") != .orderedSame
                                        && $0.key.caseInsensitiveCompare("Authorization")
                                            != .orderedSame
                                }
                            )
                        )
                    )
                    break
                } catch is CancellationError {
                    throw CancellationError()
                } catch let error as BiliAPIError {
                    guard Self.isCandidateLocalFailure(error) else { throw error }
                    continue
                } catch {
                    throw error
                }
            }
        }
        try Task.checkCancellation()
        if qualified.count == targetCount {
            seenBVIDs.formUnion(qualified.map(\.bvid))
        }
        return qualified.map(\.sample)
    }

    public func resetSeenSamples() {
        seenBVIDs.removeAll()
    }

    private static func isCandidateLocalFailure(_ error: BiliAPIError) -> Bool {
        switch error {
        case .httpStatus(404), .apiRejected(code: -404, _), .missingData,
            .invalidMediaData, .noAVCVideo:
            true
        default:
            false
        }
    }

    private func isEligible(_ submission: RecentRankSubmissionPayload) -> Bool {
        let age = now().timeIntervalSince1970 - TimeInterval(submission.senddate)
        return submission.bvid.hasPrefix("BV")
            && submission.bvid.count == 12
            && submission.mid > 0
            && (Self.minimumViewCount...Self.maximumViewCount).contains(
                submission.play.value
            )
            && (Self.minimumAge...Self.maximumAge).contains(age)
            && submission.duration >= Self.minimumDuration
    }

    private func isEligible(
        _ detail: RecentSubmissionDetailPayload,
        matching submission: RecentRankSubmissionPayload,
        regionID: Int
    ) -> Bool {
        let age = now().timeIntervalSince1970 - TimeInterval(detail.pubdate)
        return detail.bvid == submission.bvid
            && detail.cid > 0
            && detail.tid == regionID
            && detail.owner.mid == submission.mid
            && detail.duration >= Self.minimumDuration
            && (Self.minimumAge...Self.maximumAge).contains(age)
    }

    private func dateWindow(at date: Date) throws -> (from: String, to: String) {
        var calendar = Calendar(identifier: .gregorian)
        guard let timeZone = TimeZone(secondsFromGMT: 8 * 60 * 60) else {
            throw BiliAPIError.invalidRequest
        }
        calendar.timeZone = timeZone
        guard let to = calendar.date(byAdding: .day, value: -1, to: date),
            let from = calendar.date(byAdding: .day, value: -13, to: to)
        else {
            throw BiliAPIError.invalidRequest
        }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyyMMdd"
        return (formatter.string(from: from), formatter.string(from: to))
    }

    private func highestConsumableVideo(
        in videos: [MediaRepresentation]
    ) -> MediaRepresentation? {
        videos.filter { video in
            guard video.codecs.lowercased().hasPrefix("avc"),
                video.id >= Self.minimumQualityID,
                let bandwidth = video.bandwidth,
                bandwidth >= Self.minimumBandwidth,
                let attributes = video.videoAttributes,
                min(attributes.width, attributes.height) >= Self.minimumShortSide
            else { return false }
            return true
        }.max { lhs, rhs in
            let left = (
                lhs.bandwidth ?? 0,
                (lhs.videoAttributes?.width ?? 0) * (lhs.videoAttributes?.height ?? 0),
                lhs.id
            )
            let right = (
                rhs.bandwidth ?? 0,
                (rhs.videoAttributes?.width ?? 0) * (rhs.videoAttributes?.height ?? 0),
                rhs.id
            )
            return left < right
        }
    }

    private func hasComparableOrigins(_ video: MediaRepresentation) -> Bool {
        let hosts = video.urlCandidates.compactMap { $0.host?.lowercased() }
        let hasAkamai = hosts.contains {
            $0 == "akamaized.net" || $0.hasSuffix(".akamaized.net")
                || $0 == "akamaihd.net" || $0.hasSuffix(".akamaihd.net")
        }
        let hasBilivideo = hosts.contains {
            $0 == "bilivideo.com" || $0.hasSuffix(".bilivideo.com")
                || $0 == "bilivideo.cn" || $0.hasSuffix(".bilivideo.cn")
        }
        return hasAkamai && hasBilivideo
    }
}
