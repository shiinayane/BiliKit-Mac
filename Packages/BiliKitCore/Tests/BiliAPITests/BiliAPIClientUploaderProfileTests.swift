import BiliApplication
import BiliModels
import BiliNetworking
import Foundation
import Testing

@testable import BiliAPI

/// 固定 UP 主名片契约：只请求 `/x/web-interface/card`，MID 必须与请求一致，
/// 大会员、名字、头像、粉丝数与投稿数异常时按缺省处理而签名照常返回；观看者关注状态只采用带凭据读到的。
struct BiliAPIClientUploaderProfileTests {
    @Test
    func uploaderCardUsesExactCardEndpoint() async throws {
        let transport = StubTransport(
            responses: [try fixtureResponse("uploader-card")]
        )
        let client = BiliAPIClient(transport: transport)

        let profile = try await client.uploaderCard(for: 10_001).profile

        #expect(
            profile
                == UploaderProfile(
                    name: "虚构作者",
                    avatarURL: URL(string: "https://image.example.invalid/avatar.jpg"),
                    signature: "用影像记录生活",
                    isVIP: true,
                    followerCount: 123_456,
                    videoCount: 78
                )
        )
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

    /// 粉丝数与投稿数只是展示：缺失、为负或形状不对时按缺省，签名照常返回。
    @Test(arguments: [#""follower":-1,"archive_count":"many""#, #""follower":null"#])
    func uploaderProfileTreatsMalformedCountsAsMissing(counts: String) async throws {
        let response = jsonResponse(
            #"{"code":0,"data":{"card":{"mid":10001,"sign":"签名"},"# + counts + "}}"
        )
        let client = BiliAPIClient(transport: StubTransport(responses: [response]))

        #expect(
            try await client.uploaderCard(for: 10_001).profile == UploaderProfile(signature: "签名")
        )
    }

    /// 大会员只是名字颜色的增强：过期或字段异常都按非大会员处理，签名照常返回。
    @Test(
        arguments: [
            #"{"vipType":2,"vipStatus":0}"#,
            #"{"vipStatus":"1"}"#,
            #""invalid""#
        ]
    )
    func uploaderProfileTreatsInactiveOrMalformedVIPAsRegular(vip: String) async throws {
        let response = jsonResponse(
            #"{"code":0,"data":{"card":{"mid":"10001","sign":"签名","vip":"#
                + vip + "}}}"
        )
        let client = BiliAPIClient(
            transport: StubTransport(responses: [response])
        )

        #expect(
            try await client.uploaderCard(for: 10_001).profile
                == UploaderProfile(signature: "签名", isVIP: false)
        )
    }

    /// 名字与头像只用于补齐只凭 MID 打开的空间：字段异常或头像不是 HTTPS 时按缺省处理，签名照常返回。
    @Test(
        arguments: [
            #""name":42,"face":["x"]"#,
            #""name":"作者","face":"ftp://example.invalid/a.jpg""#
        ]
    )
    func uploaderProfileTreatsMalformedNameAndFaceAsAbsent(fields: String) async throws {
        let response = jsonResponse(
            #"{"code":0,"data":{"card":{"mid":"10001","sign":"签名","#
                + fields + "}}}"
        )
        let client = BiliAPIClient(
            transport: StubTransport(responses: [response])
        )

        let profile = try await client.uploaderCard(for: 10_001).profile

        #expect(profile.signature == "签名")
        #expect(profile.avatarURL == nil)
    }

    /// 观看者关注状态属于发出读取的账户：带凭据读到的 `following` 采用；匿名回退（本地没有凭据）时响应里即使带了也按
    /// 未知，不当成“未关注”或“已关注”。
    @Test(arguments: [true, false])
    func uploaderCardTakesFollowingOnlyFromAnAuthenticatedRead(authenticated: Bool) async throws {
        let response = jsonResponse(
            #"{"code":0,"data":{"card":{"mid":"10001","sign":"签名"},"following":true}}"#
        )
        let client = BiliAPIClient(
            transport: StubTransport(responses: [response]),
            requestAuthorizer: StubAuthorizer(
                authenticated ? .authorize : .fail(.missingCredential)
            )
        )

        let card = try await client.uploaderCard(for: 10_001)

        #expect(card.viewerFollows == (authenticated ? true : nil))
    }

    @Test
    func uploaderProfileRejectsMismatchedMID() async {
        let response = jsonResponse(
            #"{"code":0,"data":{"card":{"mid":"10002","sign":"签名"}}}"#
        )
        let client = BiliAPIClient(
            transport: StubTransport(responses: [response])
        )

        await #expect(throws: BiliAPIError.decodingFailed) {
            try await client.uploaderCard(for: 10_001).profile
        }
    }
}
