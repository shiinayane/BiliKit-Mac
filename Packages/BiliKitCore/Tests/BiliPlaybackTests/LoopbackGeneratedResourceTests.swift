import Foundation
import Testing

@testable import BiliPlayback

/// 按需生成的 loopback 资源对并发请求只加载一次，每个路由 generation 失败后最多重试一次。
///
/// 也固定单个等待者取消不丢弃共享结果、成功后的长度／HEAD／Range 响应、server 停止时取消进行中的加载，
/// 以及批量注册遇到冲突时整批不生效。
@Suite(.serialized, .timeLimit(.minutes(1)))
struct LoopbackGeneratedResourceTests {
    @Test
    func failedRequestCanRetryThenServesLengthHeadAndRange() async throws {
        let probe = GeneratedLoadProbe(.failsOnceThenServes(Data("WEBVTT\n".utf8)))
        let generated = try LoopbackGeneratedResource(
            contentType: "text/vtt",
            maximumContentLength: 1_024
        ) {
            try await probe.load()
        }
        let server = LoopbackPlaybackServer()
        try await server.start()
        defer { server.stop() }
        let url = try server.register(.generated(generated), at: "subtitle.vtt")

        let (firstBody, firstResponse) = try await URLSession.shared.data(
            from: url
        )
        #expect((firstResponse as? HTTPURLResponse)?.statusCode == 502)
        #expect(firstBody.isEmpty)

        let (body, response) = try await URLSession.shared.data(from: url)
        let httpResponse = try #require(response as? HTTPURLResponse)
        #expect(httpResponse.statusCode == 200)
        #expect(body == Data("WEBVTT\n".utf8))
        #expect(
            httpResponse.value(forHTTPHeaderField: "Content-Length")
                == "7"
        )

        var head = URLRequest(url: url)
        head.httpMethod = "HEAD"
        let (headBody, headResponse) = try await URLSession.shared.data(for: head)
        #expect((headResponse as? HTTPURLResponse)?.statusCode == 200)
        #expect(
            (headResponse as? HTTPURLResponse)?.value(
                forHTTPHeaderField: "Content-Length"
            ) == "7"
        )
        #expect(headBody.isEmpty)

        var range = URLRequest(url: url)
        range.setValue("bytes=0-5", forHTTPHeaderField: "Range")
        let (rangeBody, rangeResponse) = try await URLSession.shared.data(
            for: range
        )
        #expect((rangeResponse as? HTTPURLResponse)?.statusCode == 206)
        #expect(
            (rangeResponse as? HTTPURLResponse)?.value(
                forHTTPHeaderField: "Content-Range"
            ) == "bytes 0-5/7"
        )
        #expect(rangeBody == Data("WEBVTT".utf8))
        #expect(await probe.loadCount == 2)
    }

    @Test
    func concurrentRequestsCoalesceOneGeneratedLoad() async throws {
        let probe = GeneratedLoadProbe(.holdsUntilReleased(Data("WEBVTT\n".utf8)))
        let generated = try LoopbackGeneratedResource(
            contentType: "text/vtt",
            maximumContentLength: 1_024
        ) {
            try await probe.load()
        }
        let server = LoopbackPlaybackServer()
        try await server.start()
        defer { server.stop() }
        let url = try server.register(.generated(generated), at: "shared.vtt")

        async let first = URLSession.shared.data(from: url)
        async let second = URLSession.shared.data(from: url)
        await probe.waitForLoads(1)
        await probe.release()
        let results = try await [first, second]

        #expect(results.allSatisfy { $0.0 == Data("WEBVTT\n".utf8) })
        #expect(await probe.loadCount == 1)
    }

    @Test
    func cancelledWaiterDoesNotDiscardSharedSuccessfulLoad() async throws {
        let probe = GeneratedLoadProbe(.holdsUntilReleased(Data("WEBVTT\n".utf8)))
        let generated = try LoopbackGeneratedResource(
            contentType: "text/vtt",
            maximumContentLength: 1_024
        ) {
            try await probe.load()
        }
        let server = LoopbackPlaybackServer()
        try await server.start()
        defer { server.stop() }
        let url = try server.register(.generated(generated), at: "cancelled.vtt")

        let first = Task { try await URLSession.shared.data(from: url) }
        await probe.waitForLoads(1)
        first.cancel()
        _ = try? await first.value
        await probe.release()

        let (body, response) = try await URLSession.shared.data(from: url)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(body == Data("WEBVTT\n".utf8))
        #expect(await probe.loadCount == 1)
    }

    @Test
    func stoppingServerCancelsInFlightGeneratedLoad() async throws {
        let probe = GeneratedLoadProbe(.holdsUntilCancelled)
        let generated = try LoopbackGeneratedResource(
            contentType: "text/vtt",
            maximumContentLength: 1_024
        ) {
            try await probe.load()
        }
        let server = LoopbackPlaybackServer()
        try await server.start()
        defer { server.stop() }
        let url = try server.register(.generated(generated), at: "stopped.vtt")

        let request = Task { try await URLSession.shared.data(from: url) }
        await probe.waitForLoads(1)
        server.stop()
        _ = try? await request.value
        await probe.waitForCancellations(1)

        #expect(await probe.cancellationCount == 1)
    }

    @Test
    func generatedLoadRetriesAtMostOncePerRouteGeneration() async throws {
        let probe = GeneratedLoadProbe(.alwaysFails)
        let generated = try LoopbackGeneratedResource(
            contentType: "text/vtt",
            maximumContentLength: 1_024
        ) {
            try await probe.load()
        }
        let server = LoopbackPlaybackServer()
        try await server.start()
        defer { server.stop() }
        let url = try server.register(.generated(generated), at: "bounded.vtt")

        for _ in 0..<3 {
            let (_, response) = try await URLSession.shared.data(from: url)
            #expect((response as? HTTPURLResponse)?.statusCode == 502)
        }
        #expect(await probe.loadCount == 2)
    }

    @Test
    func batchRegistrationIsAtomicOnCollision() async throws {
        let server = LoopbackPlaybackServer()
        try await server.start()
        defer { server.stop() }
        let existingURL = try server.register(
            .inMemory(data: Data("existing".utf8), contentType: "text/plain"),
            at: "existing.txt"
        )

        #expect(throws: LoopbackPlaybackServerError.self) {
            try server.register([
                LoopbackRouteRegistration(
                    relativePath: "fresh.txt",
                    resource: .inMemory(
                        data: Data("fresh".utf8),
                        contentType: "text/plain"
                    )
                ),
                LoopbackRouteRegistration(
                    relativePath: "existing.txt",
                    resource: .inMemory(
                        data: Data("replacement".utf8),
                        contentType: "text/plain"
                    )
                )
            ])
        }

        let (existingBody, existingResponse) = try await URLSession.shared.data(
            from: existingURL
        )
        #expect((existingResponse as? HTTPURLResponse)?.statusCode == 200)
        #expect(existingBody == Data("existing".utf8))
        let freshURL = try server.url(for: "fresh.txt")
        let (_, response) = try await URLSession.shared.data(from: freshURL)
        #expect((response as? HTTPURLResponse)?.statusCode == 404)
    }
}

private enum ProbeError: Error {
    case configuredFailure
}

/// `LoopbackGeneratedResource` 加载闭包的可配置替身：记录加载与取消次数，按配置失败、挂起或返回正文。
private actor GeneratedLoadProbe {
    enum Behavior: Sendable {
        /// 第一次加载失败，之后返回正文。
        case failsOnceThenServes(Data)
        /// 每次加载都失败。
        case alwaysFails
        /// 挂起到 `release()` 后返回正文；不响应取消。
        case holdsUntilReleased(Data)
        /// 挂起到被取消；60 s 只是兜底超时。
        case holdsUntilCancelled
    }

    private let behavior: Behavior
    private(set) var loadCount = 0
    private(set) var cancellationCount = 0
    private var loadWaiters = CountWaiters()
    private var cancellationWaiters = CountWaiters()
    private var heldLoad: CheckedContinuation<Void, Never>?

    init(_ behavior: Behavior) {
        self.behavior = behavior
    }

    func load() async throws -> Data {
        loadCount += 1
        loadWaiters.resume(reaching: loadCount)
        switch behavior {
        case .failsOnceThenServes(let body):
            if loadCount == 1 { throw ProbeError.configuredFailure }
            return body
        case .alwaysFails:
            throw ProbeError.configuredFailure
        case .holdsUntilReleased(let body):
            await withCheckedContinuation { heldLoad = $0 }
            return body
        case .holdsUntilCancelled:
            do {
                try await Task.sleep(for: .seconds(60))
                return Data("late".utf8)
            } catch is CancellationError {
                cancellationCount += 1
                cancellationWaiters.resume(reaching: cancellationCount)
                throw CancellationError()
            }
        }
    }

    func waitForLoads(_ count: Int) async {
        await withCheckedContinuation {
            loadWaiters.add($0, until: count, current: loadCount)
        }
    }

    func waitForCancellations(_ count: Int) async {
        await withCheckedContinuation {
            cancellationWaiters.add($0, until: count, current: cancellationCount)
        }
    }

    func release() {
        heldLoad?.resume()
        heldLoad = nil
    }
}
