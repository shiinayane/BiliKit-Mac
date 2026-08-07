import BiliApplication
import BiliModels
import Foundation
import Testing

@testable import BiliPlayback

@Suite(.serialized, .timeLimit(.minutes(1)))
struct NativeSubtitleStage0GeneratedBodyTests {
    @Test
    func failedBodyCanRetryThenServeStrictLengthAndRange() async throws {
        let expectedBody = Data("WEBVTT\n".utf8)
        let probe = Stage0RetryBodyProbe(success: expectedBody)
        let store = Stage0GeneratedBodyStore(maximumLength: 1_024) {
            try await probe.load()
        }

        var firstFailed = false
        do {
            _ = try await store.resolve()
        } catch Stage0GeneratedBodyError.fixtureFailure {
            firstFailed = true
        }
        #expect(firstFailed)

        let resolved = try await store.resolve()
        #expect(resolved == expectedBody)
        #expect(try await store.resolve() == expectedBody)
        #expect(await probe.loadCount == 2)

        let server = LoopbackPlaybackServer()
        try await server.start()
        let url = try server.register(
            .inMemory(data: resolved, contentType: "text/vtt"),
            at: "stage0/generated-subtitle.vtt"
        )

        var headRequest = URLRequest(url: url)
        headRequest.httpMethod = "HEAD"
        let (headBody, headResponse) = try await URLSession.shared.data(
            for: headRequest
        )
        let headHTTP = try #require(headResponse as? HTTPURLResponse)
        #expect(headHTTP.statusCode == 200)
        #expect(
            headHTTP.value(forHTTPHeaderField: "Content-Length")
                == "\(expectedBody.count)"
        )
        #expect(headBody.isEmpty)

        var rangeRequest = URLRequest(url: url)
        rangeRequest.setValue("bytes=0-5", forHTTPHeaderField: "Range")
        let (rangeBody, rangeResponse) = try await URLSession.shared.data(
            for: rangeRequest
        )
        let rangeHTTP = try #require(rangeResponse as? HTTPURLResponse)
        #expect(rangeHTTP.statusCode == 206)
        #expect(
            rangeHTTP.value(forHTTPHeaderField: "Content-Range")
                == "bytes 0-5/\(expectedBody.count)"
        )
        #expect(rangeBody == Data("WEBVTT".utf8))

        server.stop()
        let diagnostics = server.diagnosticsSnapshot()
        #expect(!diagnostics.isRunning)
        #expect(diagnostics.registeredRouteCount == 0)
        #expect(diagnostics.activeConnectionCount == 0)
        #expect(diagnostics.activeTaskCount == 0)
    }

    @Test
    func concurrentRequestsShareOneLoadAndCancellationCanRetry() async throws {
        let body = Data("WEBVTT\n".utf8)
        let sharedProbe = Stage0BlockingBodyProbe(body: body)
        let sharedStore = Stage0GeneratedBodyStore(maximumLength: 1_024) {
            await sharedProbe.load()
        }
        let first = Task { try await sharedStore.resolve() }
        let second = Task { try await sharedStore.resolve() }
        try await waitUntil { await sharedStore.resolveCount == 2 }
        await sharedProbe.release()

        #expect(try await first.value == body)
        #expect(try await second.value == body)
        #expect(await sharedProbe.loadCount == 1)

        let cancellationProbe = Stage0CancellableRetryProbe(success: body)
        let cancellationStore = Stage0GeneratedBodyStore(maximumLength: 1_024) {
            try await cancellationProbe.load()
        }
        let cancelled = Task { try await cancellationStore.resolve() }
        try await waitUntil { await cancellationProbe.loadCount == 1 }
        await cancellationStore.cancel()

        var cancellationObserved = false
        do {
            _ = try await cancelled.value
        } catch is CancellationError {
            cancellationObserved = true
        }
        #expect(cancellationObserved)
        #expect(await cancellationProbe.cancellationCount == 1)
        #expect(try await cancellationStore.resolve() == body)
        #expect(await cancellationProbe.loadCount == 2)
    }

    @Test
    func generationRejectsLateAResultAcrossABAReloadAndStop() async throws {
        let firstA = PlaybackItemIdentity(bvid: "BV1Stage0A", cid: 101)
        let itemB = PlaybackItemIdentity(bvid: "BV1Stage0B", cid: 202)
        let owner = Stage0GeneratedBodyOwner()
        let lateAProbe = Stage0BlockingBodyProbe(body: Data("A-old".utf8))

        let lateA = Task {
            try await owner.load(identity: firstA) {
                await lateAProbe.load()
            }
        }
        try await waitUntil { await lateAProbe.started }

        let loadedB = try await owner.load(identity: itemB) {
            Data("B".utf8)
        }
        #expect(loadedB.identity == itemB)
        #expect(loadedB.generation == 2)
        #expect(loadedB.body == Data("B".utf8))

        await lateAProbe.release()
        #expect(await observesCancellation(lateA))

        let reloadedA = try await owner.load(identity: firstA) {
            Data("A-new".utf8)
        }
        #expect(reloadedA.identity == firstA)
        #expect(reloadedA.generation == 3)
        #expect(reloadedA.body == Data("A-new".utf8))

        let stoppedProbe = Stage0BlockingBodyProbe(body: Data("late".utf8))
        let stoppedLoad = Task {
            try await owner.load(identity: itemB) {
                await stoppedProbe.load()
            }
        }
        try await waitUntil { await stoppedProbe.started }
        await owner.stop()
        await stoppedProbe.release()

        #expect(await observesCancellation(stoppedLoad))
        let stoppedSnapshot = await owner.snapshot
        #expect(stoppedSnapshot.identity == nil)
        #expect(stoppedSnapshot.generation == 5)
    }

    private func observesCancellation(
        _ task: Task<Stage0GeneratedBodySnapshot, any Error>
    ) async -> Bool {
        do {
            _ = try await task.value
            return false
        } catch is CancellationError {
            return true
        } catch {
            return false
        }
    }

    private func waitUntil(
        _ condition: @escaping @Sendable () async -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while !(await condition()) {
            guard clock.now < deadline else {
                throw Stage0GeneratedBodyError.timedOut
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

private actor Stage0GeneratedBodyStore {
    private let maximumLength: Int
    private let loader: @Sendable () async throws -> Data
    private var cachedBody: Data?
    private var loadGeneration = 0
    private var loadTask: Task<Data, any Error>?
    private(set) var resolveCount = 0

    init(
        maximumLength: Int,
        loader: @escaping @Sendable () async throws -> Data
    ) {
        self.maximumLength = maximumLength
        self.loader = loader
    }

    func resolve() async throws -> Data {
        resolveCount += 1
        if let cachedBody { return cachedBody }
        let requestedGeneration: Int
        let task: Task<Data, any Error>
        if let loadTask {
            requestedGeneration = loadGeneration
            task = loadTask
        } else {
            loadGeneration += 1
            requestedGeneration = loadGeneration
            task = Task { try await loader() }
            loadTask = task
        }
        do {
            let body = try await task.value
            guard !body.isEmpty, body.count <= maximumLength else {
                throw Stage0GeneratedBodyError.invalidLength
            }
            guard requestedGeneration == loadGeneration else {
                throw CancellationError()
            }
            cachedBody = body
            loadTask = nil
            return body
        } catch {
            if requestedGeneration == loadGeneration {
                loadTask = nil
            }
            throw error
        }
    }

    func cancel() {
        loadGeneration += 1
        loadTask?.cancel()
        loadTask = nil
    }
}

private actor Stage0GeneratedBodyOwner {
    private var generation = 0
    private var identity: PlaybackItemIdentity?
    private var loadTask: Task<Data, Never>?

    var snapshot: Stage0GeneratedBodySnapshot {
        Stage0GeneratedBodySnapshot(
            identity: identity,
            generation: generation,
            body: Data()
        )
    }

    func load(
        identity: PlaybackItemIdentity,
        loader: @escaping @Sendable () async -> Data
    ) async throws -> Stage0GeneratedBodySnapshot {
        generation += 1
        let requestedGeneration = generation
        self.identity = identity
        loadTask?.cancel()
        let task = Task { await loader() }
        loadTask = task

        let body = await task.value
        guard requestedGeneration == generation,
            self.identity == identity,
            !Task.isCancelled
        else {
            throw CancellationError()
        }
        loadTask = nil
        return Stage0GeneratedBodySnapshot(
            identity: identity,
            generation: requestedGeneration,
            body: body
        )
    }

    func stop() {
        generation += 1
        identity = nil
        loadTask?.cancel()
        loadTask = nil
    }
}

private struct Stage0GeneratedBodySnapshot: Sendable, Equatable {
    let identity: PlaybackItemIdentity?
    let generation: Int
    let body: Data
}

private actor Stage0RetryBodyProbe {
    private let success: Data
    private(set) var loadCount = 0

    init(success: Data) {
        self.success = success
    }

    func load() throws -> Data {
        loadCount += 1
        if loadCount == 1 {
            throw Stage0GeneratedBodyError.fixtureFailure
        }
        return success
    }
}

private actor Stage0BlockingBodyProbe {
    private let body: Data
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var started = false
    private(set) var loadCount = 0

    init(body: Data) {
        self.body = body
    }

    func load() async -> Data {
        loadCount += 1
        started = true
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

private actor Stage0CancellableRetryProbe {
    private let success: Data
    private(set) var loadCount = 0
    private(set) var cancellationCount = 0

    init(success: Data) {
        self.success = success
    }

    func load() async throws -> Data {
        loadCount += 1
        if loadCount == 1 {
            do {
                try await Task.sleep(for: .seconds(60))
            } catch is CancellationError {
                cancellationCount += 1
                throw CancellationError()
            }
        }
        return success
    }
}

private enum Stage0GeneratedBodyError: Error {
    case fixtureFailure
    case invalidLength
    case timedOut
}
