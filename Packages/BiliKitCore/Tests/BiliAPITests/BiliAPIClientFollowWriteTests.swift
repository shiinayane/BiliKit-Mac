import BiliAPI
import BiliApplication
import BiliModels
import BiliNetworking
import Foundation
import Testing

/// 固定特别关注与设置分组的请求形状：都是网页表单，经账户写授权器绑定账户，Referer 与 Origin 同关注；特别关注只发单个
/// `fid`；设置分组只发单个 `fids` 与完整的 `tagids`（-10 与自定义分组 id，只在默认分组时是单独的 0）。
@Suite(.timeLimit(.minutes(1)))
struct BiliAPIClientFollowWriteTests {
    @Test(arguments: [
        (true, "https://api.bilibili.com/x/relation/tag/special/add"),
        (false, "https://api.bilibili.com/x/relation/tag/special/del")
    ])
    func specialSendsOnlyTheFid(isSpecial: Bool, url: String) async throws {
        let authorizer = StubSubjectBoundAuthorizer()
        let repository = BiliFollowRelationWriteRepository(
            client: BiliAPIClient(
                transport: StubTransport(responses: [statusResponse(code: 0)]),
                accountWriteAuthorizer: authorizer
            )
        )

        try await repository.setSpecial(isSpecial, uploader: try uploader(), accountID: 42)

        let authorized = try #require(await authorizer.capturedRequests().last)
        #expect(await authorizer.subjects == ["42"])
        #expect(authorized.url.absoluteString == url)
        #expect(authorized.headers["Referer"] == "https://www.bilibili.com/")
        #expect(authorized.headers["Origin"] == "https://www.bilibili.com")
        #expect(formFields(authorized) == ["fid": "7"])
    }

    /// 接口按完整集合覆盖：发出的总是这个人要在的全部分组，同一集合总是同一个请求。
    @Test(arguments: [
        (FollowMembership.defaultGroupOnly, "0"),
        (FollowMembership(isSpecial: true, customGroupIDs: []), "-10"),
        (FollowMembership(isSpecial: false, customGroupIDs: [12, 3]), "3,12"),
        (FollowMembership(isSpecial: true, customGroupIDs: [12, 3]), "-10,3,12")
    ])
    func groupsSendTheWholeSet(membership: FollowMembership, tagids: String) async throws {
        let authorizer = StubSubjectBoundAuthorizer()
        let repository = BiliFollowRelationWriteRepository(
            client: BiliAPIClient(
                transport: StubTransport(responses: [statusResponse(code: 0)]),
                accountWriteAuthorizer: authorizer
            )
        )

        try await repository.assignGroups(membership, uploader: try uploader(), accountID: 42)

        let authorized = try #require(await authorizer.capturedRequests().last)
        #expect(
            authorized.url.absoluteString == "https://api.bilibili.com/x/relation/tags/addUsers"
        )
        #expect(authorized.headers["Referer"] == "https://www.bilibili.com/")
        #expect(formFields(authorized) == ["fids": "7", "tagids": tagids])
    }

    private func uploader() throws -> UploaderWriteTarget {
        try #require(UploaderWriteTarget(mid: 7))
    }
}
