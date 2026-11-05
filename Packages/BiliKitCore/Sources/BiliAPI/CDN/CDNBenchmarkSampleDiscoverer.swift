import BiliApplication
import BiliModels
import BiliNetworking
import Foundation

/// 一个合格测速样本：最高可消费的 AVC 视频表示，以及去掉凭据与 Range 头的媒体请求头；不含 BVID
/// 等内容 identity。
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
///
/// 进程内一个，由 `ProcessComposition` 以线路测速专用的 API client 构造，设置窗口的测速模型调用；
/// 取消跟随调用方的 Task。actor 拥有 `seenBVIDs`：凑满目标数的一轮把样本 BVID 记下，
/// 之后的发现跳过它们，让再次测速换一批样本；设置窗口关闭或失去测速资格时调用方经
/// `resetSeenSamples()` 清空。
public actor CDNBenchmarkSampleDiscoverer {
    /// 一轮最多计入的近期投稿条数（分区数 × 每页条数）；与下面的详情上限一起限定发现阶段的请求量。
    private static let maximumMetadataCount = regionIDs.count * pageSize
    /// 一轮最多请求的稿件详情次数；每个详情至多引出一次 playurl，playurl 次数因此也以它为上限。
    ///
    /// 调大更容易凑满样本但多发账户读取，调小会让候选不合格时更常找不到样本。
    private static let maximumDetailRequestCount = 8

    /// 依次查询的分区 ID；每个分区至多取一个样本，同一 UP 主不重复，
    /// 让多个样本来自不同内容与上传者。
    private static let regionIDs = [201, 124, 228, 207, 208, 209, 229, 231]
    /// 每个分区读取的近期投稿条数，取近期投稿读取允许的上限。
    private static let pageSize = BiliAPIClient.maximumRecentSubmissionPageSize
    /// 样本条件（设置界面所说的“近期、低播放量且足够长”）：播放量 20–9999、发布 6 小时到 14 天、
    /// 时长至少 3 分钟。
    ///
    /// 详情返回后再核对一次发布时间与时长；调整任一条件都改变能选中的稿件范围，
    /// 收紧会更常找不到样本。
    private static let minimumViewCount: Int64 = 20
    private static let maximumViewCount: Int64 = 9_999
    private static let minimumAge: TimeInterval = 6 * 60 * 60
    private static let maximumAge: TimeInterval = 14 * 24 * 60 * 60
    private static let minimumDuration = 3 * 60
    /// 视频表示的下限：清晰度 ID ≥ 64（720P）、码率 ≥ 500 kbps、短边 ≥ 720；
    /// 低于这些的表示不参与挑选。
    private static let minimumQualityID = 64
    private static let minimumBandwidth = 500_000
    private static let minimumShortSide = 720

    private let client: BiliAPIClient
    /// 时钟边界：样本条件按发布时间筛选、查询窗口按日期计算；`init(client:)` 读系统时间。
    private let now: @Sendable () -> Date
    private var seenBVIDs: Set<String> = []

    public init(client: BiliAPIClient) {
        self.init(client: client, now: Date.init)
    }

    init(client: BiliAPIClient, now: @escaping @Sendable () -> Date) {
        self.client = client
        self.now = now
    }

    public func discover(targetCount: Int = 1) async throws -> [CDNBenchmarkDiscoveredSample] {
        // 样本数超出 `PlaybackRouteBenchmarkPolicy.supportedSampleCounts` 按 `invalidRequest` 拒绝。
        guard PlaybackRouteBenchmarkPolicy.supportedSampleCounts.contains(targetCount) else {
            throw BiliAPIError.invalidRequest
        }
        var qualified: [(bvid: String, sample: CDNBenchmarkDiscoveredSample)] = []
        var uploaderIDs: Set<Int64> = []
        var metadataCount = 0
        var detailRequestCount = 0
        let dateWindow = try dateWindow(at: now())

        for regionID in Self.regionIDs {
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
                guard detailRequestCount < Self.maximumDetailRequestCount else { break }
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
                                mediaHeaders: playback.mediaHeaders
                                    .removingCredentialAndRangeHeaders()
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

    /// 只影响单个候选的失败（稿件不存在、缺数据、媒体数据不合规、没有 AVC 视频）跳过该候选；认证、
    /// 风控与网络等其他失败终止整轮。
    private static func isCandidateLocalFailure(_ error: BiliAPIError) -> Bool {
        switch error {
        case .httpStatus(404), .apiRejected(code: -404, _), .missingData,
            .invalidMediaData, .noSupportedVideo:
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
            && submission.play.value.map {
                (Self.minimumViewCount...Self.maximumViewCount).contains($0)
            } == true
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

    /// 近期投稿的查询日期窗口：按 UTC+8 取截至前一天的 14 个自然日，与样本的发布时间条件对应。
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
        // ISO 8601 样式固定用公历与 ASCII 数字、不受用户 locale 影响，省略分隔符即接口要的 yyyyMMdd。
        let format = Date.ISO8601FormatStyle(dateSeparator: .omitted, timeZone: timeZone)
            .year().month().day()
        return (from.formatted(format), to.formatted(format))
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

    /// 样本的候选地址须同时含 Akamai 与 bilivideo 主机，测速才能在两类线路间比较。
    ///
    /// 这里的后缀匹配只做线路分类；候选地址在 DTO 映射时已经过 `BiliMediaCDNURLPolicy`
    /// 来源校验（见 SECURITY-MODEL §4）。
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
