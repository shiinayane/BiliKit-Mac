@preconcurrency import AVFoundation
import BiliApplication
import BiliModels
import BiliNetworking
import Foundation
import Testing

@testable import BiliPlayback

// Swift Testing macros reference their diagnostic comment type without qualification.
private typealias Comment = Testing.Comment

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

        #expect(acceptedStatus == 200)
        #expect(rejectedTokenStatus == 404)
        #expect(rejectedPathStatus == 404)
        #expect(untrustedHostStatus == 400)
        #expect(missingHostStatus == 400)
        #expect(duplicateHostStatus == 400)
        #expect(malformedHostStatus == 400)

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

    @Test
    func remoteResourceStaysOnItsPreparedSourceAcrossRanges() async throws {
        let primary = try #require(
            URL(string: "https://primary.example/media.mp4")
        )
        let backup = try #require(
            URL(string: "https://backup.example/media.mp4")
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
        try input.fileHandleForWriting.close()
        let response = output.fileHandleForReading.readDataToEndOfFile()
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
