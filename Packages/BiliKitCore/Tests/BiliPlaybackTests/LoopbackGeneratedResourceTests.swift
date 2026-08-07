import Foundation
import Testing

@testable import BiliPlayback

@Suite(.serialized, .timeLimit(.minutes(1)))
struct LoopbackGeneratedResourceTests {
    @Test
    func failedRequestCanRetryThenServesLengthHeadAndRange() async throws {
        let probe = RetryProbe(body: Data("WEBVTT\n".utf8))
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
        let probe = BlockingProbe(body: Data("WEBVTT\n".utf8))
        let generated = try LoopbackGeneratedResource(
            contentType: "text/vtt",
            maximumContentLength: 1_024
        ) {
            await probe.load()
        }
        let server = LoopbackPlaybackServer()
        try await server.start()
        defer { server.stop() }
        let url = try server.register(.generated(generated), at: "shared.vtt")

        async let first = URLSession.shared.data(from: url)
        async let second = URLSession.shared.data(from: url)
        try await waitUntil { await probe.loadCount == 1 }
        await probe.release()
        let results = try await [first, second]

        #expect(results.allSatisfy { $0.0 == Data("WEBVTT\n".utf8) })
        #expect(await probe.loadCount == 1)
    }

    @Test
    func cancelledWaiterDoesNotDiscardSharedSuccessfulLoad() async throws {
        let probe = BlockingProbe(body: Data("WEBVTT\n".utf8))
        let generated = try LoopbackGeneratedResource(
            contentType: "text/vtt",
            maximumContentLength: 1_024
        ) {
            await probe.load()
        }
        let server = LoopbackPlaybackServer()
        try await server.start()
        defer { server.stop() }
        let url = try server.register(.generated(generated), at: "cancelled.vtt")

        let first = Task { try await URLSession.shared.data(from: url) }
        try await waitUntil { await probe.loadCount == 1 }
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
        let probe = CancellationProbe()
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
        try await waitUntil { await probe.loadCount == 1 }
        server.stop()
        _ = try? await request.value
        try await waitUntil { await probe.cancellationCount == 1 }

        #expect(await probe.cancellationCount == 1)
        #expect(server.diagnosticsSnapshot().registeredRouteCount == 0)
    }

    @Test
    func unregisterIsTerminalForCapturedGeneratedResource() async throws {
        let probe = CancellationProbe()
        let generated = try LoopbackGeneratedResource(
            contentType: "text/vtt",
            maximumContentLength: 1_024
        ) {
            try await probe.load()
        }
        let server = LoopbackPlaybackServer()
        try await server.start()
        defer { server.stop() }
        let firstURL = try server.register(
            .generated(generated),
            at: "removed.vtt"
        )

        let request = Task { try await URLSession.shared.data(from: firstURL) }
        try await waitUntil { await probe.loadCount == 1 }
        try server.unregister(relativePaths: ["removed.vtt"])
        _ = try? await request.value
        try await waitUntil { await probe.cancellationCount == 1 }

        let secondURL = try server.register(
            .generated(generated),
            at: "reused.vtt"
        )
        _ = try? await URLSession.shared.data(from: secondURL)
        #expect(await probe.loadCount == 1)
    }

    @Test
    func generatedLoadRetriesAtMostOncePerRouteGeneration() async throws {
        let probe = AlwaysFailingProbe()
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
        _ = try server.register(
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
                ),
            ])
        }

        #expect(server.diagnosticsSnapshot().registeredRouteCount == 1)
        let freshURL = try server.url(for: "fresh.txt")
        let (_, response) = try await URLSession.shared.data(from: freshURL)
        #expect((response as? HTTPURLResponse)?.statusCode == 404)
    }

    private func waitUntil(
        _ condition: @escaping @Sendable () async -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while !(await condition()) {
            guard clock.now < deadline else { throw ProbeError.timedOut }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

private enum ProbeError: Error {
    case firstFailure
    case timedOut
}

private actor RetryProbe {
    let body: Data
    private(set) var loadCount = 0

    init(body: Data) {
        self.body = body
    }

    func load() throws -> Data {
        loadCount += 1
        if loadCount == 1 { throw ProbeError.firstFailure }
        return body
    }
}

private actor BlockingProbe {
    let body: Data
    private(set) var loadCount = 0
    private var continuation: CheckedContinuation<Void, Never>?

    init(body: Data) {
        self.body = body
    }

    func load() async -> Data {
        loadCount += 1
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
        return body
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

private actor CancellationProbe {
    private(set) var loadCount = 0
    private(set) var cancellationCount = 0

    func load() async throws -> Data {
        loadCount += 1
        do {
            try await Task.sleep(for: .seconds(60))
            return Data("late".utf8)
        } catch is CancellationError {
            cancellationCount += 1
            throw CancellationError()
        }
    }
}

private actor AlwaysFailingProbe {
    private(set) var loadCount = 0

    func load() throws -> Data {
        loadCount += 1
        throw ProbeError.firstFailure
    }
}
