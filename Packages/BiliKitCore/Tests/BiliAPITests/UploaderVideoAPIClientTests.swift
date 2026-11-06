import BiliApplication
import BiliModels
import BiliNetworking
import Foundation
import Testing

@testable import BiliAPI

/// 固定 UP 主投稿契约：App 端游标接口经 App 授权器签名（未登录也能读），排序只映射最新与最多播放；下一批游标是本批最后
/// 一条的 `param`，只在 `has_next` 时给出，游标形状不对时不发请求；只收 BVID、标题与发布时间齐全的普通稿件，隐藏的统计
/// 不当作 0，单条损坏只丢这一条。
struct UploaderVideoAPIClientTests {
    @Test
    func batchMapsFieldsAndDropsUnsupportedEntries() async throws {
        let client = BiliAPIClient(
            transport: StubTransport(responses: [try fixtureResponse("uploader-videos")]),
            appRequestAuthorizer: StubAppAuthorizer()
        )

        let batch = try await client.uploaderVideos(ownerID: 10_001, order: .newest, after: nil)

        #expect(batch.videos.map(\.bvid) == ["BV1FixtureA1", "BV1FixtureB2"])
        #expect(batch.totalCount == 61)
        // 游标取本批最后一条的 `param`，即使那一条本身被丢弃，下一批也不会重复它之前的条目。
        #expect(batch.nextCursor == UploaderVideoCursor(value: "900005"))

        let first = batch.videos[0]
        #expect(first.title == "投稿 & 一")
        #expect(first.coverURL?.absoluteString == "https://images.example.invalid/a.jpg")
        #expect(first.durationSeconds == 754)
        #expect(first.viewCount == 12_345)
        #expect(first.danmakuCount == 678)
        #expect(first.publishedAt == Date(timeIntervalSince1970: 1_720_000_000))
        #expect(!first.isCollaboration)

        let second = batch.videos[1]
        #expect(second.coverURL?.absoluteString == "https://images.example.invalid/b.jpg")
        #expect(second.viewCount == nil)
        #expect(second.danmakuCount == nil)
        #expect(second.isCollaboration)
    }

    @Test(arguments: [
        (UploaderVideoOrder.newest, "pubdate"),
        (.mostPlayed, "click")
    ])
    func requestIsASignedAppReadWithTheCursor(
        order: UploaderVideoOrder,
        apiValue: String
    ) async throws {
        let transport = StubTransport(responses: [try fixtureResponse("uploader-videos")])
        let authorizer = StubAppAuthorizer(carriesCredential: false)
        let client = BiliAPIClient(transport: transport, appRequestAuthorizer: authorizer)

        _ = try await client.uploaderVideos(
            ownerID: 10_001,
            order: order,
            after: UploaderVideoCursor(value: "900005")
        )

        let request = try #require(await authorizer.requests.first)
        #expect(request.url.host == "app.bilibili.com")
        #expect(request.url.path == "/x/v2/space/archive/cursor")
        #expect(
            queryFields(request) == [
                "vmid": "10001", "ps": "20", "order": apiValue, "aid": "900005"
            ]
        )
        #expect(request.headers["Referer"] == nil)
        #expect(transport.capturedRequests().count == 1)
    }

    /// 到底时没有下一批；`item` 缺失按空批处理。
    @Test(arguments: [
        #"{"code":0,"data":{"count":2,"has_next":false,"item":[{"goto":"av","param":"1","bvid":"BV1FixtureA1","title":"a","ctime":1700000000}]}}"#,
        #"{"code":0,"data":{"count":2,"has_next":false}}"#
    ])
    func lastBatchHasNoCursor(body: String) async throws {
        let client = BiliAPIClient(
            transport: StubTransport(responses: [jsonResponse(body)]),
            appRequestAuthorizer: StubAppAuthorizer()
        )

        let batch = try await client.uploaderVideos(ownerID: 10_001, order: .newest, after: nil)

        #expect(batch.nextCursor == nil)
        #expect(batch.totalCount == 2)
    }

    /// 非法 MID 或游标不是十进制数字（会被原样拼进 query）时不发请求。
    @Test(
        arguments: [
            (0, nil),
            (10_001, "1&ps=100"),
            (10_001, ""),
            (10_001, String(repeating: "9", count: 21))
        ] as [(Int64, String?)]
    )
    func invalidRequestSendsNothing(ownerID: Int64, cursor: String?) async throws {
        let transport = StubTransport(responses: [])
        let client = BiliAPIClient(transport: transport, appRequestAuthorizer: StubAppAuthorizer())

        await #expect(throws: BiliAPIError.invalidRequest) {
            try await client.uploaderVideos(
                ownerID: ownerID,
                order: .newest,
                after: cursor.map(UploaderVideoCursor.init(value:))
            )
        }
        #expect(transport.capturedRequests().isEmpty)
    }
}
