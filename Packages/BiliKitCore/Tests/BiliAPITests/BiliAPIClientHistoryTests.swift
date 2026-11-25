import BiliApplication
import BiliModels
import BiliNetworking
import Foundation
import Testing

@testable import BiliAPI

/// 固定观看历史契约：只映射可播放的稿件并沿游标翻页，设备按 `dt` 区分，上次看到第一个分 P 时带出它的 CID，
/// 页大小越界、游标损坏或没有授权器时在发请求前失败。
struct BiliAPIClientHistoryTests {
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
        #expect(page.items.map(\.device) == [.phone, .web])
        // 历史的 CID 是上次看到的那一 P，只在那一 P 是第一个分 P 时作为提示。
        #expect(page.items.map(\.firstPageCID) == [900_201, nil])
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

    /// 历史的观看设备按 `dt` 区分；缺失、未知取值或形状不对时没有设备，不影响整条历史。
    @Test(arguments: [
        (#","dt":3"#, WatchHistoryDevice?.some(.phone)),
        (#","dt":6"#, .pad),
        (#","dt":"2""#, .web),
        (#","dt":33"#, .tv),
        (#","dt":0"#, nil),
        (#","dt":true"#, nil),
        ("", nil)
    ])
    func historyDeviceComesFromTheDeviceType(field: String, expected: WatchHistoryDevice?) throws {
        let payload = try JSONDecoder().decode(
            WatchHistoryIdentityPayload.self,
            from: Data(#"{"bvid":"BV1HistoryA1","business":"archive"\#(field)}"#.utf8)
        )

        #expect(payload.device == expected)
    }

    @Test
    func historyAcceptsMinimumAndMaximumPageSizeAndRejectsOutOfRangeBeforeTransport()
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

        _ = try await client.watchHistory(pageSize: 1)
        _ = try await client.watchHistory(pageSize: 30)

        let validRequests = transport.capturedRequests()
        #expect(validRequests.count == 2)
        let minimumQuery = URLComponents(
            url: validRequests[0].url,
            resolvingAgainstBaseURL: false
        )?.queryItems
        let maximumQuery = URLComponents(
            url: validRequests[1].url,
            resolvingAgainstBaseURL: false
        )?.queryItems
        #expect(minimumQuery?.contains(URLQueryItem(name: "ps", value: "1")) == true)
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
}
