import Foundation
import Synchronization

/// 传输层允许的 HTTP 方法。
///
/// `POST` 只用于网页端写授权器放行的写请求（观看进度 heartbeat 与用户发起的账户写入）与 BiliAuth 发往 passport 的
/// 扫码取码、轮询和续期，`HEAD` 只用于 b23.tv 短链解析（见 SECURITY-MODEL §2–§4）。
public enum HTTPMethod: String, Sendable {
    case get = "GET"
    case head = "HEAD"
    case post = "POST"
}

/// 与业务无关的不可变请求值；header 只含调用方显式写入的内容，凭据由授权器另行生成新请求附加。
public struct HTTPRequest: Sendable, Equatable {
    public let url: URL
    public let method: HTTPMethod
    public let headers: [String: String]
    public let body: Data?

    public init(
        url: URL,
        method: HTTPMethod = .get,
        headers: [String: String] = [:],
        body: Data? = nil
    ) {
        self.url = url
        self.method = method
        self.headers = headers
        self.body = body
    }
}

extension HTTPResponse {
    /// 按 HTTP 规则不区分大小写地取响应头；响应侧读取单个头都经这里。
    ///
    /// `headers` 保留 transport 交来的原样键，需要整张表的调用方直接用它。
    public func headerValue(_ name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    /// 解码前拒绝 HTML 风控页等非 JSON 响应：Content-Type 必须声明 JSON，正文须以对象（或允许时数组）开头。
    public func looksLikeJSON(allowsTopLevelArray: Bool = false) -> Bool {
        guard
            let contentType = headerValue("Content-Type")?.lowercased(),
            contentType.contains("json"),
            let firstByte = body.first(where: { ![9, 10, 13, 32].contains($0) })
        else {
            return false
        }
        return firstByte == 0x7B || (allowsTopLevelArray && firstByte == 0x5B)
    }
}

/// 传输层返回的状态码、header 与完整正文；状态、来源与大小的判定交给 `HTTPClient` 与各调用方。
public struct HTTPResponse: Sendable, Equatable {
    public let statusCode: Int
    public let headers: [String: String]
    public let body: Data

    public init(
        statusCode: Int,
        headers: [String: String] = [:],
        body: Data
    ) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
    }
}

/// 不包含业务或认证语义的 HTTP 传输边界，便于按用途注入独立 session。
public protocol HTTPTransport: Sendable {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse
}

/// 可以立即取消在途请求并作废 session 的 transport。
///
/// 持有 transport 的一方（API client、授权器、QR 会话、短链解析）在会话失效、登出或关窗时调用；
/// 可以与已取出这个 transport 的请求并发。失效后的 `send` 不再发出请求，与被打断的在途请求一样以
/// `URLError(.cancelled)` 结束；API client 随即换入新 transport。
public protocol HTTPTransportInvalidating: Sendable {
    func invalidateAndCancel()
}

/// 传输层的通用失败：响应不是 HTTP，或状态码不在调用方接受的范围内。
public enum HTTPClientError: Error, Sendable, Equatable {
    case nonHTTPResponse
    case unacceptableStatusCode(Int)
}

/// 只统一成功状态检查的轻量 client；来源、大小、Content-Type 与解码限制仍由调用方负责。
public actor HTTPClient {
    private let transport: any HTTPTransport

    public init(transport: any HTTPTransport) {
        self.transport = transport
    }

    public func send(
        _ request: HTTPRequest,
        accepting acceptedStatusCodes: Range<Int> = 200..<300
    ) async throws -> HTTPResponse {
        let response = try await transport.send(request)
        guard acceptedStatusCodes.contains(response.statusCode) else {
            throw HTTPClientError.unacceptableStatusCode(response.statusCode)
        }
        return response
    }
}

extension URLSessionConfiguration {
    /// 交互式请求（API JSON、认证、字幕正文、图片）的超时：15 秒无数据或 30 秒未完成即按网络失败处理，
    /// 让界面及时显示可重试的错误或占位；调大会让失败更晚出现，调小会让弱网下的大列表、大图或大字幕
    /// 被误判失败。
    static let interactiveRequestTimeout: TimeInterval = 15
    static let interactiveResourceTimeout: TimeInterval = 30

    /// API、认证、媒体、字幕、短链与图片 session 唯一的 ephemeral 基线：不自动附加 Cookie，没有 Cookie、
    /// 凭据与 URL cache（见 SECURITY-MODEL §4）。
    ///
    /// 默认使用交互式请求超时；只有用途确实不同的调用方（测速、媒体流、短链）覆盖超时，并在自己那里
    /// 写明理由。调用方不得重新打开 Cookie、凭据或缓存；持有 session 的一方都以 delegate 拒绝 redirect。
    /// 需要账户凭据的请求只由授权器显式写入 header。
    public static func credentialFreeEphemeral() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = interactiveRequestTimeout
        configuration.timeoutIntervalForResource = interactiveResourceTimeout
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return configuration
    }
}

/// `URLSession` adapter：按调用方给出的用途专属配置自建并拥有 session，一律拒绝跟随重定向。
///
/// 来源校验只作用于发出的 URL，跟随重定向会绕过它，所以没有可跟随的选项（见 SECURITY-MODEL §4）；
/// 也没有回落到 `URLSession.shared` 的入口（见 §1）。
///
/// owner 是构造它的一方（API client、授权器、QR 会话、短链解析、字幕正文）。`invalidateAndCancel()` 立即取消
/// 在途请求并永久关闭 session；transport 释放时让 session 完成在途任务后失效，session 与 delegate 随之释放。
/// 在已失效的 session 上建 task 会抛 Objective-C 异常直接终止进程，而持有方失效 transport 与另一个 actor 上
/// 已取出它的请求并发（例如 `BiliAPIClient` 换号时）。所以失效标记由 `isInvalidated` 这把 `Mutex` 保护：
/// 建 task 并 `resume()` 与“置位并失效 session”都在锁内完成，两者严格先后；失效之后的 `send` 不建 task，
/// 与在途请求被失效打断一样以 `URLError(.cancelled)` 结束。
public final class URLSessionTransport: HTTPTransport, HTTPTransportInvalidating, Sendable {
    private let session: URLSession
    private let isInvalidated = Mutex(false)

    public convenience init(configuration: URLSessionConfiguration) {
        self.init(
            session: URLSession(
                configuration: configuration,
                delegate: RejectHTTPRedirectDelegate(),
                delegateQueue: nil
            )
        )
    }

    /// 接管 `session` 的生命周期：transport 释放时让它失效。
    init(session: URLSession) {
        self.session = session
    }

    deinit {
        // 已被 `invalidateAndCancel` 失效的 session 再次失效是 no-op；释放时不可能还有并发的 `send`，不需要闸门。
        session.finishTasksAndInvalidate()
    }

    /// 调用方 Task 被取消时抛 `CancellationError`；transport 失效（在途被打断或失效后才发）而调用方没被取消时抛
    /// `URLError(.cancelled)`；其余失败原样抛出 URLSession 的错误。
    ///
    /// 两种取消刻意区分：页面对 `CancellationError` 不做任何事，而失效打断的是页面仍在等的请求，要按传输失败
    /// 报告（`BiliAPIClient` 映射为可重试的失败；需要认证的请求另由 epoch 比对改判为取消，交给账户变化的重载）。
    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method.rawValue
        urlRequest.httpBody = request.body
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }

        try Task.checkCancellation()
        // 每次请求一个 OneShotResult，唯一等待方是下面的 `value()`。
        let outcome = OneShotResult<HTTPResponse>()
        let task = try isInvalidated.withLock { isInvalidated in
            guard !isInvalidated else { throw URLError(.cancelled) }
            let task = session.dataTask(with: urlRequest) { data, response, error in
                outcome.resolve(Self.result(data: data, response: response, error: error))
            }
            task.resume()
            return task
        }
        // task 在装上取消处理之前已经存在：调用方此前或此后取消，`onCancel` 都能拿到它。
        do {
            return try await withTaskCancellationHandler {
                try await outcome.value()
            } onCancel: {
                task.cancel()
            }
        } catch let error as URLError where error.code == .cancelled && Task.isCancelled {
            // URLSession 对两种取消都报 `.cancelled`；只有调用方自己被取消时才改成 `CancellationError`。
            throw CancellationError()
        }
    }

    public func invalidateAndCancel() {
        isInvalidated.withLock { isInvalidated in
            guard !isInvalidated else { return }
            isInvalidated = true
            session.invalidateAndCancel()
        }
    }

    private static func result(
        data: Data?,
        response: URLResponse?,
        error: (any Error)?
    ) -> Result<HTTPResponse, any Error> {
        if let error {
            return .failure(error)
        }
        guard let httpResponse = response as? HTTPURLResponse else {
            return .failure(HTTPClientError.nonHTTPResponse)
        }
        let headers = httpResponse.allHeaderFields.reduce(
            into: [String: String](),
            { result, entry in
                result[String(describing: entry.key)] = String(describing: entry.value)
            }
        )
        return .success(
            HTTPResponse(
                statusCode: httpResponse.statusCode,
                headers: headers,
                body: data ?? Data()
            )
        )
    }
}

/// 拒绝一切 redirect 的 session delegate：跳转目标不经来源校验，见 SECURITY-MODEL §4。
final class RejectHTTPRedirectDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
