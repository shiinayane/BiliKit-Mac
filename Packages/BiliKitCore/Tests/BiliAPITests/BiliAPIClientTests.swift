import BiliAPI
import BiliModels
import BiliNetworking
import Foundation
import Testing

struct BiliAPIClientTests {
    @Test
    func popularDecodesSanitizedContractAndBuildsGuestRequest() async throws {
        let transport = RecordingTransport(responses: [try fixtureResponse("popular")])
        let client = BiliAPIClient(transport: transport)

        let page = try await client.popular(page: 2, pageSize: 10)

        #expect(page.pageNumber == 2)
        #expect(page.pageSize == 10)
        #expect(page.videos.count == 2)
        #expect(page.videos[0].bvid == "BV1FixtureA1")
        #expect(page.videos[0].owner.name == "测试作者甲")
        #expect(page.videos[0].statistics.viewCount == 12_345)

        let request = try #require(await transport.capturedRequests().first)
        #expect(request.url.path == "/x/web-interface/popular")
        let query = try #require(URLComponents(url: request.url, resolvingAgainstBaseURL: false))
        #expect(query.queryItems?.contains(URLQueryItem(name: "pn", value: "2")) == true)
        #expect(query.queryItems?.contains(URLQueryItem(name: "ps", value: "10")) == true)
        #expect(request.headers["Accept"] == "application/json")
        #expect(request.headers["Referer"] == "https://www.bilibili.com/")
    }

    @Test
    func pageListDecodesMultipleParts() async throws {
        let transport = RecordingTransport(responses: [try fixtureResponse("pagelist")])
        let client = BiliAPIClient(transport: transport)

        let pages = try await client.pages(for: "BV1FixtureA1")

        #expect(pages.map(\.cid) == [900_001, 900_002])
        #expect(pages.map(\.index) == [1, 2])
        #expect(pages[1].dimension?.width == 1080)
        let request = try #require(await transport.capturedRequests().first)
        #expect(request.url.path == "/x/player/pagelist")
        #expect(request.headers["Referer"] == "https://www.bilibili.com/video/BV1FixtureA1/")
    }

    @Test
    func videoDetailDecodesSanitizedContract() async throws {
        let transport = RecordingTransport(responses: [try fixtureResponse("view")])
        let client = BiliAPIClient(transport: transport)

        let detail = try await client.videoDetail(for: "BV1FixtureA1")

        #expect(detail.bvid == "BV1FixtureA1")
        #expect(detail.title == "合成视频详情 A")
        #expect(detail.summary == "这是手写的脱敏详情说明。")
        #expect(detail.owner.id == 10_001)
        #expect(detail.statistics.likeCount == 3_456)
        #expect(detail.dimension == VideoDimension(width: 1920, height: 1080, rotation: 0))

        let request = try #require(await transport.capturedRequests().first)
        #expect(request.url.path == "/x/web-interface/view")
        #expect(request.headers["Referer"] == "https://www.bilibili.com/video/BV1FixtureA1/")
    }

    @Test
    func searchUsesWBIAndNormalizesEndpointQuirks() async throws {
        let transport = RecordingTransport(
            responses: [
                try fixtureResponse("nav"),
                try fixtureResponse("search"),
            ]
        )
        let client = BiliAPIClient(
            transport: transport,
            timestampProvider: { 1_700_000_000 }
        )

        let page = try await client.searchVideos(
            keyword: " macOS !'()* 测试 ",
            page: 1
        )

        #expect(page.totalResults == 3)
        #expect(page.videos.count == 2)
        #expect(page.videos[0].title == "学习macOS 的第一步")
        #expect(page.videos[0].durationSeconds == 3_723)
        #expect(page.videos[0].coverURL?.scheme == "https")
        #expect(page.videos[1].durationSeconds == 754)

        let requests = await transport.capturedRequests()
        #expect(requests.map(\.url.path) == [
            "/x/web-interface/nav",
            "/x/web-interface/wbi/search/type",
        ])
        let searchQuery = URLComponents(
            url: requests[1].url,
            resolvingAgainstBaseURL: false
        )?.queryItems
        #expect(searchQuery?.first(where: { $0.name == "keyword" })?.value == "macOS  测试")
        #expect(searchQuery?.first(where: { $0.name == "wts" })?.value == "1700000000")
        #expect(searchQuery?.first(where: { $0.name == "w_rid" })?.value?.count == 32)
    }

    @Test
    func searchReusesSameDayWBIKey() async throws {
        let transport = RecordingTransport(
            responses: [
                try fixtureResponse("nav"),
                try fixtureResponse("search"),
                try fixtureResponse("search"),
            ]
        )
        let client = BiliAPIClient(
            transport: transport,
            timestampProvider: { 1_700_000_000 }
        )

        _ = try await client.searchVideos(keyword: "macOS", page: 1)
        _ = try await client.searchVideos(keyword: "Swift", page: 1)

        let paths = await transport.capturedRequests().map(\.url.path)
        #expect(paths.filter { $0 == "/x/web-interface/nav" }.count == 1)
        #expect(paths.filter { $0 == "/x/web-interface/wbi/search/type" }.count == 2)
    }

    @Test
    func signatureRejectionRefreshesWBIKeyOnce() async throws {
        let rejected = HTTPResponse(
            statusCode: 200,
            headers: ["Content-Type": "application/json"],
            body: Data(
                #"{"code":-403,"message":"访问权限不足","data":{"unexpected":true}}"#.utf8
            )
        )
        let transport = RecordingTransport(
            responses: [
                try fixtureResponse("nav"),
                rejected,
                try fixtureResponse("nav-refreshed"),
                try fixtureResponse("search"),
            ]
        )
        let client = BiliAPIClient(
            transport: transport,
            timestampProvider: { 1_700_000_000 }
        )

        let page = try await client.searchVideos(keyword: "macOS", page: 1)

        #expect(page.videos.count == 2)
        let requests = await transport.capturedRequests()
        #expect(requests.map(\.url.path) == [
            "/x/web-interface/nav",
            "/x/web-interface/wbi/search/type",
            "/x/web-interface/nav",
            "/x/web-interface/wbi/search/type",
        ])
        let signatures = requests
            .filter { $0.url.path.contains("/wbi/search/") }
            .compactMap {
                URLComponents(url: $0.url, resolvingAgainstBaseURL: false)?
                    .queryItems?
                    .first(where: { $0.name == "w_rid" })?
                    .value
            }
        #expect(signatures.count == 2)
        #expect(signatures[0] != signatures[1])
    }

    @Test
    func httpForbiddenAlsoRefreshesWBIKeyOnce() async throws {
        let transport = RecordingTransport(
            responses: [
                try fixtureResponse("nav"),
                HTTPResponse(statusCode: 403, body: Data()),
                try fixtureResponse("nav-refreshed"),
                try fixtureResponse("search"),
            ]
        )
        let client = BiliAPIClient(
            transport: transport,
            timestampProvider: { 1_700_000_000 }
        )

        _ = try await client.searchVideos(keyword: "macOS", page: 1)

        #expect(await transport.capturedRequests().map(\.url.path) == [
            "/x/web-interface/nav",
            "/x/web-interface/wbi/search/type",
            "/x/web-interface/nav",
            "/x/web-interface/wbi/search/type",
        ])
    }

    @Test
    func playURLMapsOnlyAVCAndAACRepresentations() async throws {
        let transport = RecordingTransport(responses: [try fixtureResponse("playurl")])
        let client = BiliAPIClient(transport: transport)

        let playback = try await client.playback(
            for: "BV1FixtureA1",
            cid: 900_001,
            quality: 32
        )

        let video = try #require(playback.manifest.videoRepresentations.first)
        let audio = try #require(playback.manifest.audioRepresentations.first)
        #expect(playback.manifest.videoRepresentations.count == 1)
        #expect(playback.manifest.audioRepresentations.count == 1)
        #expect(video.id == 32)
        #expect(video.urlCandidates.count == 2)
        #expect(video.segmentBase.initialization.httpRangeHeaderValue == "bytes=0-999")
        #expect(audio.id == 30216)
        #expect(audio.segmentBase.index.httpRangeHeaderValue == "bytes=800-1599")
        #expect(playback.mediaHeaders["Referer"]?.contains("BV1FixtureA1") == true)

        let request = try #require(await transport.capturedRequests().first)
        #expect(request.url.path == "/x/player/playurl")
        let queryItems = URLComponents(
            url: request.url,
            resolvingAgainstBaseURL: false
        )?.queryItems
        #expect(queryItems?.contains(URLQueryItem(name: "fnval", value: "16")) == true)
        #expect(queryItems?.contains(URLQueryItem(name: "cid", value: "900001")) == true)
    }

    @Test
    func rejectsHTMLRiskControlPageBeforeDecoding() async {
        let response = HTTPResponse(
            statusCode: 200,
            headers: ["Content-Type": "text/html; charset=utf-8"],
            body: Data("<html>risk control</html>".utf8)
        )
        let client = BiliAPIClient(transport: RecordingTransport(responses: [response]))

        await #expect(throws: BiliAPIError.nonJSONResponse) {
            try await client.popular(page: 1, pageSize: 20)
        }
    }

    @Test
    func preservesAPIErrorCodeWithoutLeakingBody() async {
        let body = Data(
            #"{"code":-412,"message":"请求被拦截","data":{"unexpected":true}}"#.utf8
        )
        let response = HTTPResponse(
            statusCode: 200,
            headers: ["Content-Type": "application/json"],
            body: body
        )
        let client = BiliAPIClient(transport: RecordingTransport(responses: [response]))

        await #expect(
            throws: BiliAPIError.apiRejected(code: -412, message: "请求被拦截")
        ) {
            try await client.popular(page: 1, pageSize: 20)
        }
    }

    @Test
    func missingRequiredContractFieldFailsDecoding() async {
        let body = Data(
            #"{"code":0,"message":"OK","data":{"list":[{"bvid":"BV1FixtureA1"}]}}"#.utf8
        )
        let response = HTTPResponse(
            statusCode: 200,
            headers: ["Content-Type": "application/json"],
            body: body
        )
        let client = BiliAPIClient(transport: RecordingTransport(responses: [response]))

        await #expect(throws: BiliAPIError.decodingFailed) {
            try await client.popular(page: 1, pageSize: 20)
        }
    }

    @Test
    func cancellationIsNotCollapsedIntoTransportFailure() async {
        let client = BiliAPIClient(transport: CancellationTransport())

        await #expect(throws: CancellationError.self) {
            try await client.pages(for: "BV1FixtureA1")
        }
    }

    @Test
    func validatesInputBeforeSendingRequest() async {
        let transport = RecordingTransport(responses: [])
        let client = BiliAPIClient(transport: transport)

        await #expect(throws: BiliAPIError.invalidRequest) {
            try await client.pages(for: "not-a-bvid")
        }
        #expect(await transport.capturedRequests().isEmpty)
    }

    private func fixtureResponse(_ name: String) throws -> HTTPResponse {
        let url = try #require(
            Bundle.module.url(
                forResource: name,
                withExtension: "json",
                subdirectory: "Fixtures"
            )
        )
        return HTTPResponse(
            statusCode: 200,
            headers: ["Content-Type": "application/json; charset=utf-8"],
            body: try Data(contentsOf: url)
        )
    }
}

private actor RecordingTransport: HTTPTransport {
    private var responses: [HTTPResponse]
    private var requests: [HTTPRequest] = []

    init(responses: [HTTPResponse]) {
        self.responses = responses
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        requests.append(request)
        guard !responses.isEmpty else {
            throw RecordingTransportError.missingResponse
        }
        return responses.removeFirst()
    }

    func capturedRequests() -> [HTTPRequest] {
        requests
    }
}

private struct CancellationTransport: HTTPTransport {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        throw CancellationError()
    }
}

private enum RecordingTransportError: Error {
    case missingResponse
}
