import Foundation
import Testing

@testable import BiliNetworking

@Suite(.serialized, .timeLimit(.minutes(1)))
struct HTTPRangeStreamingClientTests {
    @Test
    func exact206StreamsOnlyAfterValidatedResponseAndStripsCredentials() async throws {
        StreamingRangeURLProtocol.state.configure(
            statusCode: 206,
            headers: [
                "Content-Range": "bytes 10-13/100",
                "Content-Length": "4",
                "Content-Type": "video/mp4; charset=binary"
            ],
            chunks: [Data([1, 2]), Data([3, 4])]
        )
        let events = StreamEventRecorder()
        let result = try await makeClient().stream(
            from: URL(string: "https://cdn.example/video.mp4")!,
            rangeHeader: "bytes=10-13",
            expectedRange: try HTTPByteRange(start: 10, endInclusive: 13),
            expectedCompleteLength: 100,
            headers: [
                "Cookie": "must-not-leave",
                "Authorization": "must-not-leave",
                "Referer": "https://www.bilibili.com/"
            ],
            allowedContentTypes: ["video/mp4"],
            onResponse: { _ in await events.append("response") },
            onChunk: { data in await events.append("chunk:\(data.count)") }
        )

        #expect(result.byteCount == 4)
        #expect(await events.values.first == "response")
        let request = StreamingRangeURLProtocol.state.lastRequest
        #expect(request?.value(forHTTPHeaderField: "Range") == "bytes=10-13")
        #expect(request?.value(forHTTPHeaderField: "Cookie") == nil)
        #expect(request?.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request?.value(forHTTPHeaderField: "Referer") != nil)
    }

    @Test
    func rejectsStatusRangeLengthTotalAndContentTypeBeforeBody() async throws {
        let cases: [(Int, [String: String], HTTPRangeResponseError)] = [
            (200, [:], .statusCode(200)),
            (302, ["Location": "https://redirect.example/video.mp4"], .statusCode(302)),
            (
                206,
                [
                    "Content-Range": "bytes 0-2/10", "Content-Length": "3",
                    "Content-Type": "video/mp4"
                ],
                .mismatchedContentRange(
                    expected: try HTTPByteRange(start: 0, endInclusive: 3),
                    actual: try HTTPContentRange.parse("bytes 0-2/10")
                )
            ),
            (
                206,
                [
                    "Content-Range": "bytes 0-3/11", "Content-Length": "4",
                    "Content-Type": "video/mp4"
                ],
                .mismatchedCompleteLength(expected: 10, actual: 11)
            ),
            (
                206,
                [
                    "Content-Range": "bytes 0-3/10", "Content-Length": "3",
                    "Content-Type": "video/mp4"
                ],
                .mismatchedContentLength(expected: 4, actual: 3)
            ),
            (
                206,
                [
                    "Content-Range": "bytes 0-3/10", "Content-Length": "4",
                    "Content-Type": "text/html"
                ],
                .unsupportedContentType("text/html")
            )
        ]

        for (status, headers, expectedError) in cases {
            let events = StreamEventRecorder()
            StreamingRangeURLProtocol.state.configure(
                statusCode: status,
                headers: headers,
                chunks: [Data([1, 2, 3, 4])]
            )
            await #expect(throws: expectedError) {
                try await streamFourBytes(events: events)
            }
            #expect(await events.values.isEmpty)
        }
    }

    @Test
    func rejectsShortAndLongBodies() async throws {
        let headers = [
            "Content-Range": "bytes 0-3/10",
            "Content-Length": "4",
            "Content-Type": "video/mp4"
        ]
        StreamingRangeURLProtocol.state.configure(
            statusCode: 206,
            headers: headers,
            chunks: [Data([1, 2, 3])]
        )
        await #expect(
            throws: HTTPRangeResponseError.bodyLengthMismatch(expected: 4, actual: 3)
        ) {
            try await streamFourBytes()
        }
        StreamingRangeURLProtocol.state.configure(
            statusCode: 206,
            headers: headers,
            chunks: [Data([1, 2, 3, 4, 5])]
        )
        await #expect(
            throws: HTTPRangeResponseError.bodyLengthMismatch(expected: 4, actual: 5)
        ) {
            try await streamFourBytes()
        }
    }

    @Test(arguments: [nil, "text/html", "application/octet-stream"] as [String?])
    func unrestrictedContentTypeStillRequiresExactRangeAndLength(
        contentType: String?
    ) async throws {
        var headers = ["Content-Range": "bytes 0-3/10", "Content-Length": "4"]
        headers["Content-Type"] = contentType
        StreamingRangeURLProtocol.state.configure(
            statusCode: 206,
            headers: headers,
            chunks: [Data([1, 2, 3, 4])]
        )
        #expect(try await streamFourBytes(allowedContentTypes: nil).byteCount == 4)

        headers["Content-Range"] = "bytes 0-3/11"
        StreamingRangeURLProtocol.state.configure(
            statusCode: 206,
            headers: headers,
            chunks: [Data([1, 2, 3, 4])]
        )
        await #expect(
            throws: HTTPRangeResponseError.mismatchedCompleteLength(expected: 10, actual: 11)
        ) {
            try await streamFourBytes(allowedContentTypes: nil)
        }
    }

    @Test
    func cancellationStopsTheUpstreamTask() async throws {
        StreamingRangeURLProtocol.state.configure(
            statusCode: 206,
            headers: [
                "Content-Range": "bytes 0-3/10",
                "Content-Length": "4",
                "Content-Type": "video/mp4"
            ],
            chunks: [Data([1, 2, 3, 4])],
            delay: 5
        )
        let task = Task { try await streamFourBytes() }
        await StreamingRangeURLProtocol.state.waitUntilStarted()
        task.cancel()
        await #expect(throws: (any Error).self) { try await task.value }
        await StreamingRangeURLProtocol.state.waitUntilStopped()
    }

    private func streamFourBytes(
        events: StreamEventRecorder? = nil,
        allowedContentTypes: Set<String>? = ["video/mp4"]
    ) async throws -> HTTPRangeStreamResult {
        let url = try #require(URL(string: "https://cdn.example/video.mp4"))
        return try await makeClient().stream(
            from: url,
            rangeHeader: "bytes=0-3",
            expectedRange: try HTTPByteRange(start: 0, endInclusive: 3),
            expectedCompleteLength: 10,
            headers: [:],
            allowedContentTypes: allowedContentTypes,
            onResponse: { _ in await events?.append("response") },
            onChunk: { data in await events?.append("chunk:\(data.count)") }
        )
    }

    private func makeClient() -> HTTPRangeStreamingClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StreamingRangeURLProtocol.self]
        return HTTPRangeStreamingClient(
            transport: URLSessionRangeTransport(configuration: configuration)
        )
    }
}

private actor StreamEventRecorder {
    private(set) var values: [String] = []
    func append(_ value: String) { values.append(value) }
}

private final class StreamingRangeURLProtocol: ScriptedRangeURLProtocol, @unchecked Sendable {
    private static let sharedState = ScriptedRangeURLProtocolState()
    override class var state: ScriptedRangeURLProtocolState { sharedState }
}
