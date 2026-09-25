import BiliModels
import Foundation
import Testing

@testable import BiliAuth

private let fixtureIdentityWithoutAvatar = AccountIdentity(
    id: 42,
    displayName: "Fixture Account",
    avatarURL: nil
)

struct NavigationAuthenticationPayloadTests {
    @Test(
        arguments: [
            (
                #"{"isLogin":true,"mid":42,"uname":"  Fixture Account  ","face":"//i0.hdslb.com/fixture/avatar.png"}"#,
                .signedIn(
                    AccountIdentity(
                        id: 42,
                        displayName: "Fixture Account",
                        avatarURL: URL(string: "https://i0.hdslb.com/fixture/avatar.png")
                    )
                )
            ),
            // 可选身份字段缺失或类型异常时不否定登录态。
            (#"{"isLogin":true}"#, .signedIn(nil)),
            (#"{"isLogin":true,"mid":"unexpected","uname":42,"face":false}"#, .signedIn(nil)),
            // 头像越过公开图片边界时只丢头像，保留其余身份。
            (
                #"{"isLogin":true,"mid":42,"uname":"Fixture Account","face":"javascript:fixture"}"#,
                .signedIn(fixtureIdentityWithoutAvatar)
            ),
            (
                #"{"isLogin":true,"mid":42,"uname":"Fixture Account","face":"https://localhost/avatar.png"}"#,
                .signedIn(fixtureIdentityWithoutAvatar)
            ),
            (
                #"{"isLogin":true,"mid":42,"uname":"Fixture Account","face":"https://127.0.0.1/avatar.png"}"#,
                .signedIn(fixtureIdentityWithoutAvatar)
            ),
            (
                #"{"isLogin":true,"mid":42,"uname":"Fixture Account","face":"https://[::1]/avatar.png"}"#,
                .signedIn(fixtureIdentityWithoutAvatar)
            ),
            (#"{"isLogin":false,"mid":42,"uname":"Fixture Account"}"#, .signedOut)
        ] as [(String, NavigationAuthenticationResult)]
    )
    func mapsNavigationPayloadToNonSecretResult(
        dataJSON: String,
        expected: NavigationAuthenticationResult
    ) throws {
        let envelope = try JSONDecoder().decode(
            NavigationAuthenticationEnvelope.self,
            from: Data("{\"code\":0,\"data\":\(dataJSON)}".utf8)
        )

        #expect(try #require(envelope.data).authenticationResult == expected)
    }
}
