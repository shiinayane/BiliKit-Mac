import Testing

@testable import BiliAuth

/// APP 签名补上 TV 的 appkey 与 ts，按键名排序、按 unreserved 规则编码后拼 appsec 求 MD5；签名错了 B 站会拒绝取码与轮询。
struct BiliAppSigningTests {
    @Test
    func signsSortedUnreservedEncodedFormWithTVKey() {
        let form = BiliAppSigning.signed(
            ["local_id": "0", "auth_code": "FIXTURE AUTH+CODE"],
            timestamp: 1_700_000_000
        )

        // 期望值按协议规则离线算出：排序后的正文拼上 TV appsec 的 MD5。
        #expect(
            form
                == "appkey=4409e2ce8ffd12b8&auth_code=FIXTURE%20AUTH%2BCODE&local_id=0&ts=1700000000"
                + "&sign=d4a00b15a3d18c17912d85c6d1adfa59"
        )
    }

    @Test(arguments: ["appkey", "ts", "sign"])
    func rejectsCallerSuppliedReservedParameter(_ name: String) {
        #expect(BiliAppSigning.signed([name: "FIXTURE"], timestamp: 1_700_000_000) == nil)
    }
}
