import BiliApplication
import BiliModels
import BiliNetworking
import Foundation
import Testing

@testable import BiliAPI

/// 固定相关推荐契约：解码推荐架所需字段，缺少可交互字段时整页解码失败。
struct BiliAPIClientRelatedVideoTests {
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
        let response = jsonResponse(
            #"{"code":0,"data":[{"bvid":"BV1RelatedA1","title":"","owner":{"name":"作者"},"stat":{"view":1,"danmaku":2}}]}"#
        )
        let client = BiliAPIClient(
            transport: StubTransport(responses: [response])
        )

        await #expect(throws: BiliAPIError.decodingFailed) {
            try await client.relatedVideos(to: "BV1FixtureA1")
        }
    }
}
