import Foundation

public struct HTTPLogRedactor: Sendable {
    private let sensitiveQueryKeys: Set<String>
    private let sensitiveHeaderNames: Set<String>

    public init(
        sensitiveQueryKeys: Set<String> = [
            "access_key",
            "access_token",
            "bili_jct",
            "csrf",
            "qrcode_key",
            "refresh_token",
            "sessdata",
            "sign",
            "token",
            "w_rid",
        ],
        sensitiveHeaderNames: Set<String> = [
            "authorization",
            "cookie",
            "set-cookie",
        ]
    ) {
        self.sensitiveQueryKeys = Set(sensitiveQueryKeys.map { $0.lowercased() })
        self.sensitiveHeaderNames = Set(sensitiveHeaderNames.map { $0.lowercased() })
    }

    public func redact(url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return "<invalid-url>"
        }

        components.queryItems = components.queryItems?.map { item in
            guard sensitiveQueryKeys.contains(item.name.lowercased()) else {
                return item
            }
            return URLQueryItem(name: item.name, value: "<redacted>")
        }

        return components.string ?? "<invalid-url>"
    }

    public func redact(headers: [String: String]) -> [String: String] {
        headers.reduce(into: [String: String]()) { result, entry in
            if sensitiveHeaderNames.contains(entry.key.lowercased()) {
                result[entry.key] = "<redacted>"
            } else {
                result[entry.key] = entry.value
            }
        }
    }
}
