import BiliAPI
import BiliNetworking
import Foundation

@main
struct BiliAPIProbe {
    static func main() async {
        do {
            switch try Configuration(arguments: CommandLine.arguments).mode {
            case let .search(keyword, page):
                try await runSearch(keyword: keyword, page: page)
            case let .m4Contract(bvid, cid):
                try await M4ContractProbe().run(bvid: bvid, cid: cid)
            }
            print("RESULT: PASS")
        } catch let error as BiliAPIError {
            writeError("BiliAPIProbe failed: \(error.description)\n")
            exit(EXIT_FAILURE)
        } catch let error as ProbeError {
            writeError("BiliAPIProbe failed: \(error.rawValue)\n")
            exit(EXIT_FAILURE)
        } catch {
            writeError(
                "BiliAPIProbe failed: \(String(reflecting: type(of: error)))\n"
            )
            exit(EXIT_FAILURE)
        }
    }

    private static func runSearch(keyword: String, page: Int) async throws {
        let page = try await BiliAPIClient(
            transport: SearchProbeTransport()
        ).searchVideos(keyword: keyword, page: page)
        print(
            "search: page=\(page.pageNumber) count=\(page.videos.count) total=\(page.totalResults)"
        )
        if let first = page.videos.first {
            print(
                "first: bvid=\(first.bvid) duration=\(first.durationSeconds ?? 0)s"
            )
        }
    }

    private static func writeError(_ message: String) {
        FileHandle.standardError.write(Data(message.utf8))
    }
}

private actor SearchProbeTransport: HTTPTransport {
    private let transport = URLSessionTransport()

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let response = try await transport.send(request)
        print(
            "request: path=\(request.url.path) status=\(response.statusCode) bytes=\(response.body.count)"
        )
        return response
    }
}

private struct M4ContractProbe {
    private static let catalogLimit = 1 * 1_024 * 1_024
    private static let danmakuViewLimit = 256 * 1_024
    private static let danmakuSegmentLimit = 2 * 1_024 * 1_024

    private let transport: URLSessionTransport

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        transport = URLSessionTransport(
            configuration: configuration,
            redirectPolicy: .reject
        )
    }

    func run(bvid: String, cid: Int64) async throws {
        let referer = "https://www.bilibili.com/video/\(bvid)"
        let catalog = try await request(
            path: "/x/player/v2",
            queryItems: [
                URLQueryItem(name: "bvid", value: bvid),
                URLQueryItem(name: "cid", value: String(cid)),
            ],
            accept: "application/json",
            referer: referer
        )
        try observeCatalog(catalog)

        let view = try await request(
            path: "/x/v2/dm/web/view",
            queryItems: [
                URLQueryItem(name: "type", value: "1"),
                URLQueryItem(name: "oid", value: String(cid)),
            ],
            accept: "application/octet-stream",
            referer: referer
        )
        try observeBinary(
            view,
            name: "danmaku-view",
            maximumSize: Self.danmakuViewLimit
        )

        let segment = try await request(
            path: "/x/v2/dm/web/seg.so",
            queryItems: [
                URLQueryItem(name: "type", value: "1"),
                URLQueryItem(name: "oid", value: String(cid)),
                URLQueryItem(name: "segment_index", value: "1"),
            ],
            accept: "application/octet-stream",
            referer: referer
        )
        try observeBinary(
            segment,
            name: "danmaku-segment",
            maximumSize: Self.danmakuSegmentLimit
        )
    }

    private func request(
        path: String,
        queryItems: [URLQueryItem],
        accept: String,
        referer: String
    ) async throws -> HTTPResponse {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.bilibili.com"
        components.path = path
        components.queryItems = queryItems
        guard let url = components.url else { throw ProbeError.invalidRequest }
        return try await transport.send(
            HTTPRequest(
                url: url,
                headers: [
                    "Accept": accept,
                    "Referer": referer,
                    "User-Agent": "BiliKitMac-M4ContractProbe/0.1",
                ]
            )
        )
    }

    private func observeCatalog(_ response: HTTPResponse) throws {
        guard response.statusCode == 200 else { throw ProbeError.unexpectedStatus }
        guard response.body.count <= Self.catalogLimit else {
            throw ProbeError.responseTooLarge
        }
        guard contentType(response).contains("json") else {
            throw ProbeError.unexpectedContentType
        }
        guard let envelope = try JSONSerialization.jsonObject(
            with: response.body
        ) as? [String: Any],
              envelope["code"] as? Int == 0,
              let data = envelope["data"] as? [String: Any],
              let subtitle = data["subtitle"] as? [String: Any],
              let tracks = subtitle["subtitles"] as? [[String: Any]]
        else {
            throw ProbeError.invalidJSONShape
        }
        let fields = tracks.first.map { $0.keys.sorted().joined(separator: ",") }
            ?? "none"
        let needsLogin = data["need_login_subtitle"] as? Bool ?? false
        print(
            "contract=subtitle-catalog status=200 content-type=json "
                + "bytes=\(response.body.count) tracks=\(tracks.count) "
                + "needs-login=\(needsLogin) track-fields=\(fields)"
        )
    }

    private func observeBinary(
        _ response: HTTPResponse,
        name: String,
        maximumSize: Int
    ) throws {
        guard response.statusCode == 200 else { throw ProbeError.unexpectedStatus }
        guard !response.body.isEmpty else { throw ProbeError.emptyResponse }
        guard response.body.count <= maximumSize else {
            throw ProbeError.responseTooLarge
        }
        guard contentType(response).contains("application/octet-stream") else {
            throw ProbeError.unexpectedContentType
        }
        guard (try? JSONSerialization.jsonObject(with: response.body)) == nil,
              !looksLikeHTML(response.body)
        else {
            throw ProbeError.unexpectedBodyClass
        }
        print(
            "contract=\(name) status=200 content-type=octet-stream "
                + "bytes=\(response.body.count) body-class=binary"
        )
    }

    private func contentType(_ response: HTTPResponse) -> String {
        response.headers.first(where: {
            $0.key.caseInsensitiveCompare("Content-Type") == .orderedSame
        })?.value.lowercased() ?? ""
    }

    private func looksLikeHTML(_ data: Data) -> Bool {
        let prefix = String(decoding: data.prefix(256), as: UTF8.self).lowercased()
        return prefix.contains("<html") || prefix.contains("<!doctype")
    }
}

private enum ProbeError: String, Error {
    case invalidRequest = "invalid-request"
    case unexpectedStatus = "unexpected-status"
    case responseTooLarge = "response-too-large"
    case unexpectedContentType = "unexpected-content-type"
    case invalidJSONShape = "invalid-json-shape"
    case emptyResponse = "empty-response"
    case unexpectedBodyClass = "unexpected-body-class"
}

private struct Configuration {
    enum Mode {
        case search(keyword: String, page: Int)
        case m4Contract(bvid: String, cid: Int64)
    }

    let mode: Mode

    init(arguments: [String]) throws {
        let arguments = Array(arguments.dropFirst())
        if arguments.first == "--m4-contract" {
            let values = try Self.values(from: Array(arguments.dropFirst()))
            guard values.count == 2,
                  let bvid = values["--bvid"],
                  Self.isValidBVID(bvid),
                  let rawCID = values["--cid"],
                  let cid = Int64(rawCID),
                  cid > 0
            else {
                throw ProbeError.invalidRequest
            }
            mode = .m4Contract(bvid: bvid, cid: cid)
            return
        }

        let values = try Self.values(from: arguments)
        guard values.count <= 2,
              let keyword = values["--search"]?.trimmingCharacters(
                  in: .whitespacesAndNewlines
              ),
              !keyword.isEmpty,
              let page = Int(values["--page"] ?? "1"),
              page > 0
        else {
            throw ProbeError.invalidRequest
        }
        mode = .search(keyword: keyword, page: page)
    }

    private static func values(from arguments: [String]) throws -> [String: String] {
        guard arguments.count.isMultiple(of: 2) else {
            throw ProbeError.invalidRequest
        }
        var values: [String: String] = [:]
        var index = 0
        while index < arguments.count {
            let name = arguments[index]
            guard name.hasPrefix("--"), values[name] == nil else {
                throw ProbeError.invalidRequest
            }
            values[name] = arguments[index + 1]
            index += 2
        }
        return values
    }

    private static func isValidBVID(_ value: String) -> Bool {
        value.count == 12
            && value.hasPrefix("BV")
            && value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }
}
