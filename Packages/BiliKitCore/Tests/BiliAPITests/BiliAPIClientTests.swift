import BiliApplication
import BiliModels
import BiliNetworking
import Foundation
import Testing

@testable import BiliAPI

struct BiliAPIClientTests {
    @Test(arguments: AccountReadCase.all)
    func accountReadEndpointsAuthorizeOnlyTheirOwnRequest(
        _ testCase: AccountReadCase
    ) async throws {
        let transport = StubTransport(responses: try testCase.responses())
        let authorizer = StubAuthorizer()
        let client = BiliAPIClient(
            transport: transport,
            requestAuthorizer: authorizer,
            timestampProvider: { 1_700_000_000 }
        )

        try await testCase.call(client)

        let requests = transport.capturedRequests()
        #expect(await authorizer.capturedPaths() == [testCase.path])
        #expect(requests.last?.url.path == testCase.path)
        #expect(requests.last?.headers["Cookie"] == StubAuthorizer.cookie)
        // WBI key 的 nav 请求始终匿名。
        #expect(requests.dropLast().allSatisfy { $0.headers["Cookie"] == nil })
    }

    @Test
    func recommendationsUseWBIAndFilterUnsupportedCards() async throws {
        let response = jsonResponse(AccountReadCase.recommendationBody)
        let transport = StubTransport(
            responses: [try fixtureResponse("nav"), response]
        )
        let client = BiliAPIClient(
            transport: transport,
            requestAuthorizer: StubAuthorizer(),
            timestampProvider: { 1_700_000_000 }
        )

        let page = try await client.recommendations()

        #expect(page.videos.map(\.bvid) == ["BV1FixtureA1"])
        #expect(page.videos.first?.title == "推荐 & 视频")
        #expect(page.videos.first?.recommendationReason == "正在流行")
        #expect(page.continuation == RecommendationContinuation(freshIndex: 1))
        #expect(page.nextContinuation == RecommendationContinuation(freshIndex: 2))

        let requests = transport.capturedRequests()
        #expect(
            requests.map(\.url.path) == [
                "/x/web-interface/nav",
                "/x/web-interface/wbi/index/top/feed/rcmd"
            ]
        )
        #expect(requests[1].headers["Referer"] == "https://www.bilibili.com/")
        let query = URLComponents(
            url: requests[1].url,
            resolvingAgainstBaseURL: false
        )?.queryItems
        #expect(query?.first(where: { $0.name == "fresh_idx" })?.value == "1")
        #expect(query?.first(where: { $0.name == "fresh_idx_1h" })?.value == "1")
        #expect(query?.first(where: { $0.name == "wts" })?.value == "1700000000")
        #expect(query?.first(where: { $0.name == "w_rid" })?.value?.count == 32)
    }

    @Test
    func videoDetailPreservesCurrentPagesAndNestedUGCCollection() async throws {
        let response = jsonResponse(
            #"""
            {"code":0,"data":{"aid":7001,"bvid":"BV1FixtureA1","title":"当前视频","desc":"说明","pic":"https://images.example.invalid/current.jpg","owner":{"mid":10001,"name":"作者"},"stat":{"view":1,"danmaku":2,"like":3},"duration":300,"pubdate":1720000000,"pages":[{"cid":900001,"page":1,"part":"当前 P1","duration":120},{"cid":900002,"page":2,"part":"当前 P2","duration":180}],"ugc_season":{"id":501,"title":"测试合集","ep_count":3,"sections":[{"season_id":501,"id":601,"title":"第一章","episodes":[{"season_id":501,"section_id":601,"id":701,"aid":7001,"bvid":"BV1FixtureA1","cid":900001,"title":"当前视频","arc":{"aid":7001,"bvid":"BV1FixtureA1","title":"当前视频","pic":"https://images.example.invalid/current.jpg","duration":300},"pages":[{"cid":900001,"page":1,"part":"当前 P1","duration":120},{"cid":900002,"page":2,"part":"当前 P2","duration":180}]},{"season_id":501,"section_id":601,"id":702,"aid":7002,"bvid":"BV1FixtureB2","cid":910001,"title":"下一视频","arc":{"duration":200},"page":{"cid":910001,"page":1,"part":"默认 P","duration":200}}]},{"season_id":501,"id":602,"title":"第二章","episodes":[{"season_id":501,"section_id":602,"id":703,"aid":7003,"bvid":"BV1FixtureC3","cid":920001,"title":"第三视频","arc":{"duration":100}}]}]}}}
            """#
        )
        let client = BiliAPIClient(
            transport: StubTransport(responses: [response])
        )

        let detail = try await client.videoDetail(for: "BV1FixtureA1")

        #expect(detail.aid == 7_001)
        #expect(detail.pages.map(\.cid) == [900_001, 900_002])
        let collection = try #require(detail.collection)
        #expect(collection.id == 501)
        #expect(collection.sections.count == 2)
        #expect(collection.embeddedEpisodeCount == 3)
        #expect(collection.embeddedCountMatchesReportedCount == true)
        #expect(collection.sections[0].ordinal == 0)
        #expect(collection.sections[1].ordinal == 1)
        #expect(collection.sections[0].episodes[0].knownPages?.map(\.cid) == [900_001, 900_002])
        #expect(collection.sections[0].episodes[1].knownPages == nil)
        #expect(collection.sections[0].episodes[1].defaultCID == 910_001)
    }

    @Test
    func videoDetailPreservesIncompleteCollectionSummary() async throws {
        let response = jsonResponse(
            #"{"code":0,"data":{"bvid":"BV1FixtureA1","title":"当前视频","desc":"说明","pic":"","owner":{"mid":10001,"name":"作者"},"stat":{"view":1,"danmaku":2,"like":3},"duration":120,"pubdate":1720000000,"pages":[{"cid":900001,"page":1,"part":"P1","duration":120}],"ugc_season":{"id":501,"title":"摘要合集","ep_count":20}}}"#
        )
        let client = BiliAPIClient(
            transport: StubTransport(responses: [response])
        )

        let collection = try #require(
            try await client.videoDetail(for: "BV1FixtureA1").collection
        )

        #expect(collection.sections.isEmpty)
        #expect(collection.reportedEpisodeCount == 20)
        #expect(collection.embeddedCountMatchesReportedCount == false)
    }

    @Test
    func videoDetailAndPageListRejectDuplicatePageIdentity() async {
        let pages =
            #"[{"cid":900001,"page":1,"part":"P1","duration":60},{"cid":900001,"page":2,"part":"P2","duration":60}]"#
        let client = BiliAPIClient(
            transport: StubTransport(responses: [
                jsonResponse(
                    #"{"code":0,"data":{"bvid":"BV1FixtureA1","title":"当前视频","desc":"说明","pic":"","owner":{"mid":10001,"name":"作者"},"stat":{"view":1,"danmaku":2,"like":3},"duration":120,"pubdate":1720000000,"pages":"#
                        + pages + "}}"
                ),
                jsonResponse(#"{"code":0,"data":"# + pages + "}")
            ])
        )

        await #expect(throws: BiliAPIError.decodingFailed) {
            try await client.videoDetail(for: "BV1FixtureA1")
        }
        await #expect(throws: BiliAPIError.decodingFailed) {
            try await client.pages(for: "BV1FixtureA1")
        }
    }

    @Test
    func malformedCollectionEpisodeDoesNotBlockCurrentVideo() async throws {
        let response = jsonResponse(
            #"{"code":0,"data":{"bvid":"BV1FixtureA1","title":"当前视频","desc":"说明","pic":"","owner":{"mid":10001,"name":"作者"},"stat":{"view":1,"danmaku":2,"like":3},"duration":120,"pubdate":1720000000,"pages":[{"cid":900001,"page":1,"part":"P1","duration":120}],"ugc_season":{"id":501,"title":"合集","ep_count":1,"sections":[{"season_id":501,"id":601,"title":"分部","episodes":[{"season_id":999,"section_id":601,"id":701,"aid":7001,"bvid":"BV1FixtureB2","cid":910001,"title":"","arc":{"aid":7002,"bvid":"BV1FixtureC3","duration":100},"page":{"cid":910002,"page":1,"part":"P1","duration":100}}]}]}}}"#
        )
        let client = BiliAPIClient(
            transport: StubTransport(responses: [response])
        )

        let detail = try await client.videoDetail(for: "BV1FixtureA1")

        #expect(detail.pages.map(\.cid) == [900_001])
        let episode = try #require(detail.collection?.sections.first?.episodes.first)
        #expect(!episode.isIdentityConsistent)
        #expect(episode.bvid == nil)
        #expect(episode.defaultCID == nil)
    }

    @Test
    func malformedCollectionElementsPreserveValidOccurrences() async throws {
        let response = jsonResponse(
            #"{"code":0,"data":{"bvid":"BV1FixtureA1","title":"当前视频","desc":"说明","pic":"","owner":{"mid":10001,"name":"作者"},"stat":{"view":1,"danmaku":2,"like":3},"duration":120,"pubdate":1720000000,"pages":[{"cid":900001,"page":1,"part":"P1","duration":120}],"ugc_season":{"id":501,"title":"合集","sections":[{"season_id":501,"id":601,"title":"分部","episodes":[{"season_id":501,"section_id":601,"id":701,"bvid":"BV1FixtureB2","title":"一"},null,{"season_id":501,"section_id":601,"id":702,"bvid":"BV1FixtureC3","title":"二"}]},null]}}}"#
        )
        let client = BiliAPIClient(
            transport: StubTransport(responses: [response])
        )

        let collection = try #require(
            try await client.videoDetail(for: "BV1FixtureA1").collection
        )

        #expect(collection.sections.count == 2)
        #expect(collection.sections[0].episodes.count == 3)
        #expect(collection.sections[0].episodes[0].isIdentityConsistent)
        #expect(!collection.sections[0].episodes[1].isIdentityConsistent)
        #expect(collection.sections[0].episodes[2].isIdentityConsistent)
        #expect(!collection.sections[1].isIdentityConsistent)
    }

    @Test
    func duplicateSectionOccurrencesKeepEpisodeIdentitiesDistinct() async throws {
        let response = jsonResponse(
            #"{"code":0,"data":{"bvid":"BV1FixtureA1","title":"当前视频","desc":"说明","pic":"","owner":{"mid":10001,"name":"作者"},"stat":{"view":1,"danmaku":2,"like":3},"duration":120,"pubdate":1720000000,"pages":[{"cid":900001,"page":1,"part":"P1","duration":120}],"ugc_season":{"id":501,"title":"合集","sections":[{"season_id":501,"section_id":601,"episodes":[{"season_id":501,"section_id":601,"id":701,"bvid":"BV1FixtureB2","title":"一"}]},{"season_id":501,"id":601,"episodes":[{"season_id":501,"section_id":601,"id":701,"bvid":"BV1FixtureC3","title":"二"}]}]}}}"#
        )
        let client = BiliAPIClient(
            transport: StubTransport(responses: [response])
        )

        let sections = try #require(
            try await client.videoDetail(for: "BV1FixtureA1").collection?.sections
        )
        let first = try #require(sections[0].episodes.first)
        let second = try #require(sections[1].episodes.first)

        #expect(sections[0].id.occurrenceOrdinal == 0)
        #expect(sections[1].id.occurrenceOrdinal == 1)
        #expect(first.id != second.id)
        #expect(first.id.sectionOccurrenceOrdinal == 0)
        #expect(second.id.sectionOccurrenceOrdinal == 1)
    }

    @Test
    func conflictingSectionIDAliasesAreRetainedAsInvalid() async throws {
        let response = jsonResponse(
            #"{"code":0,"data":{"bvid":"BV1FixtureA1","title":"当前视频","desc":"说明","pic":"","owner":{"mid":10001,"name":"作者"},"stat":{"view":1,"danmaku":2,"like":3},"duration":120,"pubdate":1720000000,"pages":[{"cid":900001,"page":1,"part":"P1","duration":120}],"ugc_season":{"id":501,"title":"合集","sections":[{"season_id":501,"id":601,"section_id":602,"episodes":[]}]}}}"#
        )
        let client = BiliAPIClient(
            transport: StubTransport(responses: [response])
        )

        let section = try #require(
            try await client.videoDetail(for: "BV1FixtureA1")
                .collection?.sections.first
        )

        #expect(!section.isIdentityConsistent)
    }

    @Test
    func collectionIdentityRemainsStableWhenOrderChanges() async throws {
        func response(order: String) -> HTTPResponse {
            jsonResponse(
                #"{"code":0,"data":{"bvid":"BV1FixtureA1","title":"当前视频","desc":"说明","pic":"","owner":{"mid":10001,"name":"作者"},"stat":{"view":1,"danmaku":2,"like":3},"duration":120,"pubdate":1720000000,"pages":[{"cid":900001,"page":1,"part":"P1","duration":120}],"ugc_season":{"id":501,"title":"合集","ep_count":2,"sections":[{"season_id":501,"id":601,"title":"分部","episodes":ORDER}]}}}"#
                    .replacingOccurrences(
                        of: "ORDER",
                        with: order
                    )
            )
        }
        let firstEpisode =
            #"{"season_id":501,"section_id":601,"id":701,"aid":7001,"bvid":"BV1FixtureB2","cid":910001,"title":"一"}"#
        let secondEpisode =
            #"{"season_id":501,"section_id":601,"id":702,"aid":7002,"bvid":"BV1FixtureC3","cid":920001,"title":"二"}"#
        let client = BiliAPIClient(
            transport: StubTransport(responses: [
                response(order: "[\(firstEpisode),\(secondEpisode)]"),
                response(order: "[\(secondEpisode),\(firstEpisode)]")
            ])
        )

        let first = try await client.videoDetail(for: "BV1FixtureA1")
        let second = try await client.videoDetail(for: "BV1FixtureA1")
        let firstIDs = try #require(first.collection?.sections.first?.episodes.map(\.id))
        let secondIDs = try #require(second.collection?.sections.first?.episodes.map(\.id))

        #expect(firstIDs == secondIDs.reversed())
        #expect(firstIDs[0].occurrenceOrdinal == nil)
    }

    @Test
    func episodePagesAreSortedAndDefaultCIDMustBelongToThem() async throws {
        let response = jsonResponse(
            #"{"code":0,"data":{"bvid":"BV1FixtureA1","title":"当前视频","desc":"说明","pic":"","owner":{"mid":10001,"name":"作者"},"stat":{"view":1,"danmaku":2,"like":3},"duration":120,"pubdate":1720000000,"pages":[{"cid":900001,"page":1,"part":"P1","duration":120}],"ugc_season":{"id":501,"title":"合集","sections":[{"season_id":501,"id":601,"title":"分部","episodes":[{"season_id":501,"section_id":601,"id":701,"aid":7001,"bvid":"BV1FixtureB2","cid":999999,"title":"视频","pages":[{"cid":910002,"page":2,"part":"P2","duration":50},{"cid":910001,"page":1,"part":"P1","duration":50}]}]}]}}}"#
        )
        let client = BiliAPIClient(
            transport: StubTransport(responses: [response])
        )

        let episode = try #require(
            try await client.videoDetail(for: "BV1FixtureA1")
                .collection?.sections.first?.episodes.first
        )

        #expect(episode.knownPages?.map(\.index) == [1, 2])
        #expect(episode.defaultCID == nil)
        #expect(!episode.isIdentityConsistent)
    }

    @Test
    func relatedVideosDecodeShelfFields() async throws {
        let transport = StubTransport(
            responses: [try fixtureResponse("related")]
        )
        let client = BiliAPIClient(transport: transport)

        let videos = try await client.relatedVideos(to: "BV1FixtureA1")

        #expect(videos.map(\.bvid) == ["BV1RelatedA1", "BV1RelatedB2"])
        #expect(videos[0].title == "合成相关推荐 'A' <测试>")
        #expect(videos[0].ownerName == "相关作者甲")
        #expect(videos[0].viewCount == 22_222)
        #expect(videos[0].durationSeconds == 222)
        #expect(videos[1].durationSeconds == nil)
        let request = try #require(transport.capturedRequests().first)
        #expect(request.url.path == "/x/web-interface/archive/related")
        #expect(
            URLComponents(url: request.url, resolvingAgainstBaseURL: false)?
                .queryItems == [URLQueryItem(name: "bvid", value: "BV1FixtureA1")]
        )
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
            transport: StubTransport(responses: [response])
        )

        await #expect(throws: BiliAPIError.decodingFailed) {
            try await client.relatedVideos(to: "BV1FixtureA1")
        }
    }

    @Test
    func uploaderSignatureUsesExactCardEndpoint() async throws {
        let transport = StubTransport(
            responses: [try fixtureResponse("uploader-card")]
        )
        let client = BiliAPIClient(transport: transport)

        let signature = try await client.uploaderSignature(for: 10_001)

        #expect(signature == "用影像记录生活")
        let request = try #require(transport.capturedRequests().first)
        #expect(request.method == .get)
        #expect(request.url.scheme == "https")
        #expect(request.url.host == "api.bilibili.com")
        #expect(request.url.port == nil)
        #expect(request.url.path == "/x/web-interface/card")
        #expect(
            URLComponents(url: request.url, resolvingAgainstBaseURL: false)?
                .queryItems == [
                    URLQueryItem(name: "mid", value: "10001"),
                    URLQueryItem(name: "photo", value: "false")
                ]
        )
    }

    @Test
    func uploaderSignatureAcceptsNumericMID() async throws {
        let response = jsonResponse(
            #"{"code":0,"data":{"card":{"mid":10001,"sign":"签名"}}}"#
        )
        let client = BiliAPIClient(
            transport: StubTransport(responses: [response])
        )

        #expect(try await client.uploaderSignature(for: 10_001) == "签名")
    }

    @Test
    func uploaderSignatureRejectsMismatchedMID() async {
        let response = jsonResponse(
            #"{"code":0,"data":{"card":{"mid":"10002","sign":"签名"}}}"#
        )
        let client = BiliAPIClient(
            transport: StubTransport(responses: [response])
        )

        await #expect(throws: BiliAPIError.decodingFailed) {
            try await client.uploaderSignature(for: 10_001)
        }
    }

    @Test
    func searchUsesWBIAndNormalizesEndpointQuirks() async throws {
        let transport = StubTransport(
            responses: [
                try fixtureResponse("nav"),
                try fixtureResponse("search")
            ]
        )
        let client = BiliAPIClient(
            transport: transport,
            timestampProvider: { 1_700_000_000 }
        )

        let page = try await search(client, " macOS !'()* 测试 ")

        #expect(page.totalResults == 3)
        #expect(page.videos.count == 2)
        #expect(page.videos[0].title == "学习macOS 'A' <测试>")
        #expect(page.videos[0].durationSeconds == 3_723)
        #expect(page.videos[0].coverURL?.scheme == "https")
        #expect(page.videos[1].durationSeconds == 754)

        let requests = transport.capturedRequests()
        #expect(
            requests.map(\.url.path) == [
                "/x/web-interface/nav",
                "/x/web-interface/wbi/search/type"
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
    func searchFallsBackAnonymouslyOnlyForMissingCredential() async throws {
        let transport = StubTransport(
            responses: [
                try fixtureResponse("nav"),
                try fixtureResponse("search")
            ]
        )
        let client = BiliAPIClient(
            transport: transport,
            requestAuthorizer: StubAuthorizer(.fail(.missingCredential)),
            timestampProvider: { 1_700_000_000 }
        )

        _ = try await search(client, "macOS")

        let requests = transport.capturedRequests()
        #expect(requests.count == 2)
        #expect(requests.allSatisfy { $0.headers["Cookie"] == nil })
    }

    @Test(arguments: [
        (HTTPRequestAuthorizationFailureKind.invalidCredential, BiliAPIError.authenticationInvalid),
        (.unavailable, .authorizationUnavailable),
        (.denied, .authorizationUnavailable)
    ])
    func searchFailsClosedForCredentialFailure(
        kind: HTTPRequestAuthorizationFailureKind,
        expected: BiliAPIError
    ) async throws {
        let transport = StubTransport(responses: [try fixtureResponse("nav")])
        let client = BiliAPIClient(
            transport: transport,
            requestAuthorizer: StubAuthorizer(.fail(kind)),
            timestampProvider: { 1_700_000_000 }
        )

        await #expect(throws: expected) {
            try await search(client)
        }
        #expect(
            transport.capturedRequests().map(\.url.path) == ["/x/web-interface/nav"]
        )
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
        let transport = StubTransport(
            responses: [
                try fixtureResponse("nav"),
                HTTPResponse(
                    statusCode: response.statusCode,
                    headers: response.headers,
                    body: body
                )
            ]
        )
        let client = BiliAPIClient(
            transport: transport,
            timestampProvider: { 1_700_000_000 }
        )

        let page = try await search(client, "macOS")

        #expect(page.videos[0].durationSeconds == nil)
    }

    @Test
    func searchReusesSameDayWBIKey() async throws {
        let transport = StubTransport(
            responses: [
                try fixtureResponse("nav"),
                try fixtureResponse("search"),
                try fixtureResponse("search")
            ]
        )
        let client = BiliAPIClient(
            transport: transport,
            timestampProvider: { 1_700_000_000 }
        )

        _ = try await search(client, "macOS")
        _ = try await search(client, "Swift")

        let paths = transport.capturedRequests().map(\.url.path)
        #expect(paths.filter { $0 == "/x/web-interface/nav" }.count == 1)
        #expect(paths.filter { $0 == "/x/web-interface/wbi/search/type" }.count == 2)
    }

    @Test(arguments: [
        jsonResponse(#"{"code":-403,"message":"访问权限不足","data":{"unexpected":true}}"#),
        HTTPResponse(statusCode: 403, body: Data())
    ])
    func signatureRejectionRefreshesWBIKeyOnce(rejection: HTTPResponse) async throws {
        let transport = StubTransport(
            responses: [
                try fixtureResponse("nav"),
                rejection,
                try fixtureResponse("nav-refreshed"),
                try fixtureResponse("search")
            ]
        )
        let client = BiliAPIClient(
            transport: transport,
            requestAuthorizer: StubAuthorizer(),
            timestampProvider: { 1_700_000_000 }
        )

        let page = try await search(client)

        #expect(page.videos.count == 2)
        let requests = transport.capturedRequests()
        #expect(
            requests.map(\.url.path) == [
                "/x/web-interface/nav",
                "/x/web-interface/wbi/search/type",
                "/x/web-interface/nav",
                "/x/web-interface/wbi/search/type"
            ]
        )
        let searches = [requests[1], requests[3]]
        #expect(searches.allSatisfy { $0.headers["Cookie"] == StubAuthorizer.cookie })
        let signatures = searches.map {
            URLComponents(url: $0.url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "w_rid" })?.value
        }
        #expect(signatures[0] != nil)
        #expect(signatures[0] != signatures[1])
    }

    @Test
    func playURLMapsOnlyAVCAndAACRepresentationsWithAnonymousMediaHeaders() async throws {
        let transport = StubTransport(responses: [try fixtureResponse("playurl")])
        let client = BiliAPIClient(
            transport: transport,
            requestAuthorizer: StubAuthorizer()
        )

        let playback = try await client.playback(
            for: "BV1FixtureA1",
            cid: 900_001
        )

        let manifest = try #require(playback.dashManifest)
        let video = try #require(manifest.videoRepresentations.first)
        let audioTrack = try #require(manifest.audioTracks.first)
        let audio = try #require(audioTrack.representations.first)
        #expect(manifest.videoRepresentations.count == 1)
        #expect(manifest.audioTracks.count == 1)
        #expect(audioTrack.id == "original")
        #expect(audioTrack.displayName == "原声")
        #expect(audioTrack.languageTag == nil)
        #expect(audioTrack.role == .original)
        #expect(audioTrack.isDefault)
        #expect(audioTrack.isAutoselect)
        #expect(audioTrack.representations.map(\.id) == [30216, 30280])
        #expect(video.id == 32)
        #expect(video.urlCandidates.count == 2)
        #expect(video.videoAttributes?.width == 1280)
        #expect(video.videoAttributes?.height == 720)
        #expect(video.videoAttributes?.frameRate == 60_000.0 / 1_001.0)
        #expect(video.segmentBase.initialization.httpRangeHeaderValue == "bytes=0-999")
        #expect(audio.id == 30216)
        #expect(audio.segmentBase.index.httpRangeHeaderValue == "bytes=800-1599")
        #expect(playback.mediaHeaders["Referer"]?.contains("BV1FixtureA1") == true)
        // playurl 请求可带账户凭据，交给 CDN 的媒体 header 不得带。
        #expect(Set(playback.mediaHeaders.keys) == ["Referer", "User-Agent"])

        let request = try #require(transport.capturedRequests().first)
        #expect(request.url.path == "/x/player/playurl")
        let queryItems = URLComponents(
            url: request.url,
            resolvingAgainstBaseURL: false
        )?.queryItems
        #expect(queryItems?.contains(URLQueryItem(name: "qn", value: "120")) == true)
        #expect(queryItems?.contains(URLQueryItem(name: "fnval", value: "976")) == true)
        #expect(queryItems?.contains(URLQueryItem(name: "fourk", value: "1")) == true)
        #expect(queryItems?.contains(URLQueryItem(name: "cid", value: "900001")) == true)
        #expect(
            queryItems?.contains(
                URLQueryItem(name: "voice_balance", value: "1")
            ) == true
        )
    }

    @Test
    func playURLMapsSingleSafeDURLAsProgressiveMedia() async throws {
        let client = BiliAPIClient(
            transport: StubTransport(
                responses: [try ProgressiveShape.singleSafeSegment.response()]
            )
        )

        let playback = try await client.playback(
            for: "BV1FixtureA1",
            cid: 900_001
        )

        guard case .progressive(let source) = playback.media else {
            Issue.record("Expected progressive media")
            return
        }
        #expect(source.contentLength == 50_000_000)
        #expect(source.durationMilliseconds == 884_983)
        #expect(source.container == .mp4)
        #expect(source.urlCandidates.count == 2)
        #expect(playback.mediaHeaders["Cookie"] == nil)
    }

    @Test
    func playURLPrefersDASHWhenDURLIsAlsoPresent() async throws {
        // DASH 优先级还必须防止未消费的漂移 durl 破坏旧路径。
        let response = try mutatedFixture("playurl") {
            $0["durl"] = [["unexpected": true]]
        }
        let client = BiliAPIClient(
            transport: StubTransport(responses: [response])
        )

        let playback = try await client.playback(
            for: "BV1FixtureA1",
            cid: 900_001
        )

        #expect(playback.dashManifest != nil)
    }

    @Test(arguments: [
        (ProgressiveShape.emptyDURL, ProgressiveMediaFailure.empty),
        (.twoSegments, .multipleSegments),
        (.malformedSecondSegment, .multipleSegments),
        (.zeroDuration, .invalidDuration),
        (.zeroSize, .invalidSize),
        (.loopbackOnly, .noSafeURL),
        (.missingURL, .noSafeURL),
        (.flvContainer, .unsupportedContainer)
    ])
    func playURLRejectsUnsupportedProgressiveShape(
        shape: ProgressiveShape,
        expected: ProgressiveMediaFailure
    ) async throws {
        let client = BiliAPIClient(
            transport: StubTransport(responses: [try shape.response()])
        )

        await #expect(throws: BiliAPIError.unsupportedProgressiveMedia(expected)) {
            try await client.playback(for: "BV1FixtureA1", cid: 900_001)
        }
    }

    @Test
    func playURLBindsLoudnessMetadataToEachSemanticTrackResponse() async throws {
        let originalVolume = loudnessVolume(measuredI: -20, measuredTP: -4)
        let aiVolume = loudnessVolume(measuredI: -11, measuredTP: -0.5)
        let transport = StubTransport(
            responses: [
                try semanticAudioResponse(
                    audioPath: "original-audio.m4s",
                    languageCatalog: [
                        "support": true,
                        "items": [
                            [
                                "lang": "en",
                                "title": "English（AI）",
                                "production_type": 2
                            ],
                            [
                                "lang": "ja",
                                "title": "日本語（AI）",
                                "production_type": 2
                            ]
                        ]
                    ],
                    volume: originalVolume
                ),
                try semanticAudioResponse(
                    audioPath: "ai-en-audio.m4s",
                    currentLanguage: "en",
                    currentProductionType: 2,
                    volume: aiVolume
                ),
                try semanticAudioResponse(
                    audioPath: "ai-ja-audio.m4s",
                    currentLanguage: "ja",
                    currentProductionType: 2
                )
            ]
        )
        let client = BiliAPIClient(
            transport: transport,
            requestAuthorizer: StubAuthorizer()
        )

        let playback = try await client.playback(
            for: "BV1FixtureA1",
            cid: 900_001
        )

        let manifest = try #require(playback.dashManifest)
        #expect(manifest.audioTracks.count == 3)
        let original = manifest.audioTracks[0]
        let englishAI = manifest.audioTracks[1]
        let japaneseAI = manifest.audioTracks[2]
        #expect(original.loudnessMetadata?.measuredIntegratedLUFS == -20)
        #expect(englishAI.loudnessMetadata?.measuredIntegratedLUFS == -11)
        #expect(japaneseAI.loudnessMetadata == nil)
        #expect(original.loudnessMetadata != englishAI.loudnessMetadata)
        let requests = transport.capturedRequests()
        #expect(
            requests.allSatisfy { request in
                URLComponents(
                    url: request.url,
                    resolvingAgainstBaseURL: false
                )?.queryItems?.contains(
                    URLQueryItem(name: "voice_balance", value: "1")
                ) == true
            }
        )
    }

    @Test(
        arguments: [
            (
                #"{"measured_i":-20,"measured_lra":3,"measured_tp":-4,"measured_threshold":-30,"target_i":-14,"target_tp":-1}"#,
                -20.0
            ),
            (
                #"{"measured_i":-20,"measured_lra":3,"measured_tp":-4,"measured_threshold":-30,"target_i":-14}"#,
                nil
            ),
            (
                #"{"measured_i":null,"measured_lra":3,"measured_tp":-4,"measured_threshold":-30,"target_i":-14,"target_tp":-1}"#,
                nil
            ),
            (
                #"{"measured_i":"bad","measured_lra":3,"measured_tp":-4,"measured_threshold":-30,"target_i":-14,"target_tp":-1}"#,
                nil
            ),
            (
                #"{"measured_i":-200,"measured_lra":3,"measured_tp":-4,"measured_threshold":-30,"target_i":-14,"target_tp":-1}"#,
                nil
            ),
            (
                #"{"measured_i":1e400,"measured_lra":3,"measured_tp":-4,"measured_threshold":-30,"target_i":-14,"target_tp":-1}"#,
                nil
            )
        ] as [(String, Double?)]
    )
    func loudnessPayloadRequiresACompleteFiniteBoundedGroup(
        _ source: String,
        expectedIntegratedLUFS: Double?
    ) {
        let payload = try? JSONDecoder().decode(
            PlaybackVolumePayload.self,
            from: Data(source.utf8)
        )

        #expect(payload?.model?.measuredIntegratedLUFS == expectedIntegratedLUFS)
    }

    @Test
    func authenticatedPlayURLMapsVerifiedAIAudioAsSemanticTrack() async throws {
        let transport = StubTransport(
            responses: [
                try semanticAudioResponse(
                    audioPath: "original-audio.m4s",
                    languageCatalog: machineGeneratedEnglishCatalog
                ),
                try semanticAudioResponse(
                    audioPath: "ai-en-audio.m4s",
                    currentLanguage: "en",
                    currentProductionType: 2
                )
            ]
        )
        let client = BiliAPIClient(
            transport: transport,
            requestAuthorizer: StubAuthorizer()
        )

        let playback = try await client.playback(
            for: "BV1FixtureA1",
            cid: 900_001
        )

        let manifest = try #require(playback.dashManifest)
        #expect(manifest.audioTracks.count == 2)
        let original = manifest.audioTracks[0]
        let ai = manifest.audioTracks[1]
        #expect(original.role == .original)
        #expect(original.isDefault)
        #expect(ai.id == "machine-generated:en")
        #expect(ai.displayName == "English（AI）")
        #expect(ai.languageTag == "en")
        #expect(ai.role == .machineGenerated)
        #expect(!ai.isDefault)
        #expect(ai.isAutoselect)
        #expect(ai.representations.map(\.id) == [30_280])
        let requests = transport.capturedRequests()
        #expect(requests.count == 2)
        #expect(
            URLComponents(
                url: requests[1].url,
                resolvingAgainstBaseURL: false
            )?.queryItems?.contains(
                URLQueryItem(name: "cur_language", value: "en")
            ) == true
        )
        #expect(playback.mediaHeaders["Cookie"] == nil)
    }

    @Test(arguments: [Int?.none, Int?.some(1)])
    func authenticatedPlayURLOmitsAIAudioWithoutMatchingResponseProductionType(
        currentProductionType: Int?
    ) async throws {
        let transport = StubTransport(
            responses: [
                try semanticAudioResponse(
                    audioPath: "original-audio.m4s",
                    languageCatalog: machineGeneratedEnglishCatalog
                ),
                try semanticAudioResponse(
                    audioPath: "ai-en-audio.m4s",
                    currentLanguage: "en",
                    currentProductionType: currentProductionType
                )
            ]
        )
        let client = BiliAPIClient(
            transport: transport,
            requestAuthorizer: StubAuthorizer()
        )

        let playback = try await client.playback(
            for: "BV1FixtureA1",
            cid: 900_001
        )

        #expect(playback.dashManifest?.audioTracks.map(\.role) == [.original])
        #expect(transport.capturedRequests().count == 2)
    }

    @Test(arguments: [true, false])
    func serverResumeMetadataIsKeptOnlyForAuthenticatedResponse(
        authenticated: Bool
    ) async throws {
        let response = try mutatedFixture("playurl") {
            $0["last_play_cid"] = 900_002
            $0["last_play_time"] = 42_500
        }
        let client = BiliAPIClient(
            transport: StubTransport(responses: [response]),
            requestAuthorizer: authenticated ? StubAuthorizer() : nil
        )

        let playback = try await client.playback(
            for: "BV1FixtureA1",
            cid: 900_001
        )

        let serverResume = PlaybackResumeMetadata(
            lastPlayedCID: 900_002,
            positionMilliseconds: 42_500
        )
        #expect(playback.resumeMetadata == (authenticated ? serverResume : nil))
    }

    @Test
    func anonymousFallbackDoesNotRequestAdvertisedAIAudio() async throws {
        let transport = StubTransport(
            responses: [
                try semanticAudioResponse(
                    audioPath: "original-audio.m4s",
                    languageCatalog: machineGeneratedEnglishCatalog
                )
            ]
        )
        let client = BiliAPIClient(
            transport: transport,
            requestAuthorizer: StubAuthorizer(.fail(.missingCredential))
        )

        let playback = try await client.playback(
            for: "BV1FixtureA1",
            cid: 900_001
        )

        #expect(playback.dashManifest?.audioTracks.count == 1)
        #expect(playback.dashManifest?.audioTracks[0].role == .original)
        #expect(transport.capturedRequests().count == 1)
    }

    @Test
    func anonymousFallbackProvenanceCannotAuthorizeAdvertisedAIAudio()
        async throws
    {
        let authorizer = StubAuthorizer(.fail(.missingCredential), .authorize)
        let transport = StubTransport(
            responses: [
                try semanticAudioResponse(
                    audioPath: "original-audio.m4s",
                    languageCatalog: machineGeneratedEnglishCatalog
                )
            ]
        )
        let client = BiliAPIClient(
            transport: transport,
            requestAuthorizer: authorizer
        )

        let playback = try await client.playback(
            for: "BV1FixtureA1",
            cid: 900_001
        )

        #expect(playback.dashManifest?.audioTracks.map(\.role) == [.original])
        #expect(await authorizer.authorizationCount == 1)
        #expect(transport.capturedRequests().count == 1)
    }

    @Test(
        arguments: [
            (HTTPResponse(statusCode: 403, body: Data()), BiliAPIError.httpStatus(403)),
            (HTTPResponse(statusCode: 412, body: Data()), .httpStatus(412)),
            (
                jsonResponse(#"{"code":-404,"message":"fixture"}"#),
                .apiRejected(code: -404, message: "fixture")
            ),
            (
                HTTPResponse(
                    statusCode: 200,
                    headers: ["Content-Type": "text/html"],
                    body: Data("fixture".utf8)
                ),
                .nonJSONResponse
            ),
            (nil, .transportFailure)
        ] as [(HTTPResponse?, BiliAPIError)]
    )
    func aiAudioFailureFailsWholePlaybackClosed(
        aiResponse: HTTPResponse?,
        expected: BiliAPIError
    ) async throws {
        let base = try semanticAudioResponse(
            audioPath: "original-audio.m4s",
            languageCatalog: machineGeneratedEnglishCatalog
        )
        let transport = StubTransport(responses: [base] + [aiResponse].compactMap { $0 })
        let client = BiliAPIClient(
            transport: transport,
            requestAuthorizer: StubAuthorizer()
        )

        await #expect(throws: expected) {
            try await client.playback(for: "BV1FixtureA1", cid: 900_001)
        }
        #expect(transport.capturedRequests().count == 2)
    }

    @Test
    func unsafeAIAudioTitleIsOmittedBeforeSecondRequest() async throws {
        let transport = StubTransport(
            responses: [
                try semanticAudioResponse(
                    audioPath: "original-audio.m4s",
                    languageCatalog: [
                        "support": true,
                        "items": [
                            [
                                "lang": "en",
                                "title": "English \"AI\"",
                                "production_type": 2
                            ]
                        ]
                    ]
                )
            ]
        )
        let client = BiliAPIClient(
            transport: transport,
            requestAuthorizer: StubAuthorizer()
        )

        let playback = try await client.playback(
            for: "BV1FixtureA1",
            cid: 900_001
        )

        #expect(playback.dashManifest?.audioTracks.count == 1)
        #expect(transport.capturedRequests().count == 1)
    }

    @Test(arguments: [
        (HTTPResponse(statusCode: 412, body: Data()), BiliAPIError.httpStatus(412)),
        (
            jsonResponse(#"{"code":-352,"message":"blocked"}"#),
            .apiRejected(code: -352, message: "blocked")
        ),
        (jsonResponse(#"{"code":-101,"message":"fixture"}"#), .authenticationInvalid)
    ])
    func authenticatedRejectionDoesNotRetryAnonymously(
        response: HTTPResponse,
        expected: BiliAPIError
    ) async {
        let transport = StubTransport(responses: [response])
        let client = BiliAPIClient(
            transport: transport,
            requestAuthorizer: StubAuthorizer()
        )

        await #expect(throws: expected) {
            try await client.playback(for: "BV1FixtureA1", cid: 900_001)
        }
        #expect(
            transport.capturedRequests().map { $0.headers["Cookie"] }
                == [StubAuthorizer.cookie]
        )
    }

    @Test(.timeLimit(.minutes(1)))
    func cancelledMissingCredentialResolutionDoesNotSendAnonymousFallback() async {
        let authorizer = StubAuthorizer(.fail(.missingCredential), suspendingCall: 1)
        let transport = StubTransport(responses: [])
        let client = BiliAPIClient(
            transport: transport,
            requestAuthorizer: authorizer
        )
        let playbackTask = Task {
            try await client.playback(for: "BV1FixtureA1", cid: 900_001)
        }
        await authorizer.waitUntilSuspended()

        playbackTask.cancel()
        await authorizer.resume()

        await #expect(throws: CancellationError.self) {
            try await playbackTask.value
        }
        #expect(transport.capturedRequests().isEmpty)
    }

    @Test(.timeLimit(.minutes(1)))
    func missingCredentialResolutionCannotCrossSessionInvalidationBoundary() async {
        let authorizer = StubAuthorizer(.fail(.missingCredential), suspendingCall: 1)
        let transport = StubTransport(responses: [])
        let client = BiliAPIClient(
            transport: transport,
            requestAuthorizer: authorizer
        )
        let playbackTask = Task {
            try await client.playback(for: "BV1FixtureA1", cid: 900_001)
        }
        await authorizer.waitUntilSuspended()

        await client.invalidateAuthenticatedSession()
        await authorizer.resume()

        await #expect(throws: CancellationError.self) {
            try await playbackTask.value
        }
        #expect(transport.capturedRequests().isEmpty)
    }

    @Test(.timeLimit(.minutes(1)))
    func authenticatedRequestCannotCrossSessionInvalidationBoundary() async throws {
        let authorizer = StubAuthorizer(suspendingCall: 1)
        let response = try fixtureResponse("playurl")
        let firstTransport = StubTransport(responses: [response])
        let replacementTransport = StubTransport(responses: [response])
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
        await authorizer.waitUntilSuspended()

        await client.invalidateAuthenticatedSession()
        await authorizer.resume()

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
        let firstTransport = StubTransport([.suspended(response)])
        let replacementTransport = StubTransport(responses: [response])
        let transportFactory = SequentialTransportFactory(
            transports: [firstTransport, replacementTransport]
        )
        let client = BiliAPIClient(
            requestAuthorizer: StubAuthorizer(),
            transportFactory: { transportFactory.makeTransport() }
        )

        let playbackTask = Task {
            try await client.playback(for: "BV1FixtureA1", cid: 900_001)
        }
        await firstTransport.waitForRequests(1)

        await client.invalidateAuthenticatedSession()
        firstTransport.resumeSuspendedRequest()

        await #expect(throws: CancellationError.self) {
            try await playbackTask.value
        }
        #expect(firstTransport.capturedRequests().count == 1)
        #expect(replacementTransport.capturedRequests().isEmpty)
        #expect(firstTransport.wasInvalidated)
    }

    @Test(.timeLimit(.minutes(1)))
    func authenticatedPlaybackEpochCannotChangeBetweenBaseAndAIAudio()
        async throws
    {
        let response = try semanticAudioResponse(
            audioPath: "original-audio.m4s",
            languageCatalog: machineGeneratedEnglishCatalog
        )
        let authorizer = StubAuthorizer(suspendingCall: 2)
        let firstTransport = StubTransport(responses: [response])
        let replacementTransport = StubTransport(responses: [response])
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
        await authorizer.waitUntilSuspended()

        await client.invalidateAuthenticatedSession()
        await authorizer.resume()

        await #expect(throws: CancellationError.self) {
            try await playbackTask.value
        }
        #expect(firstTransport.capturedRequests().count == 1)
        #expect(replacementTransport.capturedRequests().isEmpty)
        #expect(firstTransport.wasInvalidated)
    }

    @Test
    func playURLPreservesVideoWhenFrameRateCannotBeNormalized() async throws {
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
            transport: StubTransport(responses: [response])
        )

        let playback = try await client.playback(
            for: "BV1FixtureA1",
            cid: 900_001,
            quality: 32
        )

        let video = try #require(playback.dashManifest?.videoRepresentations.first)
        #expect(video.id == 32)
        #expect(video.videoAttributes?.frameRate == nil)
    }

    @Test
    func playURLRejectsRepresentationsWithoutTrustedMediaOrigin() async throws {
        let fixture = try fixtureResponse("playurl")
        let unsafeBody = String(decoding: fixture.body, as: UTF8.self)
            .replacingOccurrences(of: "media.fixture.bilivideo.com", with: "127.0.0.1")
            .replacingOccurrences(of: "backup.fixture.bilivideo.com", with: "localhost")
        let response = HTTPResponse(
            statusCode: fixture.statusCode,
            headers: fixture.headers,
            body: Data(unsafeBody.utf8)
        )
        let client = BiliAPIClient(
            transport: StubTransport(responses: [response])
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
    func historyMapsOnlyPlayableArchivesAndFollowsCursor() async throws {
        let transport = StubTransport(
            responses: [
                try fixtureResponse("history"),
                try fixtureResponse("history")
            ]
        )
        let client = BiliAPIClient(
            transport: transport,
            requestAuthorizer: StubAuthorizer()
        )

        let page = try await client.watchHistory(pageSize: 2)

        #expect(page.items.map(\.bvid) == ["BV1HistoryA1", "BV1HistoryB2"])
        #expect(page.items[0].title == "手写历史视频 '甲' <测试>")
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

        let requests = transport.capturedRequests()
        let request = try #require(requests.first)
        #expect(request.url.path == "/x/web-interface/history/cursor")
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
    }

    @Test
    func historyAcceptsDefaultAndMaximumPageSizeAndRejectsOutOfRangeBeforeTransport()
        async throws
    {
        let transport = StubTransport(
            responses: [
                try fixtureResponse("history"),
                try fixtureResponse("history")
            ]
        )
        let client = BiliAPIClient(
            transport: transport,
            requestAuthorizer: StubAuthorizer()
        )

        _ = try await client.watchHistory()
        _ = try await client.watchHistory(pageSize: 30)

        let validRequests = transport.capturedRequests()
        #expect(validRequests.count == 2)
        let defaultQuery = URLComponents(
            url: validRequests[0].url,
            resolvingAgainstBaseURL: false
        )?.queryItems
        let maximumQuery = URLComponents(
            url: validRequests[1].url,
            resolvingAgainstBaseURL: false
        )?.queryItems
        #expect(defaultQuery?.contains(URLQueryItem(name: "ps", value: "20")) == true)
        #expect(maximumQuery?.contains(URLQueryItem(name: "ps", value: "30")) == true)

        for pageSize in [31, 0, -1] {
            await #expect(throws: BiliAPIError.invalidRequest) {
                try await client.watchHistory(pageSize: pageSize)
            }
        }
        #expect(transport.capturedRequests().count == 2)
    }

    @Test
    func historyFailsClosedBeforeTransportWithoutAuthorizer() async {
        let transport = StubTransport(responses: [])
        let client = BiliAPIClient(transport: transport)

        await #expect(throws: BiliAPIError.authorizationRequired) {
            try await client.watchHistory(pageSize: 20)
        }
        #expect(transport.capturedRequests().isEmpty)
    }

    @Test
    func historyRejectsMalformedContinuationBeforeTransport() async {
        let transport = StubTransport(responses: [])
        let client = BiliAPIClient(
            transport: transport,
            requestAuthorizer: StubAuthorizer()
        )

        await #expect(throws: BiliAPIError.invalidRequest) {
            try await client.watchHistory(
                after: WatchHistoryContinuation(rawValue: "not-a-valid-token"),
                pageSize: 20
            )
        }
        #expect(transport.capturedRequests().isEmpty)
    }

    @Test
    func rejectsHTMLRiskControlPageBeforeDecoding() async {
        let response = HTTPResponse(
            statusCode: 200,
            headers: ["Content-Type": "text/html; charset=utf-8"],
            body: Data("<html>risk control</html>".utf8)
        )
        let client = BiliAPIClient(transport: StubTransport(responses: [response]))

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
        let client = BiliAPIClient(transport: StubTransport(responses: [response]))

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
        let client = BiliAPIClient(transport: StubTransport(responses: [response]))

        await #expect(throws: BiliAPIError.decodingFailed) {
            try await client.popular(page: 1, pageSize: 20)
        }
    }

    @Test
    func cancellationIsNotCollapsedIntoTransportFailure() async {
        let client = BiliAPIClient(transport: StubTransport([.cancellation]))

        await #expect(throws: CancellationError.self) {
            try await client.pages(for: "BV1FixtureA1")
        }
    }

    @Test
    func validatesInputBeforeSendingRequest() async {
        let transport = StubTransport(responses: [])
        let client = BiliAPIClient(transport: transport)

        await #expect(throws: BiliAPIError.invalidRequest) {
            try await client.pages(for: "not-a-bvid")
        }
        #expect(transport.capturedRequests().isEmpty)
    }

    private func search(
        _ client: BiliAPIClient,
        _ query: String = "macOS"
    ) async throws -> SearchPage {
        try await client.searchVideos(
            request: VideoSearchRequest(
                criteria: VideoSearchCriteria(query: query),
                page: 1
            )
        )
    }

    private var machineGeneratedEnglishCatalog: [String: Any] {
        [
            "support": true,
            "items": [
                [
                    "lang": "en",
                    "title": "English（AI）",
                    "production_type": 2
                ]
            ]
        ]
    }

    private func semanticAudioResponse(
        audioPath: String,
        languageCatalog: [String: Any]? = nil,
        currentLanguage: String? = nil,
        currentProductionType: Int? = nil,
        volume: [String: Any]? = nil
    ) throws -> HTTPResponse {
        var data: [String: Any] = [
            "dash": [
                "video": [
                    [
                        "id": 32,
                        "codecid": 7,
                        "codecs": "avc1.64001f",
                        "mime_type": "video/mp4",
                        "bandwidth": 500_000,
                        "width": 1_280,
                        "height": 720,
                        "frame_rate": "30",
                        "base_url": "https://media.fixture.bilivideo.com/video.m4s",
                        "backup_url": [],
                        "segment_base": [
                            "initialization": "0-99",
                            "index_range": "100-199"
                        ]
                    ]
                ],
                "audio": [
                    [
                        "id": 30_280,
                        "codecid": 0,
                        "codecs": "mp4a.40.2",
                        "mime_type": "audio/mp4",
                        "bandwidth": 192_000,
                        "base_url":
                            "https://media.fixture.bilivideo.com/\(audioPath)",
                        "backup_url": [],
                        "segment_base": [
                            "initialization": "0-99",
                            "index_range": "100-199"
                        ]
                    ]
                ]
            ]
        ]
        if let languageCatalog {
            data["language"] = languageCatalog
        }
        if let currentLanguage {
            data["cur_language"] = currentLanguage
        }
        if let currentProductionType {
            data["cur_production_type"] = currentProductionType
        }
        if let volume {
            data["volume"] = volume
        }
        return HTTPResponse(
            statusCode: 200,
            headers: ["Content-Type": "application/json"],
            body: try JSONSerialization.data(
                withJSONObject: ["code": 0, "data": data],
                options: [.sortedKeys]
            )
        )
    }

    private func loudnessVolume(
        measuredI: Double,
        measuredTP: Double
    ) -> [String: Any] {
        [
            "measured_i": measuredI,
            "measured_lra": 3,
            "measured_tp": measuredTP,
            "measured_threshold": measuredI - 10,
            "target_i": -14,
            "target_tp": -1,
            "target_offset": 99,
            "multi_scene_args": "ignored"
        ]
    }
}

/// 每个账户读取 endpoint 只授权自己的请求；WBI endpoint 前置的 nav 请求保持匿名。
struct AccountReadCase: Sendable, CustomTestStringConvertible {
    static let recommendationBody = #"""
        {"code":0,"data":{"item":[
          {"goto":"av","bvid":"BV1FixtureA1","title":"推荐 &amp; 视频","pic":"//i0.hdslb.com/a.jpg","owner":{"mid":10001,"name":"作者","face":"//i1.hdslb.com/a.jpg"},"stat":{"view":12345,"danmaku":67,"like":8},"duration":125,"pubdate":1700000000,"rcmd_reason":{"content":"正在流行"}},
          {"goto":"live","bvid":"BV1FixtureB2","title":"直播","owner":{"mid":2,"name":"主播"},"stat":{"view":1,"danmaku":0,"like":0},"duration":0,"pubdate":1700000000},
          {"goto":"av","bvid":"BV1FixtureC3","title":"广告","owner":{"mid":3,"name":"广告主"},"stat":{"view":1,"danmaku":0,"like":0},"duration":10,"pubdate":1700000000,"business_info":{}}
        ]}}
        """#

    static let all: [AccountReadCase] = [
        AccountReadCase(
            path: "/x/web-interface/wbi/index/top/feed/rcmd",
            responses: {
                [try fixtureResponse("nav"), jsonResponse(AccountReadCase.recommendationBody)]
            },
            call: { _ = try await $0.recommendations() }
        ),
        AccountReadCase(
            path: "/x/web-interface/wbi/search/type",
            responses: { [try fixtureResponse("nav"), try fixtureResponse("search")] },
            call: {
                _ = try await $0.searchVideos(
                    request: VideoSearchRequest(
                        criteria: VideoSearchCriteria(query: "macOS"),
                        page: 1
                    )
                )
            }
        ),
        AccountReadCase(
            path: "/x/v2/dm/wbi/web/seg.so",
            responses: {
                [try fixtureResponse("nav"), try hexFixtureResponse("danmaku-segment-minimal")]
            },
            call: {
                _ = try await $0.danmakuSegmentData(
                    index: 1,
                    for: PlaybackItemIdentity(bvid: "BV1FixtureA1", cid: 900_001)
                )
            }
        ),
        AccountReadCase(
            path: "/x/web-interface/popular",
            responses: { [try fixtureResponse("popular")] },
            call: { _ = try await $0.popular(page: 1, pageSize: 20) }
        ),
        AccountReadCase(
            path: "/x/web-interface/view",
            responses: { [try fixtureResponse("view")] },
            call: { _ = try await $0.videoDetail(for: "BV1FixtureA1") }
        ),
        AccountReadCase(
            path: "/x/player/pagelist",
            responses: { [try fixtureResponse("pagelist")] },
            call: { _ = try await $0.pages(for: "BV1FixtureA1") }
        ),
        AccountReadCase(
            path: "/x/web-interface/archive/related",
            responses: { [try fixtureResponse("related")] },
            call: { _ = try await $0.relatedVideos(to: "BV1FixtureA1") }
        ),
        AccountReadCase(
            path: "/x/web-interface/card",
            responses: { [try fixtureResponse("uploader-card")] },
            call: { _ = try await $0.uploaderSignature(for: 10_001) }
        ),
        AccountReadCase(
            path: "/x/player/playurl",
            responses: { [try fixtureResponse("playurl")] },
            call: { _ = try await $0.playback(for: "BV1FixtureA1", cid: 900_001) }
        ),
        AccountReadCase(
            path: "/x/web-interface/history/cursor",
            responses: { [try fixtureResponse("history")] },
            call: { _ = try await $0.watchHistory(pageSize: 20) }
        )
    ]

    let path: String
    let responses: @Sendable () throws -> [HTTPResponse]
    let call: @Sendable (BiliAPIClient) async throws -> Void

    var testDescription: String { path }
}

/// playurl 只返回 durl 时的各种形状；只有单段、安全来源、mp4 可以映射为 progressive 媒体。
enum ProgressiveShape: Sendable {
    case singleSafeSegment
    case emptyDURL
    case twoSegments
    case malformedSecondSegment
    case zeroDuration
    case zeroSize
    case loopbackOnly
    case missingURL
    case flvContainer

    func response() throws -> HTTPResponse {
        let backup = "https://backup.fixture.bilivideo.com/preview.mp4"
        func segment(
            path: String = "preview.mp4",
            length: Int64 = 884_983,
            size: Int64 = 50_000_000,
            url: String? = nil,
            backupURLs: [String] = [backup]
        ) -> [String: Any] {
            [
                "length": length,
                "size": size,
                "url": url ?? "https://media.fixture.bilivideo.com/\(path)",
                "backup_url": backupURLs
            ]
        }
        let durl: [[String: Any]] =
            switch self {
            case .singleSafeSegment, .flvContainer: [segment()]
            case .emptyDURL: []
            case .twoSegments: [segment(), segment(path: "part-2.mp4")]
            case .malformedSecondSegment: [segment(), ["unexpected": true]]
            case .zeroDuration: [segment(length: 0)]
            case .zeroSize: [segment(size: 0)]
            case .loopbackOnly: [segment(url: "http://127.0.0.1/media.mp4", backupURLs: [])]
            case .missingURL: [["length": 884_983, "size": 50_000_000, "backup_url": []]]
            }
        return HTTPResponse(
            statusCode: 200,
            headers: ["Content-Type": "application/json"],
            body: try JSONSerialization.data(
                withJSONObject: [
                    "code": 0,
                    "message": "OK",
                    "data": ["durl": durl, "format": self == .flvContainer ? "flv" : "mp4"]
                ]
            )
        )
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
