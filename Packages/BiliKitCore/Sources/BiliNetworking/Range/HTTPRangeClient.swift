import Foundation

public struct HTTPByteRange: Sendable, Equatable {
    public let start: Int64
    public let endInclusive: Int64

    public init(start: Int64, endInclusive: Int64) throws {
        guard start >= 0, endInclusive >= start else {
            throw HTTPByteRangeError.invalidBounds(
                start: start,
                endInclusive: endInclusive
            )
        }

        self.start = start
        self.endInclusive = endInclusive
    }

    public var headerValue: String {
        "bytes=\(start)-\(endInclusive)"
    }

    public var length: UInt64 {
        UInt64(endInclusive - start) + 1
    }
}

public enum HTTPByteRangeError: Error, Sendable, Equatable {
    case invalidBounds(start: Int64, endInclusive: Int64)
}

public struct HTTPContentRange: Sendable, Equatable {
    public let start: Int64
    public let endInclusive: Int64
    public let completeLength: Int64?

    public init(start: Int64, endInclusive: Int64, completeLength: Int64?) throws {
        guard start >= 0, endInclusive >= start else {
            throw HTTPContentRangeError.invalidValue
        }
        if let completeLength, completeLength <= endInclusive {
            throw HTTPContentRangeError.invalidValue
        }

        self.start = start
        self.endInclusive = endInclusive
        self.completeLength = completeLength
    }

    public static func parse(_ value: String) throws -> Self {
        let unitAndValue = value.split(
            maxSplits: 1,
            omittingEmptySubsequences: true,
            whereSeparator: { $0.isWhitespace }
        )
        guard unitAndValue.count == 2,
              unitAndValue[0].lowercased() == "bytes"
        else {
            throw HTTPContentRangeError.invalidValue
        }

        let rangeAndLength = unitAndValue[1].split(
            separator: "/",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        guard rangeAndLength.count == 2 else {
            throw HTTPContentRangeError.invalidValue
        }

        let bounds = rangeAndLength[0].split(
            separator: "-",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        guard bounds.count == 2,
              let start = Int64(bounds[0]),
              let endInclusive = Int64(bounds[1])
        else {
            throw HTTPContentRangeError.invalidValue
        }

        let completeLength: Int64?
        if rangeAndLength[1] == "*" {
            completeLength = nil
        } else {
            guard let parsedLength = Int64(rangeAndLength[1]) else {
                throw HTTPContentRangeError.invalidValue
            }
            completeLength = parsedLength
        }

        return try Self(
            start: start,
            endInclusive: endInclusive,
            completeLength: completeLength
        )
    }
}

public enum HTTPContentRangeError: Error, Sendable, Equatable {
    case invalidValue
}

public struct HTTPRangeFetchResult: Sendable, Equatable {
    public let sourceURL: URL
    public let contentRange: HTTPContentRange
    public let body: Data

    public init(sourceURL: URL, contentRange: HTTPContentRange, body: Data) {
        self.sourceURL = sourceURL
        self.contentRange = contentRange
        self.body = body
    }
}

public struct HTTPRangeAttempt: Sendable, Equatable {
    public let url: URL
    public let failure: HTTPRangeAttemptFailure

    public init(url: URL, failure: HTTPRangeAttemptFailure) {
        self.url = url
        self.failure = failure
    }
}

public enum HTTPRangeAttemptFailure: Sendable, Equatable {
    case statusCode(Int)
    case missingContentRange
    case invalidContentRange
    case mismatchedContentRange(expected: HTTPByteRange, actual: HTTPContentRange)
    case bodyLengthMismatch(expected: UInt64, actual: Int)
    case rejectedBody
    case transport(errorType: String)
}

public enum HTTPRangeClientError: Error, Sendable, Equatable {
    case noCandidates
    case allCandidatesFailed([HTTPRangeAttempt])
}

public struct HTTPRangeClient: Sendable {
    private let transport: any HTTPTransport

    public init(transport: any HTTPTransport = URLSessionTransport()) {
        self.transport = transport
    }

    public func fetch(
        from candidateURLs: [URL],
        range: HTTPByteRange,
        headers additionalHeaders: [String: String] = [:],
        validateBody: (@Sendable (Data) -> Bool)? = nil
    ) async throws -> HTTPRangeFetchResult {
        guard !candidateURLs.isEmpty else {
            throw HTTPRangeClientError.noCandidates
        }

        var attempts: [HTTPRangeAttempt] = []
        for url in candidateURLs {
            try Task.checkCancellation()

            let request = HTTPRequest(
                url: url,
                headers: headersBySettingRange(
                    range,
                    on: additionalHeaders
                )
            )

            do {
                let response = try await transport.send(request)
                let result = try validatedResult(
                    response,
                    sourceURL: url,
                    expectedRange: range
                )
                if let validateBody, !validateBody(result.body) {
                    throw HTTPRangeAttemptFailureError(.rejectedBody)
                }
                return result
            } catch is CancellationError {
                throw CancellationError()
            } catch let failure as HTTPRangeAttemptFailureError {
                attempts.append(HTTPRangeAttempt(url: url, failure: failure.value))
            } catch {
                attempts.append(
                    HTTPRangeAttempt(
                        url: url,
                        failure: .transport(
                            errorType: String(reflecting: type(of: error))
                        )
                    )
                )
            }
        }

        throw HTTPRangeClientError.allCandidatesFailed(attempts)
    }

    private func headersBySettingRange(
        _ range: HTTPByteRange,
        on headers: [String: String]
    ) -> [String: String] {
        var result = headers.filter { name, _ in
            name.caseInsensitiveCompare("Range") != .orderedSame
        }
        result["Range"] = range.headerValue
        return result
    }

    private func validatedResult(
        _ response: HTTPResponse,
        sourceURL: URL,
        expectedRange: HTTPByteRange
    ) throws -> HTTPRangeFetchResult {
        guard response.statusCode == 206 else {
            throw HTTPRangeAttemptFailureError(.statusCode(response.statusCode))
        }
        guard let rawContentRange = response.headerValue(named: "Content-Range") else {
            throw HTTPRangeAttemptFailureError(.missingContentRange)
        }

        let contentRange: HTTPContentRange
        do {
            contentRange = try HTTPContentRange.parse(rawContentRange)
        } catch {
            throw HTTPRangeAttemptFailureError(.invalidContentRange)
        }

        guard contentRange.start == expectedRange.start,
              contentRange.endInclusive == expectedRange.endInclusive
        else {
            throw HTTPRangeAttemptFailureError(
                .mismatchedContentRange(
                    expected: expectedRange,
                    actual: contentRange
                )
            )
        }
        guard UInt64(response.body.count) == expectedRange.length else {
            throw HTTPRangeAttemptFailureError(
                .bodyLengthMismatch(
                    expected: expectedRange.length,
                    actual: response.body.count
                )
            )
        }

        return HTTPRangeFetchResult(
            sourceURL: sourceURL,
            contentRange: contentRange,
            body: response.body
        )
    }
}

private struct HTTPRangeAttemptFailureError: Error {
    let value: HTTPRangeAttemptFailure

    init(_ value: HTTPRangeAttemptFailure) {
        self.value = value
    }
}

private extension HTTPResponse {
    func headerValue(named expectedName: String) -> String? {
        headers.first { name, _ in
            name.caseInsensitiveCompare(expectedName) == .orderedSame
        }?.value
    }
}
