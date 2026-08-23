import BiliApplication
import BiliModels
import BiliNetworking
import Foundation
import Testing

@testable import BiliAPI

struct BiliAPIClientTests {
    @Test
    func recommendationsUseWBIAccountReadAndFilterUnsupportedCards() async throws {
        let response = jsonResponse(
            #"""
            {"code":0,"data":{"item":[
              {"goto":"av","bvid":"BV1FixtureA1","title":"推荐 &amp; 视频","pic":"//i0.hdslb.com/a.jpg","owner":{"mid":10001,"name":"作者","face":"//i1.hdslb.com/a.jpg"},"stat":{"view":12345,"danmaku":67,"like":8},"duration":125,"pubdate":1700000000,"rcmd_reason":{"content":"正在流行"}},
              {"goto":"live","bvid":"BV1FixtureB2","title":"直播","owner":{"mid":2,"name":"主播"},"stat":{"view":1,"danmaku":0,"like":0},"duration":0,"pubdate":1700000000},
              {"goto":"av","bvid":"BV1FixtureC3","title":"广告","owner":{"mid":3,"name":"广告主"},"stat":{"view":1,"danmaku":0,"like":0},"duration":10,"pubdate":1700000000,"business_info":{}}
            ]}}
            """#
        )
        let transport = RecordingTransport(
            responses: [try fixtureResponse("nav"), response]
        )
        let authorizer = RecordingRequestAuthorizer()
        let client = BiliAPIClient(
            transport: transport,
            requestAuthorizer: authorizer,
            timestampProvider: { 1_700_000_000 }
        )

        let page = try await client.recommendations()

        #expect(page.videos.map(\.bvid) == ["BV1FixtureA1"])
        #expect(page.videos.first?.title == "推荐 & 视频")
        #expect(page.videos.first?.recommendationReason == "正在流行")
        #expect(page.continuation == RecommendationContinuation(freshIndex: 1))
        #expect(page.nextContinuation == RecommendationContinuation(freshIndex: 2))

        let requests = await transport.capturedRequests()
        #expect(
            requests.map(\.url.path) == [
                "/x/web-interface/nav",
                "/x/web-interface/wbi/index/top/feed/rcmd",
            ]
        )
        #expect(requests[0].headers["Cookie"] == nil)
        #expect(requests[1].headers["Cookie"] == "FIXTURE_AUTHORIZED")
        #expect(requests[1].headers["Referer"] == "https://www.bilibili.com/")
        let query = URLComponents(
            url: requests[1].url,
            resolvingAgainstBaseURL: false
        )?.queryItems
        #expect(query?.first(where: { $0.name == "fresh_idx" })?.value == "1")
        #expect(query?.first(where: { $0.name == "fresh_idx_1h" })?.value == "1")
        #expect(query?.first(where: { $0.name == "wts" })?.value == "1700000000")
        #expect(query?.first(where: { $0.name == "w_rid" })?.value?.count == 32)
        #expect(
            await authorizer.capturedPaths()
                == ["/x/web-interface/wbi/index/top/feed/rcmd"]
        )
    }

    @Test
    func popularDecodesSanitizedContractAndBuildsGuestRequest() async throws {
        let transport = RecordingTransport(responses: [try fixtureResponse("popular")])
        let client = BiliAPIClient(transport: transport)

        let page = try await client.popular(page: 2, pageSize: 10)

        #expect(page.pageNumber == 2)
        #expect(page.pageSize == 10)
        #expect(page.hasMore)
        #expect(page.videos.count == 2)
        #expect(page.videos[0].bvid == "BV1FixtureA1")
        #expect(page.videos[0].title == "合成热门样本 'A' <测试>")
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

        #expect(detail.aid == 700_001)
        #expect(detail.bvid == "BV1FixtureA1")
        #expect(detail.title == "合成视频详情 A")
        #expect(detail.summary == "这是手写的脱敏详情说明。")
        #expect(detail.owner.id == 10_001)
        #expect(detail.statistics.likeCount == 3_456)
        #expect(detail.dimension == VideoDimension(width: 1920, height: 1080, rotation: 0))
        #expect(detail.pages.map(\.cid) == [900_001])

        let request = try #require(await transport.capturedRequests().first)
        #expect(request.url.path == "/x/web-interface/view")
        #expect(request.headers["Referer"] == "https://www.bilibili.com/video/BV1FixtureA1/")
    }

    @Test
    func videoDetailPreservesCurrentPagesAndNestedUGCCollection() async throws {
        let response = jsonResponse(
            #"""
            {"code":0,"data":{"aid":7001,"bvid":"BV1FixtureA1","title":"当前视频","desc":"说明","pic":"https://images.example.invalid/current.jpg","owner":{"mid":10001,"name":"作者"},"stat":{"view":1,"danmaku":2,"like":3},"duration":300,"pubdate":1720000000,"pages":[{"cid":900001,"page":1,"part":"当前 P1","duration":120},{"cid":900002,"page":2,"part":"当前 P2","duration":180}],"ugc_season":{"id":501,"title":"测试合集","ep_count":3,"sections":[{"season_id":501,"id":601,"title":"第一章","episodes":[{"season_id":501,"section_id":601,"id":701,"aid":7001,"bvid":"BV1FixtureA1","cid":900001,"title":"当前视频","arc":{"aid":7001,"bvid":"BV1FixtureA1","title":"当前视频","pic":"https://images.example.invalid/current.jpg","duration":300},"pages":[{"cid":900001,"page":1,"part":"当前 P1","duration":120},{"cid":900002,"page":2,"part":"当前 P2","duration":180}]},{"season_id":501,"section_id":601,"id":702,"aid":7002,"bvid":"BV1FixtureB2","cid":910001,"title":"下一视频","arc":{"duration":200},"page":{"cid":910001,"page":1,"part":"默认 P","duration":200}}]},{"season_id":501,"id":602,"title":"第二章","episodes":[{"season_id":501,"section_id":602,"id":703,"aid":7003,"bvid":"BV1FixtureC3","cid":920001,"title":"第三视频","arc":{"duration":100}}]}]}}}
            """#
        )
        let client = BiliAPIClient(
            transport: RecordingTransport(responses: [response])
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
            transport: RecordingTransport(responses: [response])
        )

        let collection = try #require(
            try await client.videoDetail(for: "BV1FixtureA1").collection
        )

        #expect(collection.sections.isEmpty)
        #expect(collection.reportedEpisodeCount == 20)
        #expect(collection.embeddedCountMatchesReportedCount == false)
    }

    @Test
    func videoDetailRejectsDuplicatePageIdentity() async {
        let response = jsonResponse(
            #"{"code":0,"data":{"bvid":"BV1FixtureA1","title":"当前视频","desc":"说明","pic":"","owner":{"mid":10001,"name":"作者"},"stat":{"view":1,"danmaku":2,"like":3},"duration":120,"pubdate":1720000000,"pages":[{"cid":900001,"page":1,"part":"P1","duration":60},{"cid":900001,"page":2,"part":"P2","duration":60}]}}"#
        )
        let client = BiliAPIClient(
            transport: RecordingTransport(responses: [response])
        )

        await #expect(throws: BiliAPIError.decodingFailed) {
            try await client.videoDetail(for: "BV1FixtureA1")
        }
    }

    @Test
    func malformedCollectionEpisodeDoesNotBlockCurrentVideo() async throws {
        let response = jsonResponse(
            #"{"code":0,"data":{"bvid":"BV1FixtureA1","title":"当前视频","desc":"说明","pic":"","owner":{"mid":10001,"name":"作者"},"stat":{"view":1,"danmaku":2,"like":3},"duration":120,"pubdate":1720000000,"pages":[{"cid":900001,"page":1,"part":"P1","duration":120}],"ugc_season":{"id":501,"title":"合集","ep_count":1,"sections":[{"season_id":501,"id":601,"title":"分部","episodes":[{"season_id":999,"section_id":601,"id":701,"aid":7001,"bvid":"BV1FixtureB2","cid":910001,"title":"","arc":{"aid":7002,"bvid":"BV1FixtureC3","duration":100},"page":{"cid":910002,"page":1,"part":"P1","duration":100}}]}]}}}"#
        )
        let client = BiliAPIClient(
            transport: RecordingTransport(responses: [response])
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
            transport: RecordingTransport(responses: [response])
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
            transport: RecordingTransport(responses: [response])
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
            transport: RecordingTransport(responses: [response])
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
            transport: RecordingTransport(responses: [
                response(order: "[\(firstEpisode),\(secondEpisode)]"),
                response(order: "[\(secondEpisode),\(firstEpisode)]"),
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
            transport: RecordingTransport(responses: [response])
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
    func pagelistRejectsDuplicateIdentity() async {
        let response = jsonResponse(
            #"{"code":0,"data":[{"cid":900001,"page":1,"part":"P1","duration":60},{"cid":900001,"page":2,"part":"P2","duration":60}]}"#
        )
        let client = BiliAPIClient(
            transport: RecordingTransport(responses: [response])
        )

        await #expect(throws: BiliAPIError.decodingFailed) {
            try await client.pages(for: "BV1FixtureA1")
        }
    }

    @Test
    func relatedVideosUseAccountReadAndDecodeShelfFields() async throws {
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
        #expect(videos[0].title == "合成相关推荐 'A' <测试>")
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
        #expect(request.headers["Cookie"] == "FIXTURE_AUTHORIZED")
        #expect(
            await authorizer.capturedPaths()
                == ["/x/web-interface/archive/related"]
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
    func uploaderSignatureUsesExactAccountReadCardEndpoint() async throws {
        let transport = RecordingTransport(
            responses: [try fixtureResponse("uploader-card")]
        )
        let authorizer = RecordingRequestAuthorizer()
        let client = BiliAPIClient(
            transport: transport,
            requestAuthorizer: authorizer
        )

        let signature = try await client.uploaderSignature(for: 10_001)

        #expect(signature == "用影像记录生活")
        let request = try #require(await transport.capturedRequests().first)
        #expect(request.method == .get)
        #expect(request.url.scheme == "https")
        #expect(request.url.host == "api.bilibili.com")
        #expect(request.url.port == nil)
        #expect(request.url.path == "/x/web-interface/card")
        #expect(
            URLComponents(url: request.url, resolvingAgainstBaseURL: false)?
                .queryItems == [
                    URLQueryItem(name: "mid", value: "10001"),
                    URLQueryItem(name: "photo", value: "false"),
                ]
        )
        #expect(request.headers["Cookie"] == "FIXTURE_AUTHORIZED")
        #expect(request.headers["Authorization"] == nil)
        #expect(await authorizer.capturedPaths() == ["/x/web-interface/card"])
    }

    @Test
    func uploaderSignatureAcceptsNumericMID() async throws {
        let response = jsonResponse(
            #"{"code":0,"data":{"card":{"mid":10001,"sign":"签名"}}}"#
        )
        let client = BiliAPIClient(
            transport: RecordingTransport(responses: [response])
        )

        #expect(try await client.uploaderSignature(for: 10_001) == "签名")
    }

    @Test
    func uploaderSignatureRejectsMismatchedMID() async {
        let response = jsonResponse(
            #"{"code":0,"data":{"card":{"mid":"10002","sign":"签名"}}}"#
        )
        let client = BiliAPIClient(
            transport: RecordingTransport(responses: [response])
        )

        await #expect(throws: BiliAPIError.decodingFailed) {
            try await client.uploaderSignature(for: 10_001)
        }
    }

    @Test
    func uploaderSignaturePreservesBlankValueForApplicationNormalization()
        async throws
    {
        let response = jsonResponse(
            #"{"code":0,"data":{"card":{"mid":"10001","sign":"  \n "}}}"#
        )
        let client = BiliAPIClient(
            transport: RecordingTransport(responses: [response])
        )

        #expect(try await client.uploaderSignature(for: 10_001) == "  \n ")
    }

    @Test(arguments: [302, 307])
    func uploaderSignatureRejectsRedirectResponse(statusCode: Int) async {
        let client = BiliAPIClient(
            transport: RecordingTransport(
                responses: [HTTPResponse(statusCode: statusCode, body: Data())]
            )
        )

        await #expect(throws: BiliAPIError.httpStatus(statusCode)) {
            try await client.uploaderSignature(for: 10_001)
        }
    }

    @Test
    func uploaderSignatureRejectsBusinessFailure() async {
        let client = BiliAPIClient(
            transport: RecordingTransport(
                responses: [jsonResponse(#"{"code":-352,"message":"blocked"}"#)]
            )
        )

        await #expect(
            throws: BiliAPIError.apiRejected(code: -352, message: "blocked")
        ) {
            try await client.uploaderSignature(for: 10_001)
        }
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
        #expect(page.videos[0].title == "学习macOS 'A' <测试>")
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
    func searchEncodesAllTypedCriteriaAndFixedPagination() async throws {
        let searchResponse = try fixtureResponse("search")
        let transport = RecordingTransport(
            responses: [try fixtureResponse("nav")]
                + Array(repeating: searchResponse, count: 11)
        )
        let client = BiliAPIClient(
            transport: transport,
            timestampProvider: { 1_700_000_000 }
        )

        for order in VideoSearchOrder.allCases {
            _ = try await client.searchVideos(
                request: VideoSearchRequest(
                    criteria: VideoSearchCriteria(query: "macOS", order: order),
                    page: 1
                )
            )
        }
        for duration in VideoDurationFilter.allCases {
            _ = try await client.searchVideos(
                request: VideoSearchRequest(
                    criteria: VideoSearchCriteria(query: "macOS", duration: duration),
                    page: 1
                )
            )
        }
        _ = try await client.searchVideos(
            request: VideoSearchRequest(
                criteria: VideoSearchCriteria(
                    query: "macOS",
                    publicationRange: VideoPublicationTimeRange(
                        beginTimestamp: 1_700_000_000,
                        endTimestamp: 1_700_086_399
                    )
                ),
                page: 2
            )
        )

        let searchRequests = await transport.capturedRequests().dropFirst()
        #expect(searchRequests.count == 11)
        let queries = searchRequests.map { request in
            Dictionary(
                uniqueKeysWithValues: (URLComponents(
                    url: request.url,
                    resolvingAgainstBaseURL: false
                )?.queryItems ?? []).compactMap { item in
                    item.value.map { (item.name, $0) }
                }
            )
        }
        #expect(
            queries.prefix(5).map { $0["order"] } == [
                "totalrank", "click", "pubdate", "dm", "stow",
            ]
        )
        #expect(
            queries.dropFirst(5).prefix(5).map { $0["duration"] } == [
                "0", "1", "2", "3", "4",
            ]
        )
        #expect(queries.allSatisfy { $0["search_type"] == "video" })
        #expect(queries.allSatisfy { $0["page_size"] == "20" })
        #expect(queries.last?["page"] == "2")
        #expect(queries.last?["pubtime_begin_s"] == "1700000000")
        #expect(queries.last?["pubtime_end_s"] == "1700086399")
        #expect(queries.allSatisfy { $0["wts"] == "1700000000" })
        #expect(queries.allSatisfy { $0["w_rid"]?.count == 32 })
    }

    @Test
    func searchUsesAccountReadWhileWBIKeyStaysAnonymous() async throws {
        let authorizer = RecordingRequestAuthorizer()
        let transport = RecordingTransport(
            responses: [
                try fixtureResponse("nav"),
                try fixtureResponse("search"),
            ]
        )
        let client = BiliAPIClient(
            transport: transport,
            requestAuthorizer: authorizer,
            timestampProvider: { 1_700_000_000 }
        )

        _ = try await client.searchVideos(keyword: "macOS", page: 1)

        let requests = await transport.capturedRequests()
        #expect(requests[0].url.path == "/x/web-interface/nav")
        #expect(requests[0].headers["Cookie"] == nil)
        #expect(requests[1].url.path == "/x/web-interface/wbi/search/type")
        #expect(requests[1].headers["Cookie"] == "FIXTURE_AUTHORIZED")
        #expect(
            await authorizer.capturedPaths() == [
                "/x/web-interface/wbi/search/type"
            ]
        )
    }

    @Test
    func searchFallsBackAnonymouslyOnlyForMissingCredential() async throws {
        let transport = RecordingTransport(
            responses: [
                try fixtureResponse("nav"),
                try fixtureResponse("search"),
            ]
        )
        let client = BiliAPIClient(
            transport: transport,
            requestAuthorizer: ThrowingRequestAuthorizer(kind: .missingCredential),
            timestampProvider: { 1_700_000_000 }
        )

        _ = try await client.searchVideos(keyword: "macOS", page: 1)

        let requests = await transport.capturedRequests()
        #expect(requests.count == 2)
        #expect(requests.allSatisfy { $0.headers["Cookie"] == nil })
    }

    @Test(arguments: [
        HTTPRequestAuthorizationFailureKind.invalidCredential,
        .unavailable,
        .denied,
    ])
    func searchFailsClosedForCredentialFailure(
        kind: HTTPRequestAuthorizationFailureKind
    ) async throws {
        let transport = RecordingTransport(responses: [try fixtureResponse("nav")])
        let client = BiliAPIClient(
            transport: transport,
            requestAuthorizer: ThrowingRequestAuthorizer(kind: kind),
            timestampProvider: { 1_700_000_000 }
        )

        if kind == .invalidCredential {
            await #expect(throws: BiliAPIError.authenticationInvalid) {
                try await client.searchVideos(keyword: "macOS", page: 1)
            }
        } else {
            await #expect(throws: BiliAPIError.authorizationUnavailable) {
                try await client.searchVideos(keyword: "macOS", page: 1)
            }
        }
        #expect(
            await transport.capturedRequests().map(\.url.path) == [
                "/x/web-interface/nav"
            ]
        )
    }

    @Test(.timeLimit(.minutes(1)))
    func searchCannotCrossAuthenticationEpoch() async throws {
        let authorizer = SuspendingRequestAuthorizer()
        let transport = RecordingTransport(responses: [try fixtureResponse("nav")])
        let client = BiliAPIClient(
            transport: transport,
            requestAuthorizer: authorizer,
            timestampProvider: { 1_700_000_000 }
        )
        let task = Task {
            try await client.searchVideos(keyword: "macOS", page: 1)
        }
        await authorizer.waitUntilAuthorizationStarts()

        await client.invalidateAuthenticatedSession()
        await authorizer.resumeAuthorization()

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
        #expect(
            await transport.capturedRequests().map(\.url.path) == [
                "/x/web-interface/nav"
            ]
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
        let authorizer = RecordingRequestAuthorizer()
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
            requestAuthorizer: authorizer,
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
        let searchRequests = await transport.capturedRequests().filter {
            $0.url.path == "/x/web-interface/wbi/search/type"
        }
        #expect(
            searchRequests.allSatisfy {
                $0.headers["Cookie"] == "FIXTURE_AUTHORIZED"
            }
        )
    }

    @Test
    func searchRiskResponseDoesNotRetryAnonymously() async throws {
        let authorizer = RecordingRequestAuthorizer()
        let transport = RecordingTransport(
            responses: [
                try fixtureResponse("nav"),
                HTTPResponse(statusCode: 412, body: Data()),
            ]
        )
        let client = BiliAPIClient(
            transport: transport,
            requestAuthorizer: authorizer,
            timestampProvider: { 1_700_000_000 }
        )

        await #expect(throws: BiliAPIError.httpStatus(412)) {
            try await client.searchVideos(keyword: "macOS", page: 1)
        }
        let requests = await transport.capturedRequests()
        #expect(requests.count == 2)
        #expect(requests[1].headers["Cookie"] == "FIXTURE_AUTHORIZED")
    }

    @Test
    func searchBusinessRiskDoesNotRetryAnonymously() async throws {
        let authorizer = RecordingRequestAuthorizer()
        let transport = RecordingTransport(
            responses: [
                try fixtureResponse("nav"),
                jsonResponse(#"{"code":-352,"message":"blocked"}"#),
            ]
        )
        let client = BiliAPIClient(
            transport: transport,
            requestAuthorizer: authorizer,
            timestampProvider: { 1_700_000_000 }
        )

        await #expect(
            throws: BiliAPIError.apiRejected(code: -352, message: "blocked")
        ) {
            try await client.searchVideos(keyword: "macOS", page: 1)
        }
        let requests = await transport.capturedRequests()
        #expect(requests.count == 2)
        #expect(requests[1].headers["Cookie"] == "FIXTURE_AUTHORIZED")
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
        let audioTrack = try #require(playback.manifest.audioTracks.first)
        let audio = try #require(audioTrack.representations.first)
        #expect(playback.manifest.videoRepresentations.count == 1)
        #expect(playback.manifest.audioTracks.count == 1)
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
        #expect(
            queryItems?.contains(
                URLQueryItem(name: "voice_balance", value: "1")
            ) == true
        )
    }

    @Test
    func playURLBindsLoudnessMetadataToEachSemanticTrackResponse() async throws {
        let originalVolume = loudnessVolume(measuredI: -20, measuredTP: -4)
        let aiVolume = loudnessVolume(measuredI: -11, measuredTP: -0.5)
        let transport = RecordingTransport(
            responses: [
                try semanticAudioResponse(
                    audioPath: "original-audio.m4s",
                    languageCatalog: [
                        "support": true,
                        "items": [
                            [
                                "lang": "en",
                                "title": "English（AI）",
                                "production_type": 2,
                            ],
                            [
                                "lang": "ja",
                                "title": "日本語（AI）",
                                "production_type": 2,
                            ],
                        ],
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
                ),
            ]
        )
        let client = BiliAPIClient(
            transport: transport,
            requestAuthorizer: RecordingRequestAuthorizer()
        )

        let playback = try await client.playback(
            for: "BV1FixtureA1",
            cid: 900_001
        )

        #expect(playback.manifest.audioTracks.count == 3)
        let original = playback.manifest.audioTracks[0]
        let englishAI = playback.manifest.audioTracks[1]
        let japaneseAI = playback.manifest.audioTracks[2]
        #expect(original.loudnessMetadata?.measuredIntegratedLUFS == -20)
        #expect(englishAI.loudnessMetadata?.measuredIntegratedLUFS == -11)
        #expect(japaneseAI.loudnessMetadata == nil)
        #expect(original.loudnessMetadata != englishAI.loudnessMetadata)
        let requests = await transport.capturedRequests()
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

    @Test(arguments: [
        #"{"measured_i":-20,"measured_lra":3,"measured_tp":-4,"measured_threshold":-30,"target_i":-14,"target_tp":-1}"#,
        #"{"measured_i":-20,"measured_lra":3,"measured_tp":-4,"measured_threshold":-30,"target_i":-14}"#,
        #"{"measured_i":null,"measured_lra":3,"measured_tp":-4,"measured_threshold":-30,"target_i":-14,"target_tp":-1}"#,
        #"{"measured_i":"bad","measured_lra":3,"measured_tp":-4,"measured_threshold":-30,"target_i":-14,"target_tp":-1}"#,
        #"{"measured_i":-200,"measured_lra":3,"measured_tp":-4,"measured_threshold":-30,"target_i":-14,"target_tp":-1}"#,
        #"{"measured_i":1e400,"measured_lra":3,"measured_tp":-4,"measured_threshold":-30,"target_i":-14,"target_tp":-1}"#,
    ])
    func loudnessPayloadRequiresACompleteFiniteBoundedGroup(_ source: String) {
        let payload = try? JSONDecoder().decode(
            PlaybackVolumePayload.self,
            from: Data(source.utf8)
        )

        if source.hasPrefix(#"{"measured_i":-20,"#)
            && source.contains(#""target_tp":-1"#)
        {
            #expect(payload?.model?.measuredIntegratedLUFS == -20)
        } else {
            #expect(payload?.model == nil)
        }
    }

    @Test
    func authenticatedPlayURLMapsVerifiedAIAudioAsSemanticTrack() async throws {
        let transport = RecordingTransport(
            responses: [
                try semanticAudioResponse(
                    audioPath: "original-audio.m4s",
                    languageCatalog: [
                        "support": true,
                        "items": [
                            [
                                "lang": "en",
                                "title": "English（AI）",
                                "production_type": 2,
                            ]
                        ],
                    ]
                ),
                try semanticAudioResponse(
                    audioPath: "ai-en-audio.m4s",
                    currentLanguage: "en",
                    currentProductionType: 2
                ),
            ]
        )
        let client = BiliAPIClient(
            transport: transport,
            requestAuthorizer: RecordingRequestAuthorizer()
        )

        let playback = try await client.playback(
            for: "BV1FixtureA1",
            cid: 900_001
        )

        #expect(playback.manifest.audioTracks.count == 2)
        let original = playback.manifest.audioTracks[0]
        let ai = playback.manifest.audioTracks[1]
        #expect(original.role == .original)
        #expect(original.isDefault)
        #expect(ai.id == "machine-generated:en")
        #expect(ai.displayName == "English（AI）")
        #expect(ai.languageTag == "en")
        #expect(ai.role == .machineGenerated)
        #expect(!ai.isDefault)
        #expect(ai.isAutoselect)
        #expect(ai.representations.map(\.id) == [30_280])
        let requests = await transport.capturedRequests()
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
        let transport = RecordingTransport(
            responses: [
                try semanticAudioResponse(
                    audioPath: "original-audio.m4s",
                    languageCatalog: machineGeneratedEnglishCatalog
                ),
                try semanticAudioResponse(
                    audioPath: "ai-en-audio.m4s",
                    currentLanguage: "en",
                    currentProductionType: currentProductionType
                ),
            ]
        )
        let client = BiliAPIClient(
            transport: transport,
            requestAuthorizer: RecordingRequestAuthorizer()
        )

        let playback = try await client.playback(
            for: "BV1FixtureA1",
            cid: 900_001
        )

        #expect(playback.manifest.audioTracks.map(\.role) == [.original])
        #expect(await transport.capturedRequests().count == 2)
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
    func authenticatedPlaybackMapsServerResumeMetadata() async throws {
        let client = BiliAPIClient(
            transport: RecordingTransport(
                responses: [try resumePlayURLResponse()]
            ),
            requestAuthorizer: RecordingRequestAuthorizer()
        )

        let playback = try await client.playback(
            for: "BV1FixtureA1",
            cid: 900_001
        )

        #expect(
            playback.resumeMetadata
                == PlaybackResumeMetadata(
                    lastPlayedCID: 900_002,
                    positionMilliseconds: 42_500
                )
        )
    }

    @Test
    func anonymousPlaybackDropsServerResumeMetadata() async throws {
        let client = BiliAPIClient(
            transport: RecordingTransport(
                responses: [try resumePlayURLResponse()]
            )
        )

        let playback = try await client.playback(
            for: "BV1FixtureA1",
            cid: 900_001
        )

        #expect(playback.resumeMetadata == nil)
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

    @Test
    func anonymousFallbackDoesNotRequestAdvertisedAIAudio() async throws {
        let transport = RecordingTransport(
            responses: [
                try semanticAudioResponse(
                    audioPath: "original-audio.m4s",
                    languageCatalog: [
                        "support": true,
                        "items": [
                            [
                                "lang": "en",
                                "title": "English（AI）",
                                "production_type": 2,
                            ]
                        ],
                    ]
                )
            ]
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

        #expect(playback.manifest.audioTracks.count == 1)
        #expect(playback.manifest.audioTracks[0].role == .original)
        #expect(await transport.capturedRequests().count == 1)
    }

    @Test
    func anonymousFallbackProvenanceCannotAuthorizeAdvertisedAIAudio()
        async throws
    {
        let authorizer = MissingThenAuthorizedRequestAuthorizer()
        let transport = RecordingTransport(
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

        #expect(playback.manifest.audioTracks.map(\.role) == [.original])
        #expect(await authorizer.authorizationCount() == 1)
        #expect(await transport.capturedRequests().count == 1)
    }

    @Test(arguments: [403, 412])
    func aiAudioRemoteRestrictionFailsClosed(statusCode: Int) async throws {
        let transport = RecordingTransport(
            responses: [
                try semanticAudioResponse(
                    audioPath: "original-audio.m4s",
                    languageCatalog: machineGeneratedEnglishCatalog
                ),
                HTTPResponse(statusCode: statusCode, body: Data()),
            ]
        )
        let client = BiliAPIClient(
            transport: transport,
            requestAuthorizer: RecordingRequestAuthorizer()
        )

        await #expect(throws: BiliAPIError.httpStatus(statusCode)) {
            try await client.playback(for: "BV1FixtureA1", cid: 900_001)
        }
        #expect(await transport.capturedRequests().count == 2)
    }

    @Test
    func aiAudioBusinessRejectionFailsClosed() async throws {
        let transport = RecordingTransport(
            responses: [
                try semanticAudioResponse(
                    audioPath: "original-audio.m4s",
                    languageCatalog: machineGeneratedEnglishCatalog
                ),
                jsonResponse(#"{"code":-404,"message":"fixture"}"#),
            ]
        )
        let client = BiliAPIClient(
            transport: transport,
            requestAuthorizer: RecordingRequestAuthorizer()
        )

        await #expect(
            throws: BiliAPIError.apiRejected(
                code: -404,
                message: "fixture"
            )
        ) {
            try await client.playback(for: "BV1FixtureA1", cid: 900_001)
        }
        #expect(await transport.capturedRequests().count == 2)
    }

    @Test
    func aiAudioNonJSONResponseFailsClosed() async throws {
        let transport = RecordingTransport(
            responses: [
                try semanticAudioResponse(
                    audioPath: "original-audio.m4s",
                    languageCatalog: machineGeneratedEnglishCatalog
                ),
                HTTPResponse(
                    statusCode: 200,
                    headers: ["Content-Type": "text/html"],
                    body: Data("fixture".utf8)
                ),
            ]
        )
        let client = BiliAPIClient(
            transport: transport,
            requestAuthorizer: RecordingRequestAuthorizer()
        )

        await #expect(throws: BiliAPIError.nonJSONResponse) {
            try await client.playback(for: "BV1FixtureA1", cid: 900_001)
        }
        #expect(await transport.capturedRequests().count == 2)
    }

    @Test
    func aiAudioTransportFailureFailsClosed() async throws {
        let transport = RecordingTransport(
            responses: [
                try semanticAudioResponse(
                    audioPath: "original-audio.m4s",
                    languageCatalog: machineGeneratedEnglishCatalog
                )
            ]
        )
        let client = BiliAPIClient(
            transport: transport,
            requestAuthorizer: RecordingRequestAuthorizer()
        )

        await #expect(throws: BiliAPIError.transportFailure) {
            try await client.playback(for: "BV1FixtureA1", cid: 900_001)
        }
        #expect(await transport.capturedRequests().count == 2)
    }

    @Test
    func unsafeAIAudioTitleIsOmittedBeforeSecondRequest() async throws {
        let transport = RecordingTransport(
            responses: [
                try semanticAudioResponse(
                    audioPath: "original-audio.m4s",
                    languageCatalog: [
                        "support": true,
                        "items": [
                            [
                                "lang": "en",
                                "title": "English \"AI\"",
                                "production_type": 2,
                            ]
                        ],
                    ]
                )
            ]
        )
        let client = BiliAPIClient(
            transport: transport,
            requestAuthorizer: RecordingRequestAuthorizer()
        )

        let playback = try await client.playback(
            for: "BV1FixtureA1",
            cid: 900_001
        )

        #expect(playback.manifest.audioTracks.count == 1)
        #expect(await transport.capturedRequests().count == 1)
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

    @Test(.timeLimit(.minutes(1)))
    func authenticatedPlaybackEpochCannotChangeBetweenBaseAndAIAudio()
        async throws
    {
        let response = try semanticAudioResponse(
            audioPath: "original-audio.m4s",
            languageCatalog: machineGeneratedEnglishCatalog
        )
        let authorizer = SuspendingSecondRequestAuthorizer()
        let firstTransport = RecordingInvalidatingAPITransport(
            response: response
        )
        let replacementTransport = RecordingInvalidatingAPITransport(
            response: response
        )
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
        await authorizer.waitUntilSecondAuthorizationStarts()

        await client.invalidateAuthenticatedSession()
        await authorizer.resumeSecondAuthorization()

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
            transport: RecordingTransport(responses: [response])
        )

        let playback = try await client.playback(
            for: "BV1FixtureA1",
            cid: 900_001,
            quality: 32
        )

        let video = try #require(playback.manifest.videoRepresentations.first)
        #expect(video.id == 32)
        #expect(video.videoAttributes?.frameRate == nil)
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
    func popularVideoDetailAndPageListUseAccountRead()
        async throws
    {
        let authorizer = RecordingRequestAuthorizer()
        let client = BiliAPIClient(
            transport: RecordingTransport(
                responses: [
                    try fixtureResponse("popular"),
                    try fixtureResponse("view"),
                    try fixtureResponse("pagelist"),
                ]
            ),
            requestAuthorizer: authorizer
        )

        _ = try await client.popular(page: 1, pageSize: 20)
        _ = try await client.videoDetail(for: "BV1FixtureA1")
        _ = try await client.pages(for: "BV1FixtureA1")

        #expect(
            await authorizer.capturedPaths()
                == [
                    "/x/web-interface/popular",
                    "/x/web-interface/view",
                    "/x/player/pagelist",
                ]
        )
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

    private func resumePlayURLResponse() throws -> HTTPResponse {
        let fixture = try fixtureResponse("playurl")
        var object = try #require(
            JSONSerialization.jsonObject(with: fixture.body)
                as? [String: Any]
        )
        var data = try #require(object["data"] as? [String: Any])
        data["last_play_cid"] = 900_002
        data["last_play_time"] = 42_500
        object["data"] = data
        return HTTPResponse(
            statusCode: fixture.statusCode,
            headers: fixture.headers,
            body: try JSONSerialization.data(
                withJSONObject: object,
                options: [.sortedKeys]
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
                    "production_type": 2,
                ]
            ],
        ]
    }

    private func jsonResponse(_ source: String) -> HTTPResponse {
        HTTPResponse(
            statusCode: 200,
            headers: ["Content-Type": "application/json"],
            body: Data(source.utf8)
        )
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
                        "base_url": "https://media.example.invalid/video.m4s",
                        "backup_url": [],
                        "segment_base": [
                            "initialization": "0-99",
                            "index_range": "100-199",
                        ],
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
                            "https://media.example.invalid/\(audioPath)",
                        "backup_url": [],
                        "segment_base": [
                            "initialization": "0-99",
                            "index_range": "100-199",
                        ],
                    ]
                ],
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
            "multi_scene_args": "ignored",
        ]
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

private actor MissingThenAuthorizedRequestAuthorizer: HTTPRequestAuthorizing {
    private var count = 0

    func authorize(_ request: HTTPRequest) throws -> HTTPRequest {
        count += 1
        if count == 1 {
            throw FixtureAuthorizationFailure(kind: .missingCredential)
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

    func authorizationCount() -> Int {
        count
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

private actor SuspendingSecondRequestAuthorizer: HTTPRequestAuthorizing {
    private var authorizationCount = 0
    private var secondAuthorizationStarted = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var authorizationContinuation: CheckedContinuation<Void, Never>?

    func authorize(_ request: HTTPRequest) async -> HTTPRequest {
        authorizationCount += 1
        if authorizationCount == 2 {
            secondAuthorizationStarted = true
            for waiter in startWaiters {
                waiter.resume()
            }
            startWaiters.removeAll()
            await withCheckedContinuation { continuation in
                authorizationContinuation = continuation
            }
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

    func waitUntilSecondAuthorizationStarts() async {
        guard !secondAuthorizationStarted else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func resumeSecondAuthorization() {
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
