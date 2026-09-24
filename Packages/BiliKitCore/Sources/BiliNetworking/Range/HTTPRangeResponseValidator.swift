import Foundation

/// 所有 Range client 共用的失败分类；不保留响应正文或底层 Error 文本。
public enum HTTPRangeResponseError: Error, Sendable, Equatable {
    case disallowedURL
    case invalidRangeHeader
    case statusCode(Int)
    case missingContentRange
    case invalidContentRange
    case mismatchedContentRange(expected: HTTPByteRange, actual: HTTPContentRange)
    case missingCompleteLength
    case mismatchedCompleteLength(expected: Int64, actual: Int64)
    case missingContentLength
    case invalidContentLength
    case mismatchedContentLength(expected: UInt64, actual: UInt64)
    case missingContentType
    case unsupportedContentType(String)
    case bodyLengthMismatch(expected: UInt64, actual: UInt64)
    case rejectedBody
    case transport(errorType: String)
}

/// Range 响应头的唯一验证：精确 `206` 与 `Content-Range` 起止，按用途再要求完整长度、
/// `Content-Length` 与 `Content-Type`。
struct HTTPRangeResponseValidator: Sendable {
    let expectedRange: HTTPByteRange
    /// nil 表示不要求 `Content-Range` 的完整长度。
    var expectedCompleteLength: Int64?
    var requiresContentLength = false
    /// nil 表示不限制 `Content-Type`。
    var allowedContentTypes: Set<String>?

    func validate(_ response: URLResponse) throws -> HTTPRangeStreamResponse {
        guard let response = response as? HTTPURLResponse else {
            throw HTTPRangeResponseError.transport(
                errorType: String(reflecting: HTTPClientError.nonHTTPResponse)
            )
        }
        return try validate(statusCode: response.statusCode) {
            response.value(forHTTPHeaderField: $0)
        }
    }

    func validate(
        statusCode: Int,
        headerValue: (String) -> String?
    ) throws -> HTTPRangeStreamResponse {
        guard statusCode == 206 else {
            throw HTTPRangeResponseError.statusCode(statusCode)
        }
        guard let rawRange = headerValue("Content-Range") else {
            throw HTTPRangeResponseError.missingContentRange
        }
        let contentRange: HTTPContentRange
        do {
            contentRange = try HTTPContentRange.parse(rawRange)
        } catch {
            throw HTTPRangeResponseError.invalidContentRange
        }
        guard contentRange.start == expectedRange.start,
            contentRange.endInclusive == expectedRange.endInclusive
        else {
            throw HTTPRangeResponseError.mismatchedContentRange(
                expected: expectedRange,
                actual: contentRange
            )
        }
        if let expectedCompleteLength {
            guard let completeLength = contentRange.completeLength else {
                throw HTTPRangeResponseError.missingCompleteLength
            }
            guard completeLength == expectedCompleteLength else {
                throw HTTPRangeResponseError.mismatchedCompleteLength(
                    expected: expectedCompleteLength,
                    actual: completeLength
                )
            }
        }
        if requiresContentLength {
            guard let rawLength = headerValue("Content-Length") else {
                throw HTTPRangeResponseError.missingContentLength
            }
            guard let contentLength = UInt64(rawLength) else {
                throw HTTPRangeResponseError.invalidContentLength
            }
            guard contentLength == expectedRange.length else {
                throw HTTPRangeResponseError.mismatchedContentLength(
                    expected: expectedRange.length,
                    actual: contentLength
                )
            }
        }
        let contentType = headerValue("Content-Type").map {
            $0.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)[0]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
        }
        if let allowedContentTypes {
            guard let contentType else {
                throw HTTPRangeResponseError.missingContentType
            }
            guard allowedContentTypes.contains(contentType) else {
                throw HTTPRangeResponseError.unsupportedContentType(contentType)
            }
        }
        return HTTPRangeStreamResponse(
            contentRange: contentRange,
            contentLength: expectedRange.length,
            contentType: contentType
        )
    }
}

extension URLSessionConfiguration {
    /// 媒体与字幕等无凭据请求使用的 ephemeral 配置：不设置 Cookie，没有 Cookie、凭据与 URL cache。
    package static func credentialFreeEphemeral() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return configuration
    }
}

extension Dictionary where Key == String, Value == String {
    /// 去掉不能随媒体 Range 请求离开进程的 `Cookie`、`Authorization`，以及由 client 自己设置的 `Range`。
    package func removingCredentialAndRangeHeaders() -> [String: String] {
        filter { name, _ in
            ["Cookie", "Authorization", "Range"].allSatisfy {
                name.caseInsensitiveCompare($0) != .orderedSame
            }
        }
    }
}

extension URLRequest {
    /// 以过滤后的调用方 header 与单一 Range 头构造 GET 请求。
    static func rangeGET(
        _ url: URL,
        rangeHeader: String,
        headers: [String: String]
    ) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        for (name, value) in headers.removingCredentialAndRangeHeaders() {
            request.setValue(value, forHTTPHeaderField: name)
        }
        request.setValue(rangeHeader, forHTTPHeaderField: "Range")
        return request
    }
}
