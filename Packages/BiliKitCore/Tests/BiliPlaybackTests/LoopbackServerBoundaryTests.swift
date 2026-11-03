@preconcurrency import AVFoundation
import BiliApplication
import BiliModels
import BiliNetworking
import Foundation
import Testing

@testable import BiliPlayback

// Swift Testing macros reference their diagnostic comment type without qualification.
private typealias Comment = Testing.Comment

/// loopback server 只服务 session token 与 Host 都对得上的本机请求，连接与上游请求都有界。
///
/// 对应 SECURITY-MODEL §5：独立进程视角的 Host／token／路径拒绝与畸形请求、请求目标解析、空闲与响应阶段的连接上限、
/// 远端资源的来源白名单与固定来源、GET／HEAD 的 Range 语义、远端 Range 错误不发上游请求，以及停止时取消上游请求。
@Suite(.serialized, .timeLimit(.minutes(2)))
struct LoopbackServerBoundaryTests {
    @Test
    func independentProcessEnforcesLoopbackCapabilityBoundary() async throws {
        let server = LoopbackPlaybackServer()
        try await server.start()
        let url = try server.register(
            .inMemory(
                data: Data([0x4F, 0x4B]),
                contentType: "application/octet-stream"
            ),
            at: "boundary.bin"
        )
        guard let port = url.port else {
            throw PlaybackFixtureError.missingPort
        }

        let acceptedStatus = try independentHTTPStatus(
            port: port,
            target: url.path,
            host: "127.0.0.1:\(port)"
        )
        let rejectedTokenStatus = try independentHTTPStatus(
            port: port,
            target: "/00000000000000000000000000000000/boundary.bin",
            host: "127.0.0.1:\(port)"
        )
        let rejectedPathStatus = try independentHTTPStatus(
            port: port,
            target: "\(url.path)/extra",
            host: "127.0.0.1:\(port)"
        )
        let untrustedHostStatus = try independentHTTPStatus(
            port: port,
            target: url.path,
            host: "attacker.invalid"
        )
        let missingHostStatus = try independentHTTPStatus(
            port: port,
            target: url.path,
            hostHeaders: []
        )
        let duplicateHostStatus = try independentHTTPStatus(
            port: port,
            target: url.path,
            hostHeaders: [
                "127.0.0.1:\(port)",
                "attacker.invalid"
            ]
        )
        let malformedHostStatus = try independentHTTPStatus(
            port: port,
            target: url.path,
            host: "127.0.0.1:not-a-port"
        )
        // 畸形目标在 Host／token 校验之前解析，必须作为普通 400 拒绝而不是让进程崩溃。
        let queryOnlyTargetStatus = try independentHTTPStatus(
            port: port,
            target: "?",
            host: "127.0.0.1:\(port)"
        )

        #expect(acceptedStatus == 200)
        #expect(rejectedTokenStatus == 404)
        #expect(rejectedPathStatus == 404)
        #expect(untrustedHostStatus == 400)
        #expect(missingHostStatus == 400)
        #expect(duplicateHostStatus == 400)
        #expect(malformedHostStatus == 400)
        #expect(queryOnlyTargetStatus == 400)

        try exerciseIndependentDisconnects(
            port: port,
            target: url.path
        )
        // 半截请求后断开的客户端不能让 server 卡住或占住后续请求。
        #expect(
            try independentHTTPStatus(
                port: port,
                target: url.path,
                host: "127.0.0.1:\(port)"
            ) == 200
        )
        server.stop()
        try await waitForIndependentProcessToRejectConnections(port: port)
    }

    @Test(
        arguments: [
            "GET ? HTTP/1.1",
            "GET ??? HTTP/1.1",
            "GET  HTTP/1.1",
            "GET path?x HTTP/1.1",
            "GET http://127.0.0.1/path HTTP/1.1"
        ]
    )
    func requestParserRejectsTargetsOutsideOriginForm(_ requestLine: String) {
        #expect(throws: LoopbackPlaybackServerError.invalidHTTPRequest) {
            try LoopbackHTTPRequest.parse(
                Data("\(requestLine)\r\nHost: 127.0.0.1\r\n\r\n".utf8)
            )
        }
    }

    @Test(
        arguments: [
            ("/token/path?x", "/token/path"),
            ("/token/path??x", "/token/path"),
            ("/?", "/"),
            ("/token/path", "/token/path")
        ]
    )
    func requestParserRoutesOnPathWithoutQuery(
        _ rawTarget: String,
        _ expectedTarget: String
    ) throws {
        let request = try LoopbackHTTPRequest.parse(
            Data("GET \(rawTarget) HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n".utf8)
        )

        #expect(request.method == "GET")
        #expect(request.target == expectedTarget)
        #expect(request.headers == ["host": "127.0.0.1"])
    }

    /// 空闲连接占满待请求头名额时，新连接让最早的空闲连接让位并得到服务；留下的只连不发完请求头的
    /// 连接到时被关闭。
    @Test
    func idleConnectionsCannotLockOutRequestsAndTimeOut() async throws {
        let server = LoopbackPlaybackServer()
        try await server.start()
        defer { server.stop() }
        let url = try server.register(
            .inMemory(data: Data([0x4F, 0x4B]), contentType: "text/plain"),
            at: "limited.txt"
        )
        let port = try #require(url.port)

        var idleClients: [RawLoopbackClient] = []
        defer {
            for client in idleClients {
                client.cancel()
            }
        }
        // 空闲连接数达到总上限：没有待请求头子上限时，后来的请求会被挡在门外。
        let idleCount = LoopbackPlaybackServer.maximumConcurrentConnections
        for index in 0..<idleCount {
            let client = try RawLoopbackClient(port: port)
            try await client.connect()
            if index == idleCount - 1 {
                // 请求头只发一半的慢速客户端与完全空闲的连接受同一时限约束。
                try await client.send(Data("GET \(url.path) HTTP/1.1\r\n".utf8))
            }
            idleClients.append(client)
        }

        let accepted = try RawLoopbackClient(port: port)
        defer { accepted.cancel() }
        try await accepted.connect()
        try await accepted.send(
            Data("GET \(url.path) HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\n\r\n".utf8)
        )
        let response = String(decoding: await accepted.receiveUntilClosed(), as: UTF8.self)
        #expect(response.hasPrefix("HTTP/1.1 200 OK\r\n"))
        #expect(response.hasSuffix("\r\n\r\nOK"))

        for client in idleClients {
            #expect(await client.receiveUntilClosed().isEmpty)
        }
    }

    /// 全部连接都在响应阶段且达到总上限时，新连接不进入请求处理。
    @Test
    func responsePhaseConnectionsAreCappedAtTotalLimit() async throws {
        let remoteURL = try #require(
            URL(string: "https://media.fixture.bilivideo.com/held.mp4")
        )
        let transport = FixtureRangeTransport(
            media: [remoteURL: Data(repeating: 0, count: 16)],
            blockingURLIndexRanges: [
                remoteURL: try MediaByteRange(start: 0, endInclusive: 0)
            ]
        )
        let server = LoopbackPlaybackServer(rangeStreamer: transport)
        try await server.start()
        defer { server.stop() }
        let url = try server.register(
            .remote(
                try LoopbackRemoteResource(
                    sourceURL: remoteURL,
                    contentLength: 16,
                    contentType: "video/mp4"
                )
            ),
            at: "held.mp4"
        )
        let port = try #require(url.port)
        let request = Data(
            ("GET \(url.path) HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\n"
                + "Range: bytes=4-11\r\n\r\n").utf8
        )

        var heldClients: [RawLoopbackClient] = []
        defer {
            for client in heldClients {
                client.cancel()
            }
        }
        let limit = LoopbackPlaybackServer.maximumConcurrentConnections
        for _ in 0..<limit {
            let client = try RawLoopbackClient(port: port)
            try await client.connect()
            try await client.send(request)
            heldClients.append(client)
        }
        await transport.waitForBlockedRequest(count: limit)

        let rejected = try RawLoopbackClient(port: port)
        defer { rejected.cancel() }
        try? await rejected.connect()
        try? await rejected.send(request)

        #expect(await rejected.receiveUntilClosed().isEmpty)
        #expect(await transport.startedBlockedRequestCount == limit)
    }

    @Test
    func remoteResourceRejectsSourceOutsideMediaAllowlist() throws {
        #expect(throws: LoopbackPlaybackServerError.invalidRemoteSource) {
            try LoopbackRemoteResource(
                sourceURL: URL(string: "https://example.com/media.mp4")!,
                contentLength: 4,
                contentType: "video/mp4"
            )
        }
    }

    @Test
    func remoteResourceStaysOnItsPreparedSourceAcrossRanges() async throws {
        let primary = try #require(
            URL(string: "https://primary.fixture.bilivideo.com/media.mp4")
        )
        let backup = try #require(
            URL(string: "https://backup.fixture.bilivideo.com/media.mp4")
        )
        // 备用来源能提供第二段 Range，但已固定的首个来源失败后也不能跨来源拼字节。
        let transport = FixtureRangeTransport(
            media: [
                primary: Data(repeating: 0x41, count: 4),
                backup: Data(repeating: 0x42, count: 4)
            ],
            failingRangeHeaders: [primary: ["bytes=2-3"]]
        )
        let server = LoopbackPlaybackServer(
            rangeStreamer: transport
        )
        try await server.start()
        defer { server.stop() }
        let url = try server.register(
            .remote(
                try LoopbackRemoteResource(
                    sourceURL: primary,
                    contentLength: 4,
                    contentType: "video/mp4"
                )
            ),
            at: "remote.mp4"
        )

        var firstRequest = URLRequest(url: url)
        firstRequest.setValue("bytes=0-1", forHTTPHeaderField: "Range")
        let (firstBody, firstResponse) = try await URLSession.shared.data(
            for: firstRequest
        )
        var secondRequest = URLRequest(url: url)
        secondRequest.setValue("bytes=2-3", forHTTPHeaderField: "Range")
        let (secondBody, secondResponse) = try await URLSession.shared.data(
            for: secondRequest
        )

        #expect((firstResponse as? HTTPURLResponse)?.statusCode == 206)
        #expect((secondResponse as? HTTPURLResponse)?.statusCode == 502)
        #expect(firstBody == Data([0x41, 0x41]))
        #expect(secondBody.isEmpty)
        let requestedURLs = await transport.requests.map(\.url)
        #expect(requestedURLs == [primary, primary])
    }

    @Test(arguments: loopbackGETRangeCases)
    func loopbackGETServesSingleRangesAndIgnoresUnsupportedOnes(
        _ testCase: LoopbackGETRangeCase
    ) async throws {
        let (body, response) = try await requestFiveByteResource(
            method: "GET",
            range: testCase.range
        )

        #expect(response.statusCode == testCase.status)
        #expect(
            response.value(forHTTPHeaderField: "Content-Length")
                == String(testCase.body.count)
        )
        #expect(
            response.value(forHTTPHeaderField: "Content-Range")
                == testCase.contentRange
        )
        #expect(body == Data(testCase.body))
    }

    @Test(
        arguments: [
            nil, "bytes=1-3", "bytes=-2", "bytes=5-", "bytes=0-0,2-2", "items=0-1"
        ] as [String?]
    )
    func loopbackHEADIgnoresRange(_ range: String?) async throws {
        let (body, response) = try await requestFiveByteResource(
            method: "HEAD",
            range: range
        )

        #expect(response.statusCode == 200)
        #expect(response.value(forHTTPHeaderField: "Content-Length") == "5")
        #expect(response.value(forHTTPHeaderField: "Content-Range") == nil)
        #expect(body.isEmpty)
    }

    @Test
    func remoteRangeErrorsStayLocalAndSuffixIsForwardedAsClosedRange() async throws {
        let remoteURL = try #require(
            URL(string: "https://media.fixture.bilivideo.com/remote.mp4")
        )
        let media = Data([0, 1, 2, 3, 4])
        let transport = FixtureRangeTransport(
            media: [remoteURL: media]
        )
        let server = LoopbackPlaybackServer(
            rangeStreamer: transport
        )
        try await server.start()
        defer { server.stop() }
        let url = try server.register(
            .remote(
                try LoopbackRemoteResource(
                    sourceURL: remoteURL,
                    contentLength: Int64(media.count),
                    contentType: "video/mp4"
                )
            ),
            at: "remote-range-errors.mp4"
        )

        for range in ["items=0-1", "bytes=0-0,2-2"] {
            var request = URLRequest(url: url)
            request.setValue(range, forHTTPHeaderField: "Range")
            let (body, response) = try await URLSession.shared.data(for: request)

            #expect((response as? HTTPURLResponse)?.statusCode == 400)
            #expect(body.isEmpty)
        }
        #expect(await transport.requests.isEmpty)

        var unsatisfiableRequest = URLRequest(url: url)
        unsatisfiableRequest.setValue(
            "bytes=5-",
            forHTTPHeaderField: "Range"
        )
        let (unsatisfiableBody, unsatisfiableResponse) =
            try await URLSession.shared.data(for: unsatisfiableRequest)
        let unsatisfiableHTTPResponse = try #require(
            unsatisfiableResponse as? HTTPURLResponse
        )
        #expect(unsatisfiableHTTPResponse.statusCode == 416)
        #expect(
            unsatisfiableHTTPResponse.value(
                forHTTPHeaderField: "Content-Range"
            ) == "bytes */5"
        )
        #expect(unsatisfiableBody.isEmpty)
        #expect(await transport.requests.isEmpty)

        var suffixRequest = URLRequest(url: url)
        suffixRequest.setValue("bytes=-2", forHTTPHeaderField: "Range")
        let (suffixBody, suffixResponse) = try await URLSession.shared.data(
            for: suffixRequest
        )
        #expect((suffixResponse as? HTTPURLResponse)?.statusCode == 206)
        #expect(suffixBody == Data([3, 4]))
        let requests = await transport.requests
        #expect(requests.count == 1)
        #expect(requests[0].headers["Range"] == "bytes=3-4")
    }

    @Test
    func remoteUpstreamWithUnverifiableLengthIsRejectedBeforeHead() async throws {
        let remoteURL = try #require(
            URL(string: "https://media.fixture.bilivideo.com/unknown-length.mp4")
        )
        let server = LoopbackPlaybackServer(
            rangeStreamer: FixtureRangeTransport(
                media: [remoteURL: Data([0, 1, 2, 3])],
                unknownLengthURLs: [remoteURL]
            )
        )
        try await server.start()
        defer { server.stop() }
        let url = try server.register(
            .remote(
                try LoopbackRemoteResource(
                    sourceURL: remoteURL,
                    contentLength: 4,
                    contentType: "video/mp4"
                )
            ),
            at: "unknown-length.mp4"
        )
        var request = URLRequest(url: url)
        request.setValue("bytes=0-1", forHTTPHeaderField: "Range")

        let (body, response) = try await URLSession.shared.data(for: request)

        #expect((response as? HTTPURLResponse)?.statusCode == 502)
        #expect(body.isEmpty)
    }

    @Test
    func stoppingServerCancelsInFlightRemoteRange() async throws {
        let remoteURL = try #require(
            URL(string: "https://media.fixture.bilivideo.com/stalled.mp4")
        )
        let transport = FixtureRangeTransport(
            media: [remoteURL: Data(repeating: 0, count: 16)],
            blockingURLIndexRanges: [
                remoteURL: try MediaByteRange(start: 0, endInclusive: 0)
            ]
        )
        let server = LoopbackPlaybackServer(rangeStreamer: transport)
        try await server.start()
        let url = try server.register(
            .remote(
                try LoopbackRemoteResource(
                    sourceURL: remoteURL,
                    contentLength: 16,
                    contentType: "video/mp4"
                )
            ),
            at: "stalled.mp4"
        )
        var request = URLRequest(url: url)
        request.setValue("bytes=4-11", forHTTPHeaderField: "Range")
        let pending = Task { try await URLSession.shared.data(for: request) }

        await transport.waitForBlockedRequest()
        server.stop()
        await transport.waitForCancelledBlockedRequests(1)
        _ = try? await pending.value

        #expect(await transport.cancelledBlockedRequestCount == 1)
    }

    private func requestFiveByteResource(
        method: String,
        range: String?
    ) async throws -> (Data, HTTPURLResponse) {
        let server = LoopbackPlaybackServer()
        try await server.start()
        defer { server.stop() }
        let url = try server.register(
            .inMemory(
                data: Data([0, 1, 2, 3, 4]),
                contentType: "application/octet-stream"
            ),
            at: "range.bin"
        )
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(range, forHTTPHeaderField: "Range")
        let (body, response) = try await URLSession.shared.data(for: request)
        return (body, try #require(response as? HTTPURLResponse))
    }

    private func independentHTTPStatus(
        port: Int,
        target: String,
        host: String
    ) throws -> Int {
        try independentHTTPStatus(
            port: port,
            target: target,
            hostHeaders: [host]
        )
    }

    private func independentHTTPStatus(
        port: Int,
        target: String,
        hostHeaders: [String]
    ) throws -> Int {
        let hostHeaderBlock =
            hostHeaders
            .map { "Host: \($0)\r\n" }
            .joined()
        let request =
            "GET \(target) HTTP/1.1\r\n"
            + hostHeaderBlock
            + "Connection: close\r\n"
            + "\r\n"
        let result = try runNetcat(
            port: port,
            request: Data(request.utf8)
        )
        guard result.exitStatus == 0,
            let response = String(data: result.output, encoding: .utf8),
            let statusLine = response.components(
                separatedBy: "\r\n"
            ).first,
            let rawStatus = statusLine.split(separator: " ").dropFirst().first,
            let status = Int(rawStatus)
        else {
            throw PlaybackFixtureError.invalidIndependentResponse
        }
        return status
    }

    private func exerciseIndependentDisconnects(
        port: Int,
        target: String
    ) throws {
        var processes: [(process: Process, output: Pipe)] = []
        for _ in 0..<8 {
            let process = Process()
            let input = Pipe()
            let output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/nc")
            process.arguments = ["-w", "2", "127.0.0.1", String(port)]
            process.standardInput = input
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            try process.run()
            try input.fileHandleForWriting.write(
                contentsOf: Data("GET \(target) HTTP/1.1\r\n".utf8)
            )
            try input.fileHandleForWriting.close()
            processes.append((process, output))
        }
        for entry in processes {
            _ = entry.output.fileHandleForReading.readDataToEndOfFile()
            entry.process.waitUntilExit()
        }
    }

    private func independentProcessCanConnect(port: Int) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/nc")
        process.arguments = [
            "-z",
            "-w",
            "1",
            "127.0.0.1",
            String(port)
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    /// 独立进程看到的端口关闭发生在 listener 异步取消之后，进程内没有可等待的事件；
    /// 这里是唯一保留的系统边界轮询，1 s 上限只作超时。
    private func waitForIndependentProcessToRejectConnections(
        port: Int
    ) async throws {
        for _ in 0..<100 {
            if !independentProcessCanConnect(port: port) {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw PlaybackFixtureError.timedOut
    }

    private func runNetcat(
        port: Int,
        request: Data
    ) throws -> (exitStatus: Int32, output: Data) {
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/nc")
        process.arguments = ["-w", "2", "127.0.0.1", String(port)]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        try input.fileHandleForWriting.write(contentsOf: request)
        // 读完响应前不关闭 stdin：nc 在 stdin EOF 时半关闭连接，server 会把它当作下游断开。
        let response = output.fileHandleForReading.readDataToEndOfFile()
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        return (process.terminationStatus, response)
    }
}

struct LoopbackGETRangeCase: Sendable, CustomTestStringConvertible {
    let range: String?
    let status: Int
    let contentRange: String?
    let body: [UInt8]

    var testDescription: String { range ?? "no Range" }
}

let loopbackGETRangeCases: [LoopbackGETRangeCase] = [
    .init(range: nil, status: 200, contentRange: nil, body: [0, 1, 2, 3, 4]),
    .init(range: "bytes=1-3", status: 206, contentRange: "bytes 1-3/5", body: [1, 2, 3]),
    .init(range: "bytes=2-", status: 206, contentRange: "bytes 2-4/5", body: [2, 3, 4]),
    .init(range: "bytes=-2", status: 206, contentRange: "bytes 3-4/5", body: [3, 4]),
    .init(range: "bytes=5-", status: 416, contentRange: "bytes */5", body: []),
    .init(range: "bytes=0-0,2-2", status: 200, contentRange: nil, body: [0, 1, 2, 3, 4]),
    .init(range: "items=0-1", status: 200, contentRange: nil, body: [0, 1, 2, 3, 4])
]
