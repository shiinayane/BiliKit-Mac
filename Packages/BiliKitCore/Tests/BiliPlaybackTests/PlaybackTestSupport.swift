@preconcurrency import AVFoundation
import BiliApplication
import BiliModels
import BiliNetworking
import Foundation
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
            URL(string: "https://fixture.invalid/\(id)")
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

/// 等待计数达到 `count` 的调用方。
typealias CountWaiter = (count: Int, continuation: CheckedContinuation<Void, Never>)

func resumeCountWaiters(_ waiters: inout [CountWaiter], reaching count: Int) {
    let reached = waiters.filter { $0.count <= count }
    waiters.removeAll { $0.count <= count }
    for waiter in reached { waiter.continuation.resume() }
}

/// BiliPlaybackTests 唯一的 `HTTPTransport` 替身。
///
/// 按 URL 返回精确 206 Range；可让整个 URL 或指定 Range 头返回 403、隐藏完整长度，
/// 或让某些 URL 除 SIDX index 以外的 Range 挂起到调用方取消。
actor FixtureRangeTransport: HTTPTransport {
    private let media: [URL: Data]
    private let failingURLs: Set<URL>
    private let failingRangeHeaders: [URL: Set<String>]
    private let unknownLengthURLs: Set<URL>
    private let blockingURLIndexRanges: [URL: MediaByteRange]
    private(set) var requests: [HTTPRequest] = []
    private(set) var startedBlockedRequestCount = 0
    private(set) var cancelledBlockedRequestCount = 0
    private var blockedRequestWaiters: [CountWaiter] = []

    init(
        media: [URL: Data],
        failingURLs: Set<URL> = [],
        failingRangeHeaders: [URL: Set<String>] = [:],
        unknownLengthURLs: Set<URL> = [],
        blockingURLIndexRanges: [URL: MediaByteRange] = [:]
    ) {
        self.media = media
        self.failingURLs = failingURLs
        self.failingRangeHeaders = failingRangeHeaders
        self.unknownLengthURLs = unknownLengthURLs
        self.blockingURLIndexRanges = blockingURLIndexRanges
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        requests.append(request)
        let rangeHeader = request.headers.first(where: { name, _ in
            name.caseInsensitiveCompare("Range") == .orderedSame
        })?.value
        if failingURLs.contains(request.url)
            || rangeHeader.map({
                failingRangeHeaders[request.url]?.contains($0) == true
            }) == true
        {
            return HTTPResponse(statusCode: 403, body: Data())
        }
        guard let data = media[request.url],
            let rangeHeader,
            let range = Self.parseRange(rangeHeader, contentLength: data.count)
        else {
            return HTTPResponse(statusCode: 400, body: Data())
        }

        if let indexRange = blockingURLIndexRanges[request.url],
            range != indexRange
        {
            try await blockUntilCancelled()
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
            body: data.subdata(
                in: Int(range.start)..<(Int(range.endInclusive) + 1)
            )
        )
    }

    func waitForBlockedRequest() async {
        guard startedBlockedRequestCount == 0 else { return }
        await withCheckedContinuation { blockedRequestWaiters.append((1, $0)) }
    }

    private func blockUntilCancelled() async throws {
        startedBlockedRequestCount += 1
        resumeCountWaiters(
            &blockedRequestWaiters,
            reaching: startedBlockedRequestCount
        )
        do {
            try await Task.sleep(for: .seconds(60))
        } catch is CancellationError {
            cancelledBlockedRequestCount += 1
            throw CancellationError()
        }
    }

    private static func parseRange(
        _ value: String,
        contentLength: Int
    ) -> MediaByteRange? {
        guard value.hasPrefix("bytes=") else { return nil }
        let bounds = value.dropFirst("bytes=".count).split(
            separator: "-",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        guard bounds.count == 2,
            let start = Int64(bounds[0]),
            let end = Int64(bounds[1]),
            end < Int64(contentLength)
        else {
            return nil
        }
        return try? MediaByteRange(start: start, endInclusive: end)
    }
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
    private var trackRequestWaiters: [CountWaiter] = []
    private var resetWaiters: [CountWaiter] = []

    /// `holdsReset` 让每次 reset 挂起到 `releaseReset()`，用于固定加载与 reset 的串行顺序。
    init(catalog: Catalog, holdsReset: Bool = false) {
        self.catalog = catalog
        self.holdsReset = holdsReset
    }

    func tracks(
        for identity: PlaybackItemIdentity
    ) async throws -> [SubtitleTrack] {
        trackRequests.append(identity)
        resumeCountWaiters(&trackRequestWaiters, reaching: trackRequests.count)
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
        resumeCountWaiters(&resetWaiters, reaching: resetCalls.count)
        guard holdsReset else { return }
        await withCheckedContinuation { heldReset = $0 }
    }

    func waitForTrackRequests(_ count: Int) async {
        guard trackRequests.count < count else { return }
        await withCheckedContinuation { trackRequestWaiters.append((count, $0)) }
    }

    func waitForResetCalls(_ count: Int) async {
        guard resetCalls.count < count else { return }
        await withCheckedContinuation { resetWaiters.append((count, $0)) }
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

    func create(rangeClient: HTTPRangeClient) -> LoopbackPlaybackServer {
        let server = LoopbackPlaybackServer(rangeClient: rangeClient)
        lock.withLock {
            storage.append(server)
        }
        return server
    }
}

actor PlaybackFailureRecorder {
    private var recordedEvents: [PlaybackFailureEvent] = []
    private var waiters: [CountWaiter] = []

    func append(_ event: PlaybackFailureEvent) {
        recordedEvents.append(event)
        resumeCountWaiters(&waiters, reaching: recordedEvents.count)
    }

    func waitForEvents(_ count: Int) async {
        guard recordedEvents.count < count else { return }
        await withCheckedContinuation { waiters.append((count, $0)) }
    }

    func identities() -> [PlaybackItemIdentity] {
        recordedEvents.map(\.identity)
    }
}
