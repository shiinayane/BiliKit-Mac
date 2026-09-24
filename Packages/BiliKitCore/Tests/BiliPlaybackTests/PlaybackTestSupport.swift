@preconcurrency import AVFoundation
import BiliApplication
import BiliModels
import BiliNetworking
import Foundation
import Synchronization
import Testing

@testable import BiliPlayback

enum PlaybackFixtureError: Error {
    case timedOut
    case missingPort
    case invalidIndependentResponse
    case invalidFixture
}

// MARK: - Fixture 媒体

func fixtureData(named name: String) throws -> Data {
    let url = try #require(
        Bundle.module.url(
            forResource: name,
            withExtension: "mp4",
            subdirectory: "Fixtures"
        )
    )
    return try Data(contentsOf: url)
}

func fixtureBase64Data(named name: String) throws -> Data {
    let url = try #require(
        Bundle.module.url(
            forResource: name,
            withExtension: "base64",
            subdirectory: "Fixtures"
        )
    )
    return try #require(
        Data(
            base64Encoded: try Data(contentsOf: url),
            options: .ignoreUnknownCharacters
        )
    )
}

func firstTopLevelBox(
    named expectedType: String,
    in data: Data
) -> (offset: Int, size: Int)? {
    var offset = 0
    while offset + 8 <= data.count {
        let size = Int(readUInt32(in: data, at: offset))
        let type = String(
            data: data.subdata(in: (offset + 4)..<(offset + 8)),
            encoding: .ascii
        )
        guard size >= 8, offset + size <= data.count else {
            return nil
        }
        if type == expectedType {
            return (offset, size)
        }
        offset += size
    }
    return nil
}

func readUInt32(in data: Data, at offset: Int) -> UInt32 {
    data[offset..<(offset + 4)].reduce(UInt32(0)) { value, byte in
        (value << 8) | UInt32(byte)
    }
}

func makeFixtureTrack(
    id: Int,
    kind: MediaKind,
    codecs: String,
    bandwidth: Int,
    data: Data,
    primaryURL: URL? = nil,
    backupURLs: [URL] = [],
    videoAttributes: VideoRepresentationAttributes? = nil
) throws -> (representation: MediaRepresentation, index: SegmentIndex) {
    let sidx = try #require(firstTopLevelBox(named: "sidx", in: data))
    let resolvedVideoAttributes: VideoRepresentationAttributes? =
        if kind == .video {
            if let videoAttributes {
                videoAttributes
            } else {
                try VideoRepresentationAttributes(
                    width: 128,
                    height: 72,
                    frameRate: 24
                )
            }
        } else {
            nil
        }
    let representation = MediaRepresentation(
        id: id,
        kind: kind,
        codecs: codecs,
        mimeType: kind == .video ? "video/mp4" : "audio/mp4",
        bandwidth: bandwidth,
        videoAttributes: resolvedVideoAttributes,
        primaryURL: try primaryURL ?? #require(
            URL(string: "https://media.fixture.bilivideo.com/\(id)")
        ),
        backupURLs: backupURLs,
        segmentBase: SegmentBase(
            initialization: try MediaByteRange(
                start: 0,
                endInclusive: Int64(sidx.offset - 1)
            ),
            index: try MediaByteRange(
                start: Int64(sidx.offset),
                endInclusive: Int64(sidx.offset + sidx.size - 1)
            )
        )
    )
    let index = try SIDXParser().parse(
        data.subdata(in: sidx.offset..<(sidx.offset + sidx.size)),
        boxStartOffset: UInt64(sidx.offset)
    )
    return (representation, index)
}

/// 两秒 128x72 AVC 与 AAC fixture，挂在给定 host 的独立远端 URL 上。
func makeSimpleMedia(
    host: String
) throws -> (
    video: MediaRepresentation,
    audio: MediaRepresentation,
    media: [URL: Data]
) {
    let videoData = try fixtureData(named: "video-avc")
    let audioData = try fixtureData(named: "audio-aac")
    let videoURL = try #require(URL(string: "https://\(host)/video"))
    let audioURL = try #require(URL(string: "https://\(host)/audio"))
    let video = try makeFixtureTrack(
        id: 80,
        kind: .video,
        codecs: "avc1.4d400b",
        bandwidth: 50_000,
        data: videoData,
        primaryURL: videoURL
    ).representation
    let audio = try makeFixtureTrack(
        id: 30_280,
        kind: .audio,
        codecs: "mp4a.40.2",
        bandwidth: 96_000,
        data: audioData,
        primaryURL: audioURL
    ).representation
    return (video, audio, [videoURL: videoData, audioURL: audioData])
}

func makeSelectedAudioTrack(
    trackID: String = "original",
    displayName: String = "原声",
    languageTag: String? = nil,
    role: PlaybackAudioTrack.Role = .original,
    isDefault: Bool = true,
    isAutoselect: Bool = true,
    representation: MediaRepresentation
) -> SelectedPlaybackAudioTrack {
    let track = PlaybackAudioTrack(
        id: trackID,
        displayName: displayName,
        languageTag: languageTag,
        role: role,
        isDefault: isDefault,
        isAutoselect: isAutoselect,
        representations: [representation]
    )
    return SelectedPlaybackAudioTrack(
        track: track,
        representation: representation
    )
}

// MARK: - Loopback 读取

func fetchText(_ url: URL) async throws -> String {
    let data = try await URLSession.shared.data(from: url).0
    return try #require(String(data: data, encoding: .utf8))
}

func localizedRenditionNames(
    besideMaster masterURL: URL
) async throws -> [String: [String: String]] {
    let url = masterURL.deletingLastPathComponent()
        .appending(path: "metadata/localized-rendition-names.json")
    let data = try await URLSession.shared.data(from: url).0
    return try #require(
        try JSONSerialization.jsonObject(with: data)
            as? [String: [String: String]]
    )
}

/// 旧 session 的 URL 只要不能再返回 200 即视为已释放：连接被拒绝，或端口被复用
/// 但 session token 不同而返回 404。
func isServing(_ url: URL) async -> Bool {
    guard let (_, response) = try? await URLSession.shared.data(from: url)
    else { return false }
    return (response as? HTTPURLResponse)?.statusCode == 200
}

// MARK: - 事件等待；固定时长只作超时

/// 返回 stream 中第一个满足条件的元素。
func awaitFirst<Element: Sendable>(
    in stream: AsyncStream<Element>,
    timeout: Duration = .seconds(10),
    where predicate: @escaping @Sendable (Element) -> Bool
) async throws -> Element {
    try await withThrowingTaskGroup(of: Element.self) { group in
        group.addTask {
            for await element in stream where predicate(element) {
                return element
            }
            throw CancellationError()
        }
        group.addTask {
            try await Task.sleep(for: timeout)
            throw PlaybackFixtureError.timedOut
        }
        defer { group.cancelAll() }
        guard let first = try await group.next() else {
            throw PlaybackFixtureError.timedOut
        }
        return first
    }
}

/// 以 engine 的统一时间线事件等待状态，不轮询 player。
@MainActor
@discardableResult
func waitForTimeline(
    of engine: AVPlayerEngine,
    where predicate: @escaping @Sendable (PlaybackTimelineSnapshot) -> Bool
) async throws -> PlaybackTimelineSnapshot {
    try await awaitFirst(in: engine.timelineUpdates(), where: predicate)
}

/// 以 KVO 事件等待 AVPlayer 进入指定状态。
func waitUntilTimeControlStatus(
    of player: AVPlayer,
    is expected: AVPlayer.TimeControlStatus
) async throws {
    let (statuses, continuation) = AsyncStream.makeStream(
        of: AVPlayer.TimeControlStatus.self
    )
    let observation = player.observe(
        \.timeControlStatus,
        options: [.initial, .new]
    ) { observedPlayer, _ in
        continuation.yield(observedPlayer.timeControlStatus)
    }
    defer {
        observation.invalidate()
        continuation.finish()
    }
    _ = try await awaitFirst(in: statuses) { $0 == expected }
}

// MARK: - 替身

/// 由持有者在自己的隔离域内同步使用的计数等待表；计数本身由持有者保存与推进。
struct CountWaiters {
    private var pending: [(target: Int, continuation: CheckedContinuation<Void, Never>)] = []

    /// `current` 已达到 `target` 时立即恢复，否则登记到 `resume(reaching:)`。
    mutating func add(
        _ continuation: CheckedContinuation<Void, Never>,
        until target: Int,
        current: Int
    ) {
        if current >= target {
            continuation.resume()
        } else {
            pending.append((target, continuation))
        }
    }

    mutating func resume(reaching count: Int) {
        let ready = pending.filter { $0.target <= count }
        pending.removeAll { $0.target <= count }
        for waiter in ready {
            waiter.continuation.resume()
        }
    }
}

extension Array where Element == CheckedContinuation<Void, Never> {
    /// 放行并清空全部挂起者。
    mutating func resumeAll() {
        let pending = self
        removeAll()
        for continuation in pending {
            continuation.resume()
        }
    }
}

/// BiliPlaybackTests 唯一的媒体 Range 替身，同时服务 `HTTPTransport`（SIDX／音频格式读取）
/// 与 `HTTPRangeStreaming`（loopback 媒体转发）。
///
/// 按 URL 返回精确 206 Range；可让整个 URL 或指定 Range 头失败、隐藏完整长度、在响应头后
/// 截断正文，或让某些 URL 除 SIDX index 以外的 Range 挂起到调用方取消。
actor FixtureRangeTransport: HTTPTransport, HTTPRangeStreaming {
    private let media: [URL: Data]
    private let failingURLs: Set<URL>
    private let failingRangeHeaders: [URL: Set<String>]
    private let unknownLengthURLs: Set<URL>
    private let truncatedBodyLengths: [URL: Int]
    private let blockingURLIndexRanges: [URL: MediaByteRange]
    private let invalidation = Mutex(false)
    private(set) var requests: [HTTPRequest] = []
    private(set) var startedBlockedRequestCount = 0
    private(set) var cancelledBlockedRequestCount = 0
    private var blockedRequestWaiters = CountWaiters()
    private var cancelledRequestWaiters = CountWaiters()

    init(
        media: [URL: Data],
        failingURLs: Set<URL> = [],
        failingRangeHeaders: [URL: Set<String>] = [:],
        unknownLengthURLs: Set<URL> = [],
        truncatedBodyLengths: [URL: Int] = [:],
        blockingURLIndexRanges: [URL: MediaByteRange] = [:]
    ) {
        self.media = media
        self.failingURLs = failingURLs
        self.failingRangeHeaders = failingRangeHeaders
        self.unknownLengthURLs = unknownLengthURLs
        self.truncatedBodyLengths = truncatedBodyLengths
        self.blockingURLIndexRanges = blockingURLIndexRanges
    }

    nonisolated var wasInvalidated: Bool {
        invalidation.withLock { $0 }
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        requests.append(request)
        guard
            let rangeHeader = request.headers.first(where: { name, _ in
                name.caseInsensitiveCompare("Range") == .orderedSame
            })?.value,
            let range = Self.parseRange(rangeHeader),
            let data = try await admit(request.url, rangeHeader: rangeHeader, range: range)
        else {
            return HTTPResponse(statusCode: 403, body: Data())
        }
        let completeLength =
            unknownLengthURLs.contains(request.url)
            ? "*" : String(data.count)
        return HTTPResponse(
            statusCode: 206,
            headers: [
                "Content-Range":
                    "bytes \(range.start)-\(range.endInclusive)/\(completeLength)"
            ],
            body: Self.slice(data, range)
        )
    }

    /// 与真实 streamer 一样先确认完整长度再放行响应头，并把正文分两个 chunk 交给下游。
    func stream(
        from url: URL,
        rangeHeader: String,
        expectedRange: HTTPByteRange,
        expectedCompleteLength: Int64,
        headers: [String: String],
        allowedContentTypes: Set<String>?,
        onResponse: @escaping @Sendable (HTTPRangeStreamResponse) async throws -> Void,
        onChunk: @escaping @Sendable (Data) async throws -> Void
    ) async throws -> HTTPRangeStreamResult {
        var requestHeaders = headers
        requestHeaders["Range"] = rangeHeader
        requests.append(HTTPRequest(url: url, headers: requestHeaders))
        let range = try MediaByteRange(
            start: expectedRange.start,
            endInclusive: expectedRange.endInclusive
        )
        guard let data = try await admit(url, rangeHeader: rangeHeader, range: range)
        else {
            throw HTTPRangeResponseError.statusCode(403)
        }
        guard !unknownLengthURLs.contains(url) else {
            throw HTTPRangeResponseError.missingCompleteLength
        }
        guard Int64(data.count) == expectedCompleteLength else {
            throw HTTPRangeResponseError.mismatchedCompleteLength(
                expected: expectedCompleteLength,
                actual: Int64(data.count)
            )
        }
        try await onResponse(
            HTTPRangeStreamResponse(
                contentRange: try HTTPContentRange(
                    start: expectedRange.start,
                    endInclusive: expectedRange.endInclusive,
                    completeLength: expectedCompleteLength
                ),
                contentLength: expectedRange.length,
                contentType: nil
            )
        )
        let body = Self.slice(data, range)
        if let truncatedLength = truncatedBodyLengths[url] {
            if truncatedLength > 0 {
                try await onChunk(body.prefix(truncatedLength))
            }
            throw HTTPRangeResponseError.bodyLengthMismatch(
                expected: expectedRange.length,
                actual: UInt64(truncatedLength)
            )
        }
        let midpoint = max(1, body.count / 2)
        try await onChunk(body.prefix(midpoint))
        if midpoint < body.count {
            try await onChunk(body.suffix(from: body.startIndex + midpoint))
        }
        return HTTPRangeStreamResult(byteCount: UInt64(body.count))
    }

    nonisolated func invalidate() {
        invalidation.withLock { $0 = true }
    }

    func waitForBlockedRequest() async {
        await withCheckedContinuation {
            blockedRequestWaiters.add($0, until: 1, current: startedBlockedRequestCount)
        }
    }

    func waitForCancelledBlockedRequests(_ count: Int) async {
        await withCheckedContinuation {
            cancelledRequestWaiters.add($0, until: count, current: cancelledBlockedRequestCount)
        }
    }

    /// 返回可服务的完整媒体；nil 表示该请求被配置为失败或越界。
    private func admit(
        _ url: URL,
        rangeHeader: String,
        range: MediaByteRange
    ) async throws -> Data? {
        guard !failingURLs.contains(url),
            failingRangeHeaders[url]?.contains(rangeHeader) != true,
            let data = media[url],
            range.endInclusive < Int64(data.count)
        else { return nil }
        if let indexRange = blockingURLIndexRanges[url], range != indexRange {
            try await blockUntilCancelled()
        }
        return data
    }

    private func blockUntilCancelled() async throws {
        startedBlockedRequestCount += 1
        blockedRequestWaiters.resume(reaching: startedBlockedRequestCount)
        do {
            try await Task.sleep(for: .seconds(60))
        } catch is CancellationError {
            cancelledBlockedRequestCount += 1
            cancelledRequestWaiters.resume(reaching: cancelledBlockedRequestCount)
            throw CancellationError()
        }
    }

    private static func slice(_ data: Data, _ range: MediaByteRange) -> Data {
        data.subdata(in: Int(range.start)..<(Int(range.endInclusive) + 1))
    }

    private static func parseRange(_ value: String) -> MediaByteRange? {
        guard value.hasPrefix("bytes=") else { return nil }
        let bounds = value.dropFirst("bytes=".count).split(
            separator: "-",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        guard bounds.count == 2,
            let start = Int64(bounds[0]),
            let end = Int64(bounds[1])
        else {
            return nil
        }
        return try? MediaByteRange(start: start, endInclusive: end)
    }
}

/// 用同一个 fixture 替身同时提供 SIDX 读取与 loopback 媒体转发的 bridge。
func makeFixtureBridge(_ transport: FixtureRangeTransport) -> DASHToHLSBridge {
    DASHToHLSBridge(
        rangeClient: HTTPRangeClient(transport: transport),
        serverFactory: { LoopbackPlaybackServer(rangeStreamer: transport) }
    )
}

/// BiliPlaybackTests 唯一的 `SubtitleRepository` 替身。
actor FixtureSubtitleRepository: SubtitleRepository {
    enum Catalog: Sendable {
        case tracks([SubtitleTrack])
        case failure
        /// `tracks` 不响应取消，挂起到 `releaseTracks()`。
        case heldUntilReleased([SubtitleTrack])
    }

    private let catalog: Catalog
    private let holdsReset: Bool
    private(set) var trackRequests: [PlaybackItemIdentity] = []
    private(set) var resetCalls: [PlaybackItemIdentity] = []
    private var heldTracks: CheckedContinuation<Void, Never>?
    private var heldReset: CheckedContinuation<Void, Never>?
    private var trackRequestWaiters = CountWaiters()
    private var resetWaiters = CountWaiters()

    /// `holdsReset` 让每次 reset 挂起到 `releaseReset()`，用于固定加载与 reset 的串行顺序。
    init(catalog: Catalog, holdsReset: Bool = false) {
        self.catalog = catalog
        self.holdsReset = holdsReset
    }

    func tracks(
        for identity: PlaybackItemIdentity
    ) async throws -> [SubtitleTrack] {
        trackRequests.append(identity)
        trackRequestWaiters.resume(reaching: trackRequests.count)
        switch catalog {
        case .tracks(let tracks):
            return tracks
        case .failure:
            throw SubtitleApplicationError.transportFailure
        case .heldUntilReleased(let tracks):
            await withCheckedContinuation { heldTracks = $0 }
            return tracks
        }
    }

    func cues(
        for trackID: String,
        identity: PlaybackItemIdentity
    ) async throws -> [SubtitleCue] {
        if case .failure = catalog {
            throw SubtitleApplicationError.transportFailure
        }
        return []
    }

    func reset(for identity: PlaybackItemIdentity) async {
        resetCalls.append(identity)
        resetWaiters.resume(reaching: resetCalls.count)
        guard holdsReset else { return }
        await withCheckedContinuation { heldReset = $0 }
    }

    func waitForTrackRequests(_ count: Int) async {
        await withCheckedContinuation {
            trackRequestWaiters.add($0, until: count, current: trackRequests.count)
        }
    }

    func waitForResetCalls(_ count: Int) async {
        await withCheckedContinuation {
            resetWaiters.add($0, until: count, current: resetCalls.count)
        }
    }

    func releaseTracks() {
        heldTracks?.resume()
        heldTracks = nil
    }

    func releaseReset() {
        heldReset?.resume()
        heldReset = nil
    }
}

final class LoopbackServerRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [LoopbackPlaybackServer] = []

    var servers: [LoopbackPlaybackServer] {
        lock.withLock { storage }
    }

    func create() -> LoopbackPlaybackServer {
        let server = LoopbackPlaybackServer()
        lock.withLock {
            storage.append(server)
        }
        return server
    }
}

actor PlaybackFailureRecorder {
    private var recordedEvents: [PlaybackFailureEvent] = []
    private var waiters = CountWaiters()

    func append(_ event: PlaybackFailureEvent) {
        recordedEvents.append(event)
        waiters.resume(reaching: recordedEvents.count)
    }

    func waitForEvents(_ count: Int) async {
        await withCheckedContinuation {
            waiters.add($0, until: count, current: recordedEvents.count)
        }
    }

    func identities() -> [PlaybackItemIdentity] {
        recordedEvents.map(\.identity)
    }
}
