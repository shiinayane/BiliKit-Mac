import BiliApplication
import BiliModels
import BiliNetworking
import Foundation
import Testing

@testable import BiliAPI

/// 固定稍后再看契约：WBI 签名的账户读取，默认条件与每个排序、筛选、关键词到参数的映射（未启用的筛选不传），
/// 丢弃没有可用 BVID 的占位行，番剧／影视、课程与失效三类判为不可用，按总条数推出下一页并带回总条数，响应不属于
/// 所请求的页时整页失败。
struct BiliAPIClientWatchLaterTests {
    @Test
    func requestIsSignedAccountReadWithFixedParameters() async throws {
        let transport = StubTransport(
            responses: [try fixtureResponse("watchlater")],
            answersWBINavOnce: true
        )
        let client = BiliAPIClient(
            transport: transport,
            requestAuthorizer: StubAuthorizer(),
            timestampProvider: { 1_700_000_000 }
        )

        _ = try await client.watchLater(request: WatchLaterRequest(page: 1))

        let requests = transport.businessRequests()
        #expect(requests.map(\.url.path) == ["/x/v2/history/toview/web"])
        let request = try #require(requests.first)
        #expect(request.headers["Referer"] == "https://www.bilibili.com/watchlater/")
        let query = Dictionary(
            uniqueKeysWithValues: (URLComponents(url: request.url, resolvingAgainstBaseURL: false)?
                .queryItems ?? []).map { ($0.name, $0.value ?? "") }
        )
        #expect(query["need_split"] == nil)
        #expect(query["wts"] == "1700000000")
        #expect(query["w_rid"]?.count == 32)
    }

    /// 每个条件单独映射到自己的参数；未启用的加入时间与时长两侧不传。
    @Test(arguments: [
        (WatchLaterCriteria(order: .oldestAdded), ["asc": "1"]),
        (WatchLaterCriteria(progress: .unfinished), ["viewed": "2"]),
        (WatchLaterCriteria(keyword: "  猫 咪 "), ["key": "猫 咪"]),
        (
            WatchLaterCriteria(
                addedTime: WatchLaterAddedTimeRange(
                    startTimestamp: 1_700_000_000,
                    endTimestamp: 1_700_086_400
                )
            ),
            ["add_time_start": "1700000000", "add_time_end": "1700086400"]
        ),
        (WatchLaterCriteria(duration: .underTenMinutes), ["arc_max_duration": "600"]),
        (
            WatchLaterCriteria(duration: .tenToThirtyMinutes),
            ["arc_min_duration": "600", "arc_max_duration": "1800"]
        ),
        (
            WatchLaterCriteria(duration: .thirtyToSixtyMinutes),
            ["arc_min_duration": "1800", "arc_max_duration": "3600"]
        ),
        (WatchLaterCriteria(duration: .overSixtyMinutes), ["arc_min_duration": "3600"])
    ])
    func criteriaMapToTheirOwnParameters(
        criteria: WatchLaterCriteria,
        expected: [String: String]
    ) async throws {
        let query = try await Self.query(for: WatchLaterRequest(criteria: criteria, page: 2))
        let defaults = [
            "pn": "2", "ps": "20", "viewed": "0", "key": "", "asc": "0", "web_location": "333.881"
        ]
        let filterNames: Set = [
            "add_time_start", "add_time_end", "arc_min_duration", "arc_max_duration"
        ]

        for (name, value) in defaults where expected[name] == nil {
            #expect(query[name] == value)
        }
        for (name, value) in expected {
            #expect(query[name] == value)
        }
        for name in filterNames where expected[name] == nil {
            #expect(query[name] == nil)
        }
    }

    @Test
    func combinedCriteriaSendEveryParameter() async throws {
        let query = try await Self.query(
            for: WatchLaterRequest(
                criteria: WatchLaterCriteria(
                    order: .oldestAdded,
                    progress: .unfinished,
                    addedTime: WatchLaterAddedTimeRange(startTimestamp: 10, endTimestamp: 20),
                    duration: .thirtyToSixtyMinutes,
                    keyword: "macOS"
                )
            )
        )

        #expect(query["asc"] == "1")
        #expect(query["viewed"] == "2")
        #expect(query["key"] == "macOS")
        #expect(query["add_time_start"] == "10")
        #expect(query["add_time_end"] == "20")
        #expect(query["arc_min_duration"] == "1800")
        #expect(query["arc_max_duration"] == "3600")
    }

    /// 关键词过长或加入时间倒置时不发请求。
    @Test(arguments: [
        WatchLaterCriteria(keyword: String(repeating: "长", count: 101)),
        WatchLaterCriteria(
            addedTime: WatchLaterAddedTimeRange(startTimestamp: 20, endTimestamp: 20)
        )
    ])
    func invalidCriteriaSendNothing(criteria: WatchLaterCriteria) async {
        let transport = StubTransport(responses: [])
        let client = BiliAPIClient(transport: transport, requestAuthorizer: StubAuthorizer())

        await #expect(throws: BiliAPIError.invalidRequest) {
            try await client.watchLater(request: WatchLaterRequest(criteria: criteria))
        }
        #expect(transport.capturedRequests().isEmpty)
    }

    @Test
    func pageMapsItemsAndDropsPlaceholderRows() async throws {
        let client = BiliAPIClient(
            transport: StubTransport(
                responses: [try fixtureResponse("watchlater")],
                answersWBINavOnce: true
            ),
            requestAuthorizer: StubAuthorizer(),
            timestampProvider: { 1_700_000_000 }
        )

        let page = try await client.watchLater(request: WatchLaterRequest(page: 1))

        #expect(page.totalCount == 23)
        #expect(
            page.items.map(\.bvid) == [
                "BV1LaterA1", "BV1LaterB2", "BV1LaterC3", "BV1LaterD4", "BV1LaterE5", "BV1LaterF6",
                "BV1LaterH8", "BV1LaterI9", "BV1LaterG7"
            ]
        )
        let first = page.items[0]
        #expect(first.title == "稍后 & 再看 一")
        #expect(first.coverURL?.absoluteString == "https://images.example.invalid/a.jpg")
        #expect(
            first.owner
                == VideoOwner(
                    id: 20_001,
                    name: "作者甲",
                    avatarURL: URL(string: "https://images.example.invalid/face-a.jpg")
                )
        )
        #expect(first.durationSeconds == 300)
        #expect(first.progress == .watched(seconds: 125))
        #expect(first.addedAt == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(first.unavailability == nil)
        #expect(page.items[1].progress == .finished)
        #expect(page.items[1].owner?.avatarURL == nil)
        #expect(page.items[2].progress == .notStarted)
        #expect(
            page.items.map(\.unavailability) == [
                nil, nil, .pgc(label: "番剧"), .pgc(label: "电影"), .course, .invalid, .invalid,
                .course, nil
            ]
        )
        // 不可用行字段不全时留空，不让整页失败：标题为空、owner 为 null、add_at 为 0 的失效行，作者名为空、
        // 缺时长与加入时间的课程行。
        let invalid = page.items[6]
        #expect(invalid.title == nil)
        #expect(invalid.owner == nil)
        #expect(invalid.addedAt == nil)
        #expect(invalid.durationSeconds == nil)
        let course = page.items[7]
        #expect(course.title == "缺作者的课程")
        #expect(course.owner == nil)
        #expect(course.addedAt == nil)
        #expect(course.durationSeconds == nil)
    }

    /// 有下一页的条件是本页有条目且已请求的条数少于总条数；`list` 为 null 时是空页。
    ///
    /// 本页有条目而总条数不多于
    /// 前面各页时按最后一页接受，不判失败。
    @Test(arguments: [
        (1, 23, 3, Int?.some(2)),
        (2, 23, 3, nil),
        (1, 20, 20, nil),
        (1, 0, 0, nil),
        (2, 20, 3, nil),
        (3, 5, 2, nil)
    ])
    func nextPageFollowsTheTotalCount(
        page: Int,
        count: Int,
        rows: Int,
        expectedNextPage: Int?
    ) async throws {
        let client = BiliAPIClient(
            transport: StubTransport(
                responses: [jsonResponse(Self.body(count: count, rows: rows))],
                answersWBINavOnce: true
            ),
            requestAuthorizer: StubAuthorizer(),
            timestampProvider: { 1_700_000_000 }
        )

        let result = try await client.watchLater(request: WatchLaterRequest(page: page))

        #expect(result.pageNumber == page)
        #expect(result.items.count == rows)
        #expect(result.nextPageNumber == expectedNextPage)
    }

    @Test
    func nullListIsAnEmptyLastPage() async throws {
        let client = BiliAPIClient(
            transport: StubTransport(
                responses: [jsonResponse(#"{"code":0,"data":{"count":0,"list":null}}"#)],
                answersWBINavOnce: true
            ),
            requestAuthorizer: StubAuthorizer(),
            timestampProvider: { 1_700_000_000 }
        )

        let page = try await client.watchLater(request: WatchLaterRequest(page: 1))

        #expect(page.items.isEmpty)
        #expect(page.nextPageNumber == nil)
    }

    /// 条数超过每页条数或总条数为负，说明响应不属于所请求的页。
    @Test(arguments: [(1, 30, 21), (1, -1, 0), (2, -1, 3)])
    func responseOutsideTheRequestedPageFails(page: Int, count: Int, rows: Int) async throws {
        let client = BiliAPIClient(
            transport: StubTransport(
                responses: [jsonResponse(Self.body(count: count, rows: rows))],
                answersWBINavOnce: true
            ),
            requestAuthorizer: StubAuthorizer(),
            timestampProvider: { 1_700_000_000 }
        )

        await #expect(throws: BiliAPIError.decodingFailed) {
            try await client.watchLater(request: WatchLaterRequest(page: page))
        }
    }

    /// 可播放的条目缺标题、作者或加入时间时整页失败，不悄悄显示残缺卡片（不可用条目放宽，见上）。
    @Test
    func malformedVideoRowFailsThePage() async throws {
        let body = #"""
            {"code":0,"data":{"count":1,"list":[{"aid":1,"bvid":"BV1LaterA1","title":"","pic":"","duration":10,"owner":{"mid":1,"name":"作者"},"progress":0,"add_at":1700000000,"state":0}]}}
            """#
        let client = BiliAPIClient(
            transport: StubTransport(responses: [jsonResponse(body)], answersWBINavOnce: true),
            requestAuthorizer: StubAuthorizer(),
            timestampProvider: { 1_700_000_000 }
        )

        await #expect(throws: BiliAPIError.decodingFailed) {
            try await client.watchLater(request: WatchLaterRequest(page: 1))
        }
    }

    /// 进度 `-1` 是已看完，正数截到时长以内，其余按没看过。
    @Test(arguments: [
        (-1, 100, WatchLaterProgress.finished),
        (40, 100, .watched(seconds: 40)),
        (130, 100, .watched(seconds: 100)),
        (0, 100, .notStarted),
        (-2, 100, .notStarted)
    ])
    func progressMapsTheFinishedSentinel(
        progress: Int,
        duration: Int,
        expected: WatchLaterProgress
    ) throws {
        let row = try JSONDecoder().decode(
            WatchLaterItemPayload.self,
            from: Data(
                #"{"aid":1,"bvid":"BV1LaterA1","title":"标题","duration":\#(duration),"owner":{"mid":1,"name":"作者"},"progress":\#(progress),"add_at":1700000000,"state":0}"#
                    .utf8
            )
        )

        #expect(try row.model()?.progress == expected)
    }

    @Test(arguments: [0, -1])
    func nonPositivePageSendsNothing(page: Int) async {
        let transport = StubTransport(responses: [])
        let client = BiliAPIClient(transport: transport, requestAuthorizer: StubAuthorizer())

        await #expect(throws: BiliAPIError.invalidRequest) {
            try await client.watchLater(request: WatchLaterRequest(page: page))
        }
        #expect(transport.capturedRequests().isEmpty)
    }

    /// 以默认 fixture 响应发出 `request`，返回业务请求的 query。
    private static func query(for request: WatchLaterRequest) async throws -> [String: String] {
        let transport = StubTransport(
            responses: [jsonResponse(Self.body(count: 0, rows: 0))],
            answersWBINavOnce: true
        )
        let client = BiliAPIClient(
            transport: transport,
            requestAuthorizer: StubAuthorizer(),
            timestampProvider: { 1_700_000_000 }
        )
        _ = try await client.watchLater(request: request)
        let url = try #require(transport.businessRequests().first?.url)
        return Dictionary(
            uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems ?? []).map { ($0.name, $0.value ?? "") }
        )
    }

    /// 一页 `rows` 条可播放的手写条目，总条数为 `count`。
    private static func body(count: Int, rows: Int) -> String {
        let list = (0..<rows).map { index in
            #"{"aid":\#(index + 1),"bvid":"BV1Later\#(index)","title":"条目 \#(index)","pic":"","duration":60,"owner":{"mid":1,"name":"作者"},"progress":0,"add_at":1700000000,"state":0}"#
        }
        return #"{"code":0,"data":{"count":\#(count),"list":[\#(list.joined(separator: ","))]}}"#
    }
}

/// 稍后再看 adapter 经内容域映射失败（共用映射的分类见 BiliContentRepositoryTests）：
/// 本地无凭据时不发出业务请求，总条数为负是无效响应。
@Suite(.timeLimit(.minutes(1)))
struct BiliWatchLaterRepositoryTests {
    @Test
    func missingCredentialFailsWithoutBusinessRequest() async {
        let transport = StubTransport(responses: [], answersWBINavOnce: true)
        let repository = BiliWatchLaterRepository(
            client: BiliAPIClient(
                transport: transport,
                requestAuthorizer: StubAuthorizer(.fail(.missingCredential))
            )
        )

        await #expect(throws: ContentApplicationError.authenticationRequired) {
            try await repository.watchLater(request: WatchLaterRequest(page: 1))
        }
        #expect(transport.businessRequests().isEmpty)
    }

    @Test
    func negativeCountIsAnInvalidResponse() async {
        let body = #"""
            {"code":0,"data":{"count":-1,"list":[{"aid":1,"bvid":"BV1LaterA1","title":"标题","pic":"","duration":10,"owner":{"mid":1,"name":"作者"},"progress":0,"add_at":1700000000,"state":0}]}}
            """#
        let repository = BiliWatchLaterRepository(
            client: BiliAPIClient(
                transport: StubTransport(responses: [jsonResponse(body)], answersWBINavOnce: true),
                requestAuthorizer: StubAuthorizer()
            )
        )

        await #expect(throws: ContentApplicationError.invalidResponse) {
            try await repository.watchLater(request: WatchLaterRequest(page: 2))
        }
    }
}
