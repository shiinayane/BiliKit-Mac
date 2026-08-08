import BiliAPI
import BiliApplication
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
        #expect(page.videos[0].coverURL?.scheme == "https")
        #expect(page.videos[0].owner.avatarURL?.scheme == "https")

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
    func relatedVideosUseAnonymousRequestAndDecodeShelfFields() async throws {
        let transport = RecordingTransport(
            responses: [try fixtureResponse("related")]
        )
        let authorizer = RecordingRequestAuthorizer()
        let client = BiliAPIClient(
            transport: transport,
            requestAuthorizer: authorizer
        )

        let videos = try await client.relatedVideos(to: "BV1FixtureA1")

        #expect(videos.map(\.bvid) == ["BV1RelatedA1", "BV1RelatedB2"])
        #expect(videos[0].ownerName == "相关作者甲")
        #expect(videos[0].viewCount == 22_222)
        #expect(videos[0].durationSeconds == 222)
        #expect(videos[1].durationSeconds == nil)
        let request = try #require(await transport.capturedRequests().first)
        #expect(request.url.path == "/x/web-interface/archive/related")
        #expect(
            URLComponents(url: request.url, resolvingAgainstBaseURL: false)?
                .queryItems == [URLQueryItem(name: "bvid", value: "BV1FixtureA1")]
        )
        #expect(request.headers["Cookie"] == nil)
        #expect(await authorizer.capturedPaths().isEmpty)
    }

    @Test
    func relatedVideosRejectMissingInteractiveFields() async {
        let response = HTTPResponse(
            statusCode: 200,
            headers: ["Content-Type": "application/json"],
            body: Data(
                #"{"code":0,"data":[{"bvid":"BV1RelatedA1","title":"","owner":{"name":"作者"},"stat":{"view":1,"danmaku":2}}]}"#
                    .utf8
            )
        )
        let client = BiliAPIClient(
            transport: RecordingTransport(responses: [response])
        )

        await #expect(throws: BiliAPIError.decodingFailed) {
            try await client.relatedVideos(to: "BV1FixtureA1")
        }
    }

    @Test
    func relatedVideosAcceptEmptyResponse() async throws {
        let response = HTTPResponse(
            statusCode: 200,
            headers: ["Content-Type": "application/json"],
            body: Data(#"{"code":0,"data":[]}"#.utf8)
        )
        let client = BiliAPIClient(
            transport: RecordingTransport(responses: [response])
        )

        let videos = try await client.relatedVideos(to: "BV1FixtureA1")

        #expect(videos.isEmpty)
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
        #expect(
            requests.map(\.url.path) == [
                "/x/web-interface/nav",
                "/x/web-interface/wbi/search/type",
            ]
        )
        let searchQuery = URLComponents(
            url: requests[1].url,
            resolvingAgainstBaseURL: false
        )?.queryItems
        #expect(searchQuery?.first(where: { $0.name == "keyword" })?.value == "macOS  测试")
        #expect(searchQuery?.first(where: { $0.name == "wts" })?.value == "1700000000")
        #expect(searchQuery?.first(where: { $0.name == "w_rid" })?.value?.count == 32)
    }

    @Test
    func searchRejectsNegativeDuration() async throws {
        let response = try fixtureResponse("search")
        let source = try #require(
            String(data: response.body, encoding: .utf8)
        )
        let body = try #require(
            source.replacingOccurrences(
                of: "\"duration\": \"01:02:03\"",
                with: "\"duration\": \"-01:02:03\""
            ).data(using: .utf8)
        )
        let transport = RecordingTransport(
            responses: [
                try fixtureResponse("nav"),
                HTTPResponse(
                    statusCode: response.statusCode,
                    headers: response.headers,
                    body: body
                ),
            ]
        )
        let client = BiliAPIClient(
            transport: transport,
            timestampProvider: { 1_700_000_000 }
        )

        let page = try await client.searchVideos(
            keyword: "macOS",
            page: 1
        )

        #expect(page.videos[0].durationSeconds == nil)
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
        #expect(
            requests.map(\.url.path) == [
                "/x/web-interface/nav",
                "/x/web-interface/wbi/search/type",
                "/x/web-interface/nav",
                "/x/web-interface/wbi/search/type",
            ]
        )
        let signatures =
            requests
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

        #expect(
            await transport.capturedRequests().map(\.url.path) == [
                "/x/web-interface/nav",
                "/x/web-interface/wbi/search/type",
                "/x/web-interface/nav",
                "/x/web-interface/wbi/search/type",
            ]
        )
    }

    @Test
    func playURLMapsOnlyAVCAndAACRepresentations() async throws {
        let transport = RecordingTransport(responses: [try fixtureResponse("playurl")])
        let client = BiliAPIClient(transport: transport)

        let playback = try await client.playback(
            for: "BV1FixtureA1",
            cid: 900_001
        )

        let video = try #require(playback.manifest.videoRepresentations.first)
        let audio = try #require(playback.manifest.audioRepresentations.first)
        #expect(playback.manifest.videoRepresentations.count == 1)
        #expect(playback.manifest.audioRepresentations.count == 1)
        #expect(video.id == 32)
        #expect(video.urlCandidates.count == 2)
        #expect(video.videoAttributes?.width == 1280)
        #expect(video.videoAttributes?.height == 720)
        #expect(video.videoAttributes?.frameRate == 60_000.0 / 1_001.0)
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
        #expect(queryItems?.contains(URLQueryItem(name: "qn", value: "120")) == true)
        #expect(queryItems?.contains(URLQueryItem(name: "fnval", value: "976")) == true)
        #expect(queryItems?.contains(URLQueryItem(name: "fourk", value: "1")) == true)
        #expect(queryItems?.contains(URLQueryItem(name: "cid", value: "900001")) == true)
    }

    @Test
    func playbackUsesCredentialOnlyForPlayURLRequest() async throws {
        let authorizer = RecordingRequestAuthorizer()
        let transport = RecordingTransport(
            responses: [try fixtureResponse("playurl")]
        )
        let client = BiliAPIClient(
            transport: transport,
            requestAuthorizer: authorizer
        )

        let playback = try await client.playback(
            for: "BV1FixtureA1",
            cid: 900_001
        )

        #expect(await authorizer.capturedPaths() == ["/x/player/playurl"])
        #expect(Set(playback.mediaHeaders.keys) == ["Referer", "User-Agent"])
        #expect(playback.mediaHeaders["Cookie"] == nil)
        let request = try #require(await transport.capturedRequests().first)
        #expect(request.headers["Cookie"] == "FIXTURE_AUTHORIZED")
    }

    @Test
    func playbackUsesAnonymousRequestOnlyForExplicitlyMissingCredential()
        async throws
    {
        let transport = RecordingTransport(
            responses: [try fixtureResponse("playurl")]
        )
        let client = BiliAPIClient(
            transport: transport,
            requestAuthorizer: ThrowingRequestAuthorizer(
                kind: .missingCredential
            )
        )

        let playback = try await client.playback(
            for: "BV1FixtureA1",
            cid: 900_001
        )

        #expect(playback.mediaHeaders["Cookie"] == nil)
        let request = try #require(await transport.capturedRequests().first)
        #expect(request.headers["Cookie"] == nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func cancelledMissingCredentialResolutionDoesNotSendAnonymousFallback() async {
        let authorizer = SuspendingMissingCredentialAuthorizer()
        let transport = RecordingTransport(responses: [])
        let client = BiliAPIClient(
            transport: transport,
            requestAuthorizer: authorizer
        )
        let playbackTask = Task {
            try await client.playback(for: "BV1FixtureA1", cid: 900_001)
        }
        await authorizer.waitUntilAuthorizationStarts()

        playbackTask.cancel()
        await authorizer.resumeWithMissingCredential()

        await #expect(throws: CancellationError.self) {
            try await playbackTask.value
        }
        #expect(await transport.capturedRequests().isEmpty)
    }

    @Test(.timeLimit(.minutes(1)))
    func missingCredentialResolutionCannotCrossSessionInvalidationBoundary() async {
        let authorizer = SuspendingMissingCredentialAuthorizer()
        let transport = RecordingTransport(responses: [])
        let client = BiliAPIClient(
            transport: transport,
            requestAuthorizer: authorizer
        )
        let playbackTask = Task {
            try await client.playback(for: "BV1FixtureA1", cid: 900_001)
        }
        await authorizer.waitUntilAuthorizationStarts()

        await client.invalidateAuthenticatedSession()
        await authorizer.resumeWithMissingCredential()

        await #expect(throws: CancellationError.self) {
            try await playbackTask.value
        }
        #expect(await transport.capturedRequests().isEmpty)
    }

    @Test(arguments: [
        HTTPRequestAuthorizationFailureKind.invalidCredential,
        .unavailable,
        .denied,
    ])
    func playbackFailsClosedForNonMissingAuthorizationFailure(
        kind: HTTPRequestAuthorizationFailureKind
    ) async {
        let transport = RecordingTransport(responses: [])
        let client = BiliAPIClient(
            transport: transport,
            requestAuthorizer: ThrowingRequestAuthorizer(kind: kind)
        )

        if kind == .invalidCredential {
            await #expect(throws: BiliAPIError.authenticationInvalid) {
                try await client.playback(for: "BV1FixtureA1", cid: 900_001)
            }
        } else {
            await #expect(throws: BiliAPIError.authorizationUnavailable) {
                try await client.playback(for: "BV1FixtureA1", cid: 900_001)
            }
        }
        #expect(await transport.capturedRequests().isEmpty)
    }

    @Test(arguments: [403, 412])
    func authenticatedPlaybackDoesNotRetryRemoteRestrictionAnonymously(
        statusCode: Int
    ) async {
        let transport = RecordingTransport(
            responses: [HTTPResponse(statusCode: statusCode, body: Data())]
        )
        let client = BiliAPIClient(
            transport: transport,
            requestAuthorizer: RecordingRequestAuthorizer()
        )

        await #expect(throws: BiliAPIError.httpStatus(statusCode)) {
            try await client.playback(for: "BV1FixtureA1", cid: 900_001)
        }
        #expect(await transport.capturedRequests().count == 1)
    }

    @Test
    func authenticatedPlaybackMapsRemoteSessionInvalidationWithoutRetry()
        async
    {
        let response = HTTPResponse(
            statusCode: 200,
            headers: ["Content-Type": "application/json"],
            body: Data(#"{"code":-101,"message":"fixture"}"#.utf8)
        )
        let transport = RecordingTransport(responses: [response])
        let client = BiliAPIClient(
            transport: transport,
            requestAuthorizer: RecordingRequestAuthorizer()
        )

        await #expect(throws: BiliAPIError.authenticationInvalid) {
            try await client.playback(for: "BV1FixtureA1", cid: 900_001)
        }
        #expect(await transport.capturedRequests().count == 1)
    }

    @Test
    func authenticatedPlaybackDoesNotRetryBusinessRejectionAnonymously() async {
        let response = HTTPResponse(
            statusCode: 200,
            headers: ["Content-Type": "application/json"],
            body: Data(#"{"code":-404,"message":"fixture"}"#.utf8)
        )
        let transport = RecordingTransport(responses: [response])
        let client = BiliAPIClient(
            transport: transport,
            requestAuthorizer: RecordingRequestAuthorizer()
        )

        await #expect(throws: BiliAPIError.apiRejected(code: -404, message: "fixture")) {
            try await client.playback(for: "BV1FixtureA1", cid: 900_001)
        }
        #expect(await transport.capturedRequests().count == 1)
    }

    @Test(.timeLimit(.minutes(1)))
    func authenticatedRequestCannotCrossSessionInvalidationBoundary() async throws {
        let authorizer = SuspendingRequestAuthorizer()
        let response = try fixtureResponse("playurl")
        let firstTransport = RecordingInvalidatingAPITransport(response: response)
        let replacementTransport = RecordingInvalidatingAPITransport(response: response)
        let transportFactory = SequentialTransportFactory(
            transports: [firstTransport, replacementTransport]
        )
        let client = BiliAPIClient(
            requestAuthorizer: authorizer,
            transportFactory: { transportFactory.makeTransport() }
        )

        let playbackTask = Task {
            try await client.playback(for: "BV1FixtureA1", cid: 900_001)
        }
        await authorizer.waitUntilAuthorizationStarts()

        await client.invalidateAuthenticatedSession()
        await authorizer.resumeAuthorization()

        await #expect(throws: CancellationError.self) {
            try await playbackTask.value
        }
        #expect(firstTransport.capturedRequests().isEmpty)
        #expect(replacementTransport.capturedRequests().isEmpty)
        #expect(firstTransport.wasInvalidated)
    }

    @Test(.timeLimit(.minutes(1)))
    func authenticatedResponseCannotWriteBackAfterSessionInvalidation() async throws {
        let response = try fixtureResponse("playurl")
        let firstTransport = SuspendingResponseTransport(response: response)
        let replacementTransport = RecordingInvalidatingAPITransport(response: response)
        let transportFactory = SequentialTransportFactory(
            transports: [firstTransport, replacementTransport]
        )
        let client = BiliAPIClient(
            requestAuthorizer: RecordingRequestAuthorizer(),
            transportFactory: { transportFactory.makeTransport() }
        )

        let playbackTask = Task {
            try await client.playback(for: "BV1FixtureA1", cid: 900_001)
        }
        await firstTransport.waitUntilRequestStarts()

        await client.invalidateAuthenticatedSession()
        await firstTransport.resumeResponse()

        await #expect(throws: CancellationError.self) {
            try await playbackTask.value
        }
        #expect(await firstTransport.capturedRequests().count == 1)
        #expect(replacementTransport.capturedRequests().isEmpty)
        #expect(firstTransport.wasInvalidated)
    }

    @Test
    func playURLRejectsInvalidVideoFrameRate() async throws {
        let fixture = try fixtureResponse("playurl")
        let invalidBody = String(decoding: fixture.body, as: UTF8.self)
            .replacingOccurrences(
                of: "\"frame_rate\": \"60000/1001\"",
                with: "\"frame_rate\": \"60/0\""
            )
        let response = HTTPResponse(
            statusCode: fixture.statusCode,
            headers: fixture.headers,
            body: Data(invalidBody.utf8)
        )
        let client = BiliAPIClient(
            transport: RecordingTransport(responses: [response])
        )

        await #expect(throws: BiliAPIError.invalidMediaData) {
            try await client.playback(
                for: "BV1FixtureA1",
                cid: 900_001,
                quality: 32
            )
        }
    }

    @Test
    func playURLRejectsRepresentationsWithoutTrustedMediaOrigin() async throws {
        let fixture = try fixtureResponse("playurl")
        let unsafeBody = String(decoding: fixture.body, as: UTF8.self)
            .replacingOccurrences(of: "media.example.invalid", with: "127.0.0.1")
            .replacingOccurrences(of: "backup.example.invalid", with: "localhost")
        let response = HTTPResponse(
            statusCode: fixture.statusCode,
            headers: fixture.headers,
            body: Data(unsafeBody.utf8)
        )
        let client = BiliAPIClient(
            transport: RecordingTransport(responses: [response])
        )

        await #expect(throws: BiliAPIError.invalidMediaData) {
            try await client.playback(
                for: "BV1FixtureA1",
                cid: 900_001,
                quality: 32
            )
        }
    }

    @Test
    func historyUsesExplicitAuthorizationAndMapsOnlyPlayableArchives() async throws {
        let transport = RecordingTransport(
            responses: [
                try fixtureResponse("history"),
                try fixtureResponse("history"),
            ]
        )
        let authorizer = RecordingRequestAuthorizer()
        let client = BiliAPIClient(
            transport: transport,
            requestAuthorizer: authorizer
        )

        let page = try await client.watchHistory(pageSize: 2)

        #expect(page.items.map(\.bvid) == ["BV1HistoryA1", "BV1HistoryB2"])
        #expect(page.items[0].progressSeconds == 125)
        #expect(page.items[1].progressSeconds == 300)
        #expect(page.items[0].coverURL?.scheme == "https")
        #expect(page.items[0].owner.avatarURL?.scheme == "https")
        #expect(page.items[1].owner.avatarURL == nil)
        let continuation = try #require(page.continuation)
        _ = try await client.watchHistory(
            after: continuation,
            pageSize: 2
        )

        let requests = await transport.capturedRequests()
        let request = try #require(requests.first)
        #expect(request.url.path == "/x/web-interface/history/cursor")
        #expect(request.headers["Cookie"] == "FIXTURE_AUTHORIZED")
        #expect(request.headers["Referer"] == "https://www.bilibili.com/account/history")
        let query = URLComponents(
            url: request.url,
            resolvingAgainstBaseURL: false
        )?.queryItems
        #expect(query?.contains(URLQueryItem(name: "max", value: "0")) == true)
        #expect(query?.contains(URLQueryItem(name: "ps", value: "2")) == true)
        let continuationQuery = URLComponents(
            url: requests[1].url,
            resolvingAgainstBaseURL: false
        )?.queryItems
        #expect(
            continuationQuery?.contains(
                URLQueryItem(name: "max", value: "1700000001")
            ) == true
        )
        #expect(
            continuationQuery?.contains(
                URLQueryItem(name: "business", value: "archive")
            ) == true
        )
        #expect(
            await authorizer.capturedPaths() == [
                "/x/web-interface/history/cursor",
                "/x/web-interface/history/cursor",
            ]
        )
    }

    @Test
    func anonymousGuestAndRelatedEndpointsNeverRequestCredentialAuthorization()
        async throws
    {
        let authorizer = RecordingRequestAuthorizer()
        let client = BiliAPIClient(
            transport: RecordingTransport(
                responses: [
                    try fixtureResponse("popular"),
                    try fixtureResponse("related"),
                ]
            ),
            requestAuthorizer: authorizer
        )

        _ = try await client.popular(page: 1, pageSize: 20)
        _ = try await client.relatedVideos(to: "BV1FixtureA1")

        #expect(await authorizer.capturedPaths().isEmpty)
    }

    @Test
    func historyFailsClosedBeforeTransportWithoutAuthorizer() async {
        let transport = RecordingTransport(responses: [])
        let client = BiliAPIClient(transport: transport)

        await #expect(throws: BiliAPIError.authorizationRequired) {
            try await client.watchHistory(pageSize: 20)
        }
        #expect(await transport.capturedRequests().isEmpty)
    }

    @Test
    func historyRejectsMalformedContinuationBeforeTransport() async {
        let transport = RecordingTransport(responses: [])
        let client = BiliAPIClient(
            transport: transport,
            requestAuthorizer: RecordingRequestAuthorizer()
        )

        await #expect(throws: BiliAPIError.invalidRequest) {
            try await client.watchHistory(
                after: WatchHistoryContinuation(rawValue: "not-a-valid-token"),
                pageSize: 20
            )
        }
        #expect(await transport.capturedRequests().isEmpty)
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

private actor RecordingRequestAuthorizer: HTTPRequestAuthorizing {
    private var paths: [String] = []

    func authorize(_ request: HTTPRequest) -> HTTPRequest {
        paths.append(request.url.path)
        var headers = request.headers
        headers["Cookie"] = "FIXTURE_AUTHORIZED"
        return HTTPRequest(
            url: request.url,
            method: request.method,
            headers: headers,
            body: request.body
        )
    }

    func capturedPaths() -> [String] {
        paths
    }
}

private actor SuspendingRequestAuthorizer: HTTPRequestAuthorizing {
    private var authorizationStarted = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var authorizationContinuation: CheckedContinuation<Void, Never>?

    func authorize(_ request: HTTPRequest) async -> HTTPRequest {
        authorizationStarted = true
        for waiter in startWaiters {
            waiter.resume()
        }
        startWaiters.removeAll()
        await withCheckedContinuation { continuation in
            authorizationContinuation = continuation
        }
        var headers = request.headers
        headers["Cookie"] = "FIXTURE_AUTHORIZED"
        return HTTPRequest(
            url: request.url,
            method: request.method,
            headers: headers,
            body: request.body
        )
    }

    func waitUntilAuthorizationStarts() async {
        guard !authorizationStarted else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func resumeAuthorization() {
        authorizationContinuation?.resume()
        authorizationContinuation = nil
    }
}

private actor SuspendingMissingCredentialAuthorizer: HTTPRequestAuthorizing {
    private var authorizationStarted = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var authorizationContinuation: CheckedContinuation<Void, Never>?

    func authorize(_ request: HTTPRequest) async throws -> HTTPRequest {
        authorizationStarted = true
        for waiter in startWaiters {
            waiter.resume()
        }
        startWaiters.removeAll()
        await withCheckedContinuation { continuation in
            authorizationContinuation = continuation
        }
        throw FixtureAuthorizationFailure(kind: .missingCredential)
    }

    func waitUntilAuthorizationStarts() async {
        guard !authorizationStarted else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func resumeWithMissingCredential() {
        authorizationContinuation?.resume()
        authorizationContinuation = nil
    }
}

private final class RecordingInvalidatingAPITransport: HTTPTransport,
    HTTPTransportInvalidating, @unchecked Sendable
{
    private let lock = NSLock()
    private let response: HTTPResponse
    private var requests: [HTTPRequest] = []
    private var invalidated = false

    init(response: HTTPResponse) {
        self.response = response
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        lock.withLock {
            requests.append(request)
        }
        return response
    }

    func invalidateAndCancel() {
        lock.withLock {
            invalidated = true
        }
    }

    func capturedRequests() -> [HTTPRequest] {
        lock.withLock { requests }
    }

    var wasInvalidated: Bool {
        lock.withLock { invalidated }
    }
}

private final class SequentialTransportFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var transports: [any HTTPTransport]

    init(transports: [any HTTPTransport]) {
        self.transports = transports
    }

    func makeTransport() -> any HTTPTransport {
        lock.withLock {
            precondition(!transports.isEmpty)
            return transports.removeFirst()
        }
    }
}

private final class SuspendingResponseTransport: HTTPTransport,
    HTTPTransportInvalidating, @unchecked Sendable
{
    private let flow: SuspendingResponseTransportFlow
    private let lock = NSLock()
    private var invalidated = false

    init(response: HTTPResponse) {
        flow = SuspendingResponseTransportFlow(response: response)
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        await flow.send(request)
    }

    func invalidateAndCancel() {
        lock.withLock {
            invalidated = true
        }
    }

    func waitUntilRequestStarts() async {
        await flow.waitUntilRequestStarts()
    }

    func resumeResponse() async {
        await flow.resumeResponse()
    }

    func capturedRequests() async -> [HTTPRequest] {
        await flow.capturedRequests()
    }

    var wasInvalidated: Bool {
        lock.withLock { invalidated }
    }
}

private actor SuspendingResponseTransportFlow {
    private let response: HTTPResponse
    private var requests: [HTTPRequest] = []
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var responseContinuation: CheckedContinuation<Void, Never>?

    init(response: HTTPResponse) {
        self.response = response
    }

    func send(_ request: HTTPRequest) async -> HTTPResponse {
        requests.append(request)
        for waiter in startWaiters {
            waiter.resume()
        }
        startWaiters.removeAll()
        await withCheckedContinuation { continuation in
            responseContinuation = continuation
        }
        return response
    }

    func waitUntilRequestStarts() async {
        guard requests.isEmpty else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func resumeResponse() {
        responseContinuation?.resume()
        responseContinuation = nil
    }

    func capturedRequests() -> [HTTPRequest] {
        requests
    }
}

private struct ThrowingRequestAuthorizer: HTTPRequestAuthorizing {
    let kind: HTTPRequestAuthorizationFailureKind

    func authorize(_ request: HTTPRequest) throws -> HTTPRequest {
        throw FixtureAuthorizationFailure(kind: kind)
    }
}

private struct FixtureAuthorizationFailure: HTTPRequestAuthorizationFailure {
    let authorizationFailureKind: HTTPRequestAuthorizationFailureKind

    init(kind: HTTPRequestAuthorizationFailureKind) {
        authorizationFailureKind = kind
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
