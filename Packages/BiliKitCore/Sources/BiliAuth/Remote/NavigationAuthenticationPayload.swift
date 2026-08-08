import BiliModels
import BiliNetworking
import Foundation

struct NavigationAuthenticationEnvelope: Decodable, Sendable {
    let code: Int
    let data: NavigationAuthenticationPayload?
}

struct NavigationAuthenticationPayload: Decodable, Sendable {
    let isLogin: Bool
    private let mid: Int64?
    private let uname: String?
    private let face: String?

    private enum CodingKeys: String, CodingKey {
        case isLogin
        case mid
        case uname
        case face
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isLogin = try container.decode(Bool.self, forKey: .isLogin)
        mid = try? container.decode(Int64.self, forKey: .mid)
        uname = try? container.decode(String.self, forKey: .uname)
        face = try? container.decode(String.self, forKey: .face)
    }

    var authenticationResult: NavigationAuthenticationResult {
        guard isLogin else { return .signedOut }
        guard let mid, mid > 0, let uname else {
            return .signedIn(nil)
        }
        let displayName = uname.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !displayName.isEmpty else { return .signedIn(nil) }
        return .signedIn(
            AccountIdentity(
                id: mid,
                displayName: displayName,
                avatarURL: Self.imageURL(from: face)
            )
        )
    }

    private static func imageURL(from value: String?) -> URL? {
        guard let value, !value.isEmpty else { return nil }
        let normalized: String
        if value.hasPrefix("//") {
            normalized = "https:\(value)"
        } else if value.lowercased().hasPrefix("http://") {
            normalized = "https://" + value.dropFirst("http://".count)
        } else {
            normalized = value
        }
        guard let url = URL(string: normalized),
            PublicHTTPSURLPolicy().allows(url)
        else {
            return nil
        }
        return url
    }
}

enum NavigationAuthenticationResult: Sendable, Equatable {
    case signedOut
    case signedIn(AccountIdentity?)
}

enum StoredAccountSessionRestoreResult: Sendable, Equatable {
    case signedOut(hadCredential: Bool)
    case signedIn(AccountIdentity?)
}
