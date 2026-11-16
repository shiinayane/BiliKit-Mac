import BiliApplication
import BiliModels
import BiliNetworking
import Foundation
import Testing

@testable import BiliAPI

/// 固定关注读取的契约：都是账户读取、本地无凭据时不发请求；只有关注内搜索签 WBI；全部关注带排序；列表里的 `tag`、
/// `special`、`attribute` 映射为分组关系与互关，分组成员里不读它们（为未知）；分组列表丢弃认不出的 tagid；单人关系在
/// 没有关注时为 nil、缺 `attribute` 时按解码失败。
struct BiliAPIClientFollowTests {
    private static let listBody = #"""
        {"code":0,"message":"OK","data":{"total":3,"list":[
          {"mid":11,"uname":"甲","face":"https://i0.hdslb.com/bfs/face/a.jpg","sign":"签名","attribute":6,
           "special":1,"tag":[-10,501],"official_verify":{"type":0,"desc":"认证说明"},"vip":{"vipStatus":1}},
          {"mid":12,"uname":"乙","attribute":2,"special":0,"tag":null},
          {"mid":0,"uname":"无效"}
        ]}}
        """#

    @Test(arguments: [(FollowListOrder.recentlyFollowed, ""), (.mostVisited, "attention")])
    func allFollowingsIsUnsignedAccountReadWithOrder(
        order: FollowListOrder,
        orderType: String
    ) async throws {
        let transport = StubTransport(responses: [jsonResponse(Self.listBody)])
        let client = BiliAPIClient(transport: transport, requestAuthorizer: StubAuthorizer())

        _ = try await client.followPage(
            FollowListCursor(query: .all(order), page: 2),
            ownerID: 7,
            pageSize: 50
        )

        let request = try #require(transport.capturedRequests().first)
        #expect(transport.capturedRequests().count == 1)
        #expect(request.url.path == "/x/relation/followings")
        #expect(
            queryFields(request)
                == ["vmid": "7", "pn": "2", "ps": "50", "order": "desc", "order_type": orderType]
        )
    }

    @Test
    func listRowsMapRelationAndDropInvalidMids() async throws {
        let client = BiliAPIClient(
            transport: StubTransport(responses: [jsonResponse(Self.listBody)]),
            requestAuthorizer: StubAuthorizer()
        )

        let page = try await client.followPage(
            FollowListCursor(query: .all(.recentlyFollowed)),
            ownerID: 7,
            pageSize: 50
        )

        #expect(page.totalCount == 3)
        #expect(page.users.map(\.id) == [11, 12])
        let first = page.users[0]
        #expect(first.membership == FollowMembership(isSpecial: true, customGroupIDs: [501]))
        #expect(first.isMutual == true)
        #expect(first.isVIP)
        #expect(first.officialDescription == "认证说明")
        #expect(page.users[1].membership == .defaultGroupOnly)
        #expect(page.users[1].isMutual == false)
    }

    @Test
    func searchIsSignedAndSendsTheKeyword() async throws {
        let transport = StubTransport(
            responses: [jsonResponse(Self.listBody)],
            answersWBINavOnce: true
        )
        let client = BiliAPIClient(transport: transport, requestAuthorizer: StubAuthorizer())

        _ = try await client.followPage(
            FollowListCursor(query: .search("极客")),
            ownerID: 7,
            pageSize: 50
        )

        let request = try #require(transport.businessRequests().first)
        #expect(request.url.path == "/x/relation/followings/search")
        let fields = queryFields(request)
        #expect(fields["name"] == "极客")
        #expect(fields["vmid"] == "7")
        #expect(fields["w_rid"] != nil)
    }

    /// 分组成员接口里这三个字段对每个人都是 0／null，不能当成“不在任何分组”。
    @Test
    func groupMembersLeaveRelationUnknown() async throws {
        let body =
            #"{"code":0,"data":[{"mid":11,"uname":"甲","attribute":0,"special":0,"tag":null}]}"#
        let transport = StubTransport(responses: [jsonResponse(body)])
        let client = BiliAPIClient(transport: transport, requestAuthorizer: StubAuthorizer())

        let page = try await client.followPage(
            FollowListCursor(query: .group(-10)),
            ownerID: 7,
            pageSize: 50
        )

        let request = try #require(transport.capturedRequests().first)
        #expect(request.url.path == "/x/relation/tag")
        #expect(queryFields(request) == ["mid": "7", "tagid": "-10", "pn": "1", "ps": "50"])
        #expect(page.totalCount == nil)
        #expect(page.users.map(\.id) == [11])
        #expect(page.users[0].membership == nil)
        #expect(page.users[0].isMutual == nil)
    }

    @Test
    func groupsKeepKnownTagIDsInInterfaceOrder() async throws {
        let body = #"""
            {"code":0,"data":[{"tagid":-10,"name":"特别关注","count":1},{"tagid":0,"name":"默认分组","count":560},
            {"tagid":392856017,"name":"测试分组","count":0},{"tagid":-2,"name":"认不出"},{"name":"没有 id"}]}
            """#
        let client = BiliAPIClient(
            transport: StubTransport(responses: [jsonResponse(body)]),
            requestAuthorizer: StubAuthorizer()
        )

        let groups = try await client.followGroups(ownerID: 7)

        #expect(groups.map(\.id) == [-10, 0, 392_856_017])
        #expect(groups.map(\.count) == [1, 560, 0])
    }

    @Test(arguments: [
        (
            #"{"code":0,"data":{"attribute":2,"special":1,"tag":[-10,5]}}"#,
            FollowMembership?.some(
                FollowMembership(isSpecial: true, customGroupIDs: [5])
            )
        ),
        (#"{"code":0,"data":{"attribute":6,"special":0,"tag":null}}"#, .some(.defaultGroupOnly)),
        (#"{"code":0,"data":{"attribute":0,"special":0,"tag":null}}"#, nil),
        (#"{"code":0,"data":{"attribute":128}}"#, nil)
    ])
    func relationMapsMembershipOnlyWhenFollowing(
        body: String,
        expected: FollowMembership?
    ) async throws {
        let client = BiliAPIClient(
            transport: StubTransport(responses: [jsonResponse(body)]),
            requestAuthorizer: StubAuthorizer()
        )

        #expect(try await client.followRelation(to: 11) == expected)
    }

    @Test
    func relationWithoutAttributeFailsInsteadOfGuessing() async {
        let client = BiliAPIClient(
            transport: StubTransport(responses: [jsonResponse(#"{"code":0,"data":{"special":0}}"#)]
            ),
            requestAuthorizer: StubAuthorizer()
        )

        await #expect(throws: BiliAPIError.decodingFailed) {
            try await client.followRelation(to: 11)
        }
    }

    @Test
    func missingCredentialFailsBeforeAnyRequest() async {
        let transport = StubTransport(responses: [])
        let client = BiliAPIClient(
            transport: transport,
            requestAuthorizer: StubAuthorizer(.fail(.missingCredential))
        )

        await #expect(throws: BiliAPIError.authorizationRequired) {
            try await client.followGroups(ownerID: 7)
        }
        await #expect(throws: BiliAPIError.authorizationRequired) {
            try await client.followPage(
                FollowListCursor(query: .group(0)),
                ownerID: 7,
                pageSize: 50
            )
        }
        await #expect(throws: BiliAPIError.authorizationRequired) {
            try await client.followRelation(to: 11)
        }
        #expect(transport.capturedRequests().isEmpty)
    }
}
