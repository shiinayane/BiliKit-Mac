import BiliModels
import Foundation
import Testing

@testable import BiliAuth

struct NavigationAuthenticationPayloadTests {
    @Test
    func mapsCompleteIdentityAndNormalizesAvatarURL() throws {
        let result = try authenticationResult(
            #"{"isLogin":true,"mid":42,"uname":"  Fixture Account  ","face":"//i0.hdslb.com/fixture/avatar.png"}"#
        )
        let identity = AccountIdentity(
            id: 42,
            displayName: "Fixture Account",
            avatarURL: URL(
                string: "https://i0.hdslb.com/fixture/avatar.png"
            )
        )

        #expect(result == .signedIn(identity))
    }

    @Test
    func missingOrMalformedOptionalIdentityDoesNotDenyAuthentication() throws {
        #expect(
            try authenticationResult(#"{"isLogin":true}"#)
                == .signedIn(nil)
        )
        #expect(
            try authenticationResult(
                #"{"isLogin":true,"mid":"unexpected","uname":42,"face":false}"#
            ) == .signedIn(nil)
        )
    }

    @Test
    func invalidAvatarKeepsOtherwiseValidIdentity() throws {
        let result = try authenticationResult(
            #"{"isLogin":true,"mid":42,"uname":"Fixture Account","face":"javascript:fixture"}"#
        )
        let identity = AccountIdentity(
            id: 42,
            displayName: "Fixture Account",
            avatarURL: nil
        )

        #expect(result == .signedIn(identity))
    }

    @Test
    func localOrAddressLiteralAvatarDoesNotCrossPublicImageBoundary() throws {
        for avatar in [
            "https://localhost/avatar.png",
            "https://127.0.0.1/avatar.png",
            "https://[::1]/avatar.png",
        ] {
            let result = try authenticationResult(
                "{\"isLogin\":true,\"mid\":42,\"uname\":\"Fixture Account\",\"face\":\"\(avatar)\"}"
            )
            let identity = AccountIdentity(
                id: 42,
                displayName: "Fixture Account",
                avatarURL: nil
            )

            #expect(result == .signedIn(identity))
        }
    }

    @Test
    func explicitSignedOutIgnoresIdentityFields() throws {
        #expect(
            try authenticationResult(
                #"{"isLogin":false,"mid":42,"uname":"Fixture Account"}"#
            ) == .signedOut
        )
    }

    private func authenticationResult(
        _ dataJSON: String
    ) throws -> NavigationAuthenticationResult {
        let envelopeJSON = "{\"code\":0,\"data\":\(dataJSON)}"
        let envelope = try JSONDecoder().decode(
            NavigationAuthenticationEnvelope.self,
            from: Data(envelopeJSON.utf8)
        )
        return try #require(envelope.data).authenticationResult
    }
}
