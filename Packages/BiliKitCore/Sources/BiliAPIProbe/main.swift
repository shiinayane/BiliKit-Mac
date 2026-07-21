import BiliAPI
import BiliNetworking
import Foundation

@main
struct BiliAPIProbe {
    static func main() async {
        do {
            let configuration = try Configuration(arguments: CommandLine.arguments)
            let page = try await BiliAPIClient(
                transport: ProbeTransport()
            ).searchVideos(
                keyword: configuration.keyword,
                page: configuration.page
            )
            print(
                "search: page=\(page.pageNumber) count=\(page.videos.count) total=\(page.totalResults)"
            )
            if let first = page.videos.first {
                print(
                    "first: bvid=\(first.bvid) duration=\(first.durationSeconds ?? 0)s"
                )
            }
            print("RESULT: PASS")
        } catch let error as BiliAPIError {
            writeError("BiliAPIProbe failed: \(error.description)\n")
            exit(EXIT_FAILURE)
        } catch {
            writeError(
                "BiliAPIProbe failed: \(String(reflecting: type(of: error)))\n"
            )
            exit(EXIT_FAILURE)
        }
    }

    private static func writeError(_ message: String) {
        FileHandle.standardError.write(Data(message.utf8))
    }
}

private actor ProbeTransport: HTTPTransport {
    private let transport = URLSessionTransport()

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let response = try await transport.send(request)
        print(
            "request: path=\(request.url.path) status=\(response.statusCode) bytes=\(response.body.count)"
        )
        return response
    }
}

private struct Configuration {
    let keyword: String
    let page: Int

    init(arguments: [String]) throws {
        var values: [String: String] = [:]
        var index = 1
        while index < arguments.count {
            guard arguments[index].hasPrefix("--"), index + 1 < arguments.count else {
                throw BiliAPIError.invalidRequest
            }
            values[arguments[index]] = arguments[index + 1]
            index += 2
        }
        guard let keyword = values["--search"]?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ),
              !keyword.isEmpty,
              let page = Int(values["--page"] ?? "1"),
              page > 0
        else {
            throw BiliAPIError.invalidRequest
        }
        self.keyword = keyword
        self.page = page
    }
}
