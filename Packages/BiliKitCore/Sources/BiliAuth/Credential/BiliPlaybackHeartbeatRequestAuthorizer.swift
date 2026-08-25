import BiliNetworking
import Foundation

/// 只授权 V1 唯一账户写能力，并在 `BiliAuth` 内注入最小 Cookie 与 CSRF。
public struct BiliPlaybackHeartbeatRequestAuthorizer: HTTPRequestAuthorizing,
    Sendable
{
    private static let allowedPath = "/x/click-interface/web/heartbeat"
    private static let maximumBodySize = 2 * 1_024
    private static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 BiliKitMac/0.1"
    private static let requiredQueryNames: Set<String> = [
        "w_aid", "w_dt", "w_last_play_progress_time", "w_played_time",
        "w_real_played_time", "w_realtime", "w_start_ts", "web_location",
        "wts", "w_rid",
    ]
    private static let optionalQueryNames: Set<String> = ["w_video_duration"]
    private static let requiredBodyNames: Set<String> = [
        "start_ts", "aid", "cid", "type", "sub_type", "dt", "play_type",
        "realtime", "played_time", "real_played_time", "refer_url",
        "last_play_progress_time", "max_play_progress_time", "outer",
        "mobi_app", "device", "platform", "session",
    ]
    private static let optionalBodyNames: Set<String> = ["video_duration"]

    private let store: any WebCredentialStoring

    public init() {
        store = KeychainWebCredentialStore()
    }

    init(store: any WebCredentialStoring) {
        self.store = store
    }

    public func authorize(_ request: HTTPRequest) async throws -> HTTPRequest {
        guard Self.isAllowedRequest(request),
            let body = request.body,
            body.count <= Self.maximumBodySize,
            let bodyString = String(data: body, encoding: .utf8),
            let bodyFields = Self.allowedBodyFields(bodyString),
            let queryFields = Self.allowedQueryFields(request.url),
            Self.matchesSignedFacts(body: bodyFields, query: queryFields),
            Self.hasMatchingReferer(request.headers, body: bodyFields)
        else {
            throw BiliRequestAuthorizationError.requestNotAllowed
        }
        guard !Self.containsCredentialHeader(request.headers) else {
            throw BiliRequestAuthorizationError.credentialHeaderAlreadyPresent
        }

        let credential = try loadCredential()
        guard let session = credential.value(for: .session),
            let csrf = credential.value(for: .csrf),
            let encodedCSRF = Self.percentEncodedPair(name: "csrf", value: csrf)
        else {
            throw BiliRequestAuthorizationError.invalidCredential
        }

        var headers = request.headers
        headers["Cookie"] = "SESSDATA=\(session)"
        return HTTPRequest(
            url: request.url,
            method: request.method,
            headers: headers,
            body: Data("\(bodyString)&\(encodedCSRF)".utf8)
        )
    }

    private func loadCredential() throws -> WebCredential {
        let credential: WebCredential
        do {
            guard let stored = try store.load() else {
                throw BiliRequestAuthorizationError.missingCredential
            }
            credential = stored
        } catch let error as BiliRequestAuthorizationError {
            throw error
        } catch WebCredentialStoreError.corruptCredential {
            try purgeStoredCredential()
            throw BiliRequestAuthorizationError.invalidCredential
        } catch {
            throw BiliRequestAuthorizationError.credentialStoreUnavailable
        }
        guard !credential.isExpired() else {
            try purgeStoredCredential()
            throw BiliRequestAuthorizationError.expiredCredential
        }
        return credential
    }

    private func purgeStoredCredential() throws {
        do {
            try store.delete()
        } catch {
            throw BiliRequestAuthorizationError.credentialStoreUnavailable
        }
    }

    private static func isAllowedRequest(_ request: HTTPRequest) -> Bool {
        guard
            let components = URLComponents(
                url: request.url,
                resolvingAgainstBaseURL: false
            )
        else { return false }
        let normalizedHeaders = Dictionary(
            grouping: request.headers,
            by: { $0.key.lowercased() }
        )
        let allowedHeaderNames: Set<String> = [
            "accept", "content-type", "referer", "user-agent",
        ]
        guard Set(normalizedHeaders.keys) == allowedHeaderNames,
            normalizedHeaders.values.allSatisfy({ $0.count == 1 }),
            normalizedHeaders["accept"]?.first?.value == "application/json",
            normalizedHeaders["content-type"]?.first?.value
                == "application/x-www-form-urlencoded",
            normalizedHeaders["user-agent"]?.first?.value == userAgent
        else { return false }

        return components.scheme?.lowercased() == "https"
            && components.host?.lowercased() == "api.bilibili.com"
            && (components.port == nil || components.port == 443)
            && components.user == nil
            && components.password == nil
            && components.path == allowedPath
            && components.percentEncodedPath == allowedPath
            && components.percentEncodedQuery != nil
            && components.fragment == nil
            && request.method == .post
    }

    private static func allowedQueryFields(_ url: URL) -> [String: String]? {
        guard
            let encodedQuery = URLComponents(
                url: url,
                resolvingAgainstBaseURL: false
            )?.percentEncodedQuery,
            let fields = decodedUniqueFields(encodedQuery)
        else { return nil }
        let names = Set(fields.keys)
        guard names.isSuperset(of: requiredQueryNames),
            names.isSubset(of: requiredQueryNames.union(optionalQueryNames)),
            positiveInteger(fields["w_aid"]),
            fields["w_dt"] == "2",
            nonnegativeInteger(fields["w_last_play_progress_time"]),
            signedPlayedTime(fields["w_played_time"]),
            nonnegativeInteger(fields["w_real_played_time"]),
            nonnegativeInteger(fields["w_realtime"]),
            positiveInteger(fields["w_start_ts"]),
            fields["web_location"] == "1315873",
            positiveInteger(fields["wts"]),
            isLowercaseHex(fields["w_rid"], count: 32),
            fields["w_video_duration"].map(positiveInteger) ?? true
        else { return nil }
        return fields
    }

    private static func allowedBodyFields(_ body: String) -> [String: String]? {
        guard let fields = decodedUniqueFields(body) else { return nil }
        let names = Set(fields.keys)
        guard names.isSuperset(of: requiredBodyNames),
            names.isSubset(of: requiredBodyNames.union(optionalBodyNames)),
            positiveInteger(fields["start_ts"]),
            positiveInteger(fields["aid"]),
            positiveInteger(fields["cid"]),
            fields["type"] == "3",
            fields["sub_type"] == "0",
            fields["dt"] == "2",
            let playType = integer(fields["play_type"]),
            (0...4).contains(playType),
            nonnegativeInteger(fields["realtime"]),
            signedPlayedTime(fields["played_time"]),
            nonnegativeInteger(fields["real_played_time"]),
            nonnegativeInteger(fields["last_play_progress_time"]),
            nonnegativeInteger(fields["max_play_progress_time"]),
            fields["outer"] == "0",
            fields["mobi_app"] == "web",
            fields["device"] == "web",
            fields["platform"] == "web",
            isLowercaseHex(fields["session"], count: 32),
            fields["video_duration"].map(positiveInteger) ?? true,
            let played = integer(fields["played_time"]),
            played != -1 || playType == 4,
            let position = integer(fields["last_play_progress_time"]),
            let maximum = integer(fields["max_play_progress_time"]),
            maximum >= position,
            let realtime = integer(fields["realtime"]),
            let realPlayed = integer(fields["real_played_time"]),
            realtime >= realPlayed
        else { return nil }
        return fields
    }

    private static func matchesSignedFacts(
        body: [String: String],
        query: [String: String]
    ) -> Bool {
        let mirrors = [
            ("aid", "w_aid"),
            ("dt", "w_dt"),
            ("last_play_progress_time", "w_last_play_progress_time"),
            ("played_time", "w_played_time"),
            ("real_played_time", "w_real_played_time"),
            ("realtime", "w_realtime"),
            ("start_ts", "w_start_ts"),
        ]
        return mirrors.allSatisfy { body[$0.0] == query[$0.1] }
            && body["video_duration"] == query["w_video_duration"]
    }

    private static func hasMatchingReferer(
        _ headers: [String: String],
        body: [String: String]
    ) -> Bool {
        guard
            let header = headers.first(where: {
                $0.key.caseInsensitiveCompare("Referer") == .orderedSame
            })?.value,
            header == body["refer_url"],
            let components = URLComponents(string: header)
        else { return false }
        let pathParts = components.path.split(separator: "/")
        return components.scheme == "https"
            && components.host == "www.bilibili.com"
            && components.port == nil
            && components.user == nil
            && components.password == nil
            && components.query == nil
            && components.fragment == nil
            && components.percentEncodedPath == components.path
            && header.hasSuffix("/")
            && pathParts.count == 2
            && pathParts[0] == "video"
            && pathParts[1].hasPrefix("BV")
            && pathParts[1].count <= 24
            && pathParts[1].allSatisfy {
                $0.isASCII && ($0.isLetter || $0.isNumber)
            }
    }

    private static func decodedUniqueFields(_ value: String) -> [String: String]? {
        var result: [String: String] = [:]
        for pair in value.split(separator: "&", omittingEmptySubsequences: false) {
            let parts = pair.split(
                separator: "=",
                maxSplits: 1,
                omittingEmptySubsequences: false
            )
            guard parts.count == 2,
                let name = String(parts[0]).removingPercentEncoding,
                let value = String(parts[1]).removingPercentEncoding,
                !name.isEmpty,
                result.updateValue(value, forKey: name) == nil
            else { return nil }
        }
        return result
    }

    private static func integer(_ value: String?) -> Int64? {
        guard let value, !value.isEmpty,
            value.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == "-") })
        else { return nil }
        return Int64(value)
    }

    private static func positiveInteger(_ value: String?) -> Bool {
        (integer(value) ?? 0) > 0
    }

    private static func nonnegativeInteger(_ value: String?) -> Bool {
        (integer(value) ?? -1) >= 0
    }

    private static func signedPlayedTime(_ value: String?) -> Bool {
        guard let number = integer(value) else { return false }
        return number >= -1
    }

    private static func isLowercaseHex(_ value: String?, count: Int) -> Bool {
        guard let value, value.count == count else { return false }
        return value.allSatisfy {
            $0.isNumber || ("a"..."f").contains(String($0))
        }
    }

    private static func containsCredentialHeader(_ headers: [String: String]) -> Bool {
        headers.keys.contains {
            $0.caseInsensitiveCompare("Cookie") == .orderedSame
                || $0.caseInsensitiveCompare("Authorization") == .orderedSame
                || $0.caseInsensitiveCompare("X-CSRF-Token") == .orderedSame
        }
    }

    private static func percentEncodedPair(name: String, value: String) -> String? {
        var components = URLComponents()
        components.queryItems = [URLQueryItem(name: name, value: value)]
        return components.percentEncodedQuery
    }
}
