import BiliAPI
import BiliNetworking
import Foundation
import XCTest

final class M501SearchCacheProbeTests: XCTestCase {
    @MainActor
    func testRepeatedAnonymousSearchCacheBehaviorWhenExplicitlyConfigured()
        async throws
    {
        guard let input = try LocalProbeInput.load() else {
            throw XCTSkip(
                "仅在显式提供安全本机 probe 输入文件时运行真实缓存探针"
            )
        }
        guard
            let query = input["query"]?.trimmingCharacters(
                in: .whitespacesAndNewlines
            ),
            !query.isEmpty,
            query.count <= 100
        else {
            throw LocalProbeInputError.invalidValue
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        let transport = M501SearchCapturingTransport(
            underlying: URLSessionTransport(
                configuration: configuration,
                redirectPolicy: .reject
            )
        )
        let client = BiliAPIClient(transport: transport)

        _ = try await client.searchVideos(keyword: query, page: 1)
        _ = try await client.searchVideos(keyword: query, page: 1)

        let observations = await transport.observations()
        XCTAssertEqual(observations.count, 2)
        let first = try XCTUnwrap(observations.first)
        let second = try XCTUnwrap(observations.last)
        XCTContext.runActivity(
            named: [
                "m501-search-cache",
                "responses=\(observations.count)",
                "status-first=\(first.statusCode)",
                "status-second=\(second.statusCode)",
                "cache-first=\(first.cacheControl)",
                "cache-second=\(second.cacheControl)",
                "bytes-first=\(first.bodyBytes)",
                "bytes-second=\(second.bodyBytes)",
                "conditional-first=\(first.hadConditionalRequest ? 1 : 0)",
                "conditional-second=\(second.hadConditionalRequest ? 1 : 0)",
                "etag-first=\(first.hadETag ? 1 : 0)",
                "etag-second=\(second.hadETag ? 1 : 0)",
                "last-modified-first=\(first.hadLastModified ? 1 : 0)",
                "last-modified-second=\(second.hadLastModified ? 1 : 0)",
                "cleanup=complete",
            ].joined(separator: " ")
        ) { _ in }
    }
}

private actor M501SearchCapturingTransport: HTTPTransport {
    private let underlying: URLSessionTransport
    private var captured: [M501SearchObservation] = []

    init(underlying: URLSessionTransport) {
        self.underlying = underlying
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let response = try await underlying.send(request)
        if request.url.path == "/x/web-interface/wbi/search/type" {
            captured.append(
                M501SearchObservation(
                    statusCode: response.statusCode,
                    cacheControl: Self.cacheControlCategory(response),
                    bodyBytes: response.body.count,
                    hadConditionalRequest:
                        request.headers.keys.contains(where: {
                            $0.caseInsensitiveCompare("If-None-Match")
                                == .orderedSame
                                || $0.caseInsensitiveCompare(
                                    "If-Modified-Since"
                                ) == .orderedSame
                        }),
                    hadETag: Self.hasHeader("ETag", in: response),
                    hadLastModified: Self.hasHeader(
                        "Last-Modified",
                        in: response
                    )
                )
            )
        }
        return response
    }

    func observations() -> [M501SearchObservation] {
        captured
    }

    private static func cacheControlCategory(
        _ response: HTTPResponse
    ) -> String {
        guard let value = header("Cache-Control", in: response)?.lowercased()
        else {
            return "missing"
        }
        if value.contains("no-store") {
            return "no-store"
        }
        if value.contains("no-cache") {
            return "no-cache"
        }
        if value.contains("max-age") {
            return "max-age"
        }
        return "other"
    }

    private static func hasHeader(
        _ name: String,
        in response: HTTPResponse
    ) -> Bool {
        header(name, in: response) != nil
    }

    private static func header(
        _ name: String,
        in response: HTTPResponse
    ) -> String? {
        response.headers.first(where: {
            $0.key.caseInsensitiveCompare(name) == .orderedSame
        })?.value
    }
}

private struct M501SearchObservation: Sendable {
    let statusCode: Int
    let cacheControl: String
    let bodyBytes: Int
    let hadConditionalRequest: Bool
    let hadETag: Bool
    let hadLastModified: Bool
}
