import BiliAPI
import BiliApplication
import BiliModels
import BiliNetworking
import Foundation
import Testing

/// 固定播放页互动契约：互动状态按账户读取、带 aid 与 bvid，缺点赞、投币、收藏任一项整份失败，缺是否关注只让关注状态
/// 未知；点赞、投币、三连只发最少字段，经账户写授权器绑定账户，并在授权之后附加随机 `buvid3`；关注只发 `fid`、`act`、
/// `re_src`，不附加 `buvid3`，不给自己发；重复点赞、取消未赞与重复关注按成功处理，投币、三连与关注的业务码与风控映射为对应
/// 的写入错误，-403（账号异常）是这个客户端被拒、网页上可以完成。
@Suite(.timeLimit(.minutes(1)))
struct BiliAPIClientVideoEngagementTests {
    private static let bvid = "BV17x411w7KC"

    @Test
    func engagementIsAnAccountReadWithAIDAndBVID() async throws {
        let transport = StubTransport(responses: [
            jsonResponse(
                #"{"code":0,"data":{"like":true,"coin":1,"favorite":false,"attention":false}}"#
            )
        ])
        let client = BiliAPIClient(transport: transport, requestAuthorizer: StubAuthorizer())

        let state = try await client.videoEngagement(bvid: Self.bvid)

        #expect(
            state
                == VideoEngagementState(
                    isLiked: true,
                    coinCount: 1,
                    isFavorited: false,
                    isFollowingUploader: false
                )
        )
        let request = try #require(transport.capturedRequests().first)
        #expect(request.url.path == "/x/web-interface/archive/relation")
        #expect(queryFields(request) == ["aid": "170001", "bvid": Self.bvid])
        #expect(request.headers["Cookie"] == StubAuthorizer.cookie)
    }

    /// 不知道是否已赞、已投几枚就给不出按钮状态：缺字段时整份失败。
    @Test(arguments: [
        #"{"code":0,"data":{"coin":1,"favorite":false}}"#,
        #"{"code":0,"data":{"like":true,"favorite":false}}"#,
        #"{"code":0,"data":{"like":true,"coin":1}}"#
    ])
    func engagementWithoutAFieldFails(body: String) async {
        let client = BiliAPIClient(
            transport: StubTransport(responses: [jsonResponse(body)]),
            requestAuthorizer: StubAuthorizer()
        )

        await #expect(throws: BiliAPIError.decodingFailed) {
            try await client.videoEngagement(bvid: Self.bvid)
        }
    }

    @Test(arguments: [
        #"{"code":0,"data":{"like":true,"coin":1,"favorite":false}}"#,
        #"{"code":0,"data":{"like":true,"coin":1,"favorite":false,"attention":"yes"}}"#
    ])
    func engagementWithoutFollowStateKeepsTheRest(body: String) async throws {
        let client = BiliAPIClient(
            transport: StubTransport(responses: [jsonResponse(body)]),
            requestAuthorizer: StubAuthorizer()
        )

        let state = try await client.videoEngagement(bvid: Self.bvid)

        #expect(state == VideoEngagementState(isLiked: true, coinCount: 1, isFavorited: false))
    }

    @Test(arguments: [
        (true, "1"),
        (false, "2")
    ])
    func followSendsTheMinimalFormWithoutBuvid3(isFollowing: Bool, act: String) async throws {
        let transport = StubTransport(responses: [statusResponse(code: 0)])
        let authorizer = StubSubjectBoundAuthorizer()
        let repository = BiliVideoEngagementRepository(
            client: BiliAPIClient(transport: transport, accountWriteAuthorizer: authorizer)
        )

        try await repository.setFollowing(isFollowing, uploader: try uploader(), accountID: 42)

        let authorized = try #require(await authorizer.capturedRequests().last)
        #expect(await authorizer.subjects == ["42"])
        #expect(authorized.url.absoluteString == "https://api.bilibili.com/x/relation/modify")
        #expect(authorized.headers["Referer"] == "https://www.bilibili.com/")
        #expect(authorized.headers["Origin"] == "https://www.bilibili.com")
        #expect(formFields(authorized) == ["fid": "7", "act": act, "re_src": "11"])
        let sent = try #require(transport.capturedRequests().last)
        #expect(sent.headers["Cookie"]?.contains("buvid3=") != true)
    }

    /// 重复关注按成功处理；取消关注时同一码仍是失败；关注上限与 -403 映射为对应的写入错误。
    @Test(
        arguments: [
            (true, 22_014, nil),
            (false, 22_014, AccountWriteError.rejected(code: 22_014)),
            (true, 22_009, .listFull),
            (true, 22_002, .rejected(code: 22_002)),
            (true, -403, .declinedForClient)
        ] as [(Bool, Int, AccountWriteError?)]
    )
    func followMapsItsBusinessCodes(
        isFollowing: Bool,
        code: Int,
        expected: AccountWriteError?
    ) async throws {
        let repository = BiliVideoEngagementRepository(
            client: BiliAPIClient(
                transport: StubTransport(responses: [statusResponse(code: code)]),
                accountWriteAuthorizer: StubSubjectBoundAuthorizer()
            )
        )
        let uploader = try uploader()

        if let expected {
            await #expect(throws: expected) {
                try await repository.setFollowing(isFollowing, uploader: uploader, accountID: 42)
            }
        } else {
            try await repository.setFollowing(isFollowing, uploader: uploader, accountID: 42)
        }
    }

    @Test
    func followingYourselfSendsNothing() async {
        let transport = StubTransport(responses: [])
        let client = BiliAPIClient(
            transport: transport,
            accountWriteAuthorizer: StubSubjectBoundAuthorizer()
        )

        await #expect(throws: BiliAPIError.invalidRequest) {
            try await client.setUploaderFollowing(true, mid: 42, accountID: 42)
        }
        #expect(transport.capturedRequests().isEmpty)
    }

    @Test(arguments: [
        (true, "1"),
        (false, "2")
    ])
    func likeSendsTheMinimalFormWithBuvid3(isLiked: Bool, like: String) async throws {
        let transport = StubTransport(responses: [statusResponse(code: 0)])
        let authorizer = StubSubjectBoundAuthorizer()
        let repository = BiliVideoEngagementRepository(
            client: BiliAPIClient(transport: transport, accountWriteAuthorizer: authorizer)
        )

        try await repository.setLiked(isLiked, target: try target(), accountID: 42)

        let authorized = try #require(await authorizer.capturedRequests().last)
        #expect(await authorizer.subjects == ["42"])
        #expect(
            authorized.url.absoluteString == "https://api.bilibili.com/x/web-interface/archive/like"
        )
        #expect(authorized.headers["Referer"] == "https://www.bilibili.com/")
        #expect(formFields(authorized) == ["aid": "170001", "like": like])
        // 授权器不注入 buvid3；它在授权之后附加，发出的请求里与授权器给的 Cookie 并列。
        #expect(authorized.headers["Cookie"] == nil)
        let sent = try #require(transport.capturedRequests().last)
        #expect(sent.headers["Cookie"]?.contains("buvid3=") == true)
    }

    @Test
    func coinAndTripleSendTheMinimalForms() async throws {
        let transport = StubTransport(responses: [
            jsonResponse(#"{"code":0,"message":"OK","data":{"like":true}}"#),
            jsonResponse(
                #"{"code":0,"data":{"like":true,"coin":true,"fav":true,"multiply":1,"is_risk":false,"gaia_res_type":0}}"#
            )
        ])
        let authorizer = StubSubjectBoundAuthorizer()
        let repository = BiliVideoEngagementRepository(
            client: BiliAPIClient(transport: transport, accountWriteAuthorizer: authorizer)
        )

        let liked = try await repository.addCoins(
            2,
            alsoLike: true,
            target: try target(),
            accountID: 42
        )
        let outcome = try await repository.triple(target: try target(), accountID: 42)

        #expect(liked)
        #expect(
            outcome
                == VideoTripleOutcome(
                    isLiked: true,
                    isCoined: true,
                    isFavorited: true,
                    addedCoinCount: 1
                )
        )
        let requests = await authorizer.capturedRequests()
        #expect(
            requests.map(\.url.path) == [
                "/x/web-interface/coin/add", "/x/web-interface/archive/like/triple"
            ]
        )
        #expect(formFields(requests[0]) == ["aid": "170001", "multiply": "2", "select_like": "1"])
        #expect(formFields(requests[1]) == ["aid": "170001"])
        #expect(
            transport.capturedRequests().allSatisfy {
                $0.headers["Cookie"]?.contains("buvid3=") == true
            }
        )
    }

    /// 服务端已经是目标状态的点赞码按成功处理；反方向的同一码仍是失败。
    @Test(
        arguments: [
            (true, 65_006, nil),
            (false, 65_004, nil),
            (true, 65_004, AccountWriteError.rejected(code: 65_004)),
            (false, 65_006, .rejected(code: 65_006)),
            (true, -403, .declinedForClient)
        ] as [(Bool, Int, AccountWriteError?)]
    )
    func likeTreatsTheTargetStateAsSuccess(
        isLiked: Bool,
        code: Int,
        expected: AccountWriteError?
    ) async throws {
        let repository = BiliVideoEngagementRepository(
            client: BiliAPIClient(
                transport: StubTransport(responses: [statusResponse(code: code)]),
                accountWriteAuthorizer: StubSubjectBoundAuthorizer()
            )
        )
        let target = try target()

        if let expected {
            await #expect(throws: expected) {
                try await repository.setLiked(isLiked, target: target, accountID: 42)
            }
        } else {
            try await repository.setLiked(isLiked, target: target, accountID: 42)
        }
    }

    @Test(arguments: [
        (-104, AccountWriteError.coinsInsufficient),
        (34_002, .ownVideo),
        (34_004, .restricted),
        (34_005, .coinLimitReached),
        (-403, .declinedForClient),
        (10_003, .contentUnavailable),
        (12_345, .rejected(code: 12_345))
    ])
    func coinMapsItsBusinessCodes(code: Int, expected: AccountWriteError) async throws {
        let repository = BiliVideoEngagementRepository(
            client: BiliAPIClient(
                transport: StubTransport(responses: [statusResponse(code: code)]),
                accountWriteAuthorizer: StubSubjectBoundAuthorizer()
            )
        )
        let target = try target()

        await #expect(throws: expected) {
            _ = try await repository.addCoins(1, alsoLike: false, target: target, accountID: 42)
        }
    }

    /// 三连报告风控（`is_risk` 或 `gaia_res_type` 非 0）时不当作成功；缺逐项结果时按无效响应。
    @Test(arguments: [
        (
            #"{"code":0,"data":{"like":true,"coin":true,"fav":true,"multiply":2,"is_risk":true,"gaia_res_type":0}}"#,
            AccountWriteError.restricted
        ),
        (
            #"{"code":0,"data":{"like":true,"coin":true,"fav":true,"multiply":2,"is_risk":false,"gaia_res_type":1}}"#,
            .restricted
        ),
        (#"{"code":0,"data":{"like":true,"coin":true,"multiply":2}}"#, .unavailable),
        (#"{"code":0,"data":null}"#, .unavailable)
    ])
    func tripleRiskOrIncompleteResultFails(body: String, expected: AccountWriteError) async throws {
        let repository = BiliVideoEngagementRepository(
            client: BiliAPIClient(
                transport: StubTransport(responses: [jsonResponse(body)]),
                accountWriteAuthorizer: StubSubjectBoundAuthorizer()
            )
        )
        let target = try target()

        await #expect(throws: expected) {
            _ = try await repository.triple(target: target, accountID: 42)
        }
    }

    /// 投币只能 1 或 2 枚，不发请求。
    @Test(arguments: [0, 3])
    func coinCountOutsideTheLimitSendsNothing(count: Int) async {
        let transport = StubTransport(responses: [])
        let client = BiliAPIClient(
            transport: transport,
            accountWriteAuthorizer: StubSubjectBoundAuthorizer()
        )

        await #expect(throws: BiliAPIError.invalidRequest) {
            _ = try await client.addVideoCoins(
                count,
                alsoLike: false,
                bvid: Self.bvid,
                accountID: 42
            )
        }
        #expect(transport.capturedRequests().isEmpty)
    }

    private func target() throws -> VideoWriteTarget {
        try #require(VideoWriteTarget(bvid: Self.bvid))
    }

    private func uploader() throws -> UploaderWriteTarget {
        try #require(UploaderWriteTarget(mid: 7))
    }
}
