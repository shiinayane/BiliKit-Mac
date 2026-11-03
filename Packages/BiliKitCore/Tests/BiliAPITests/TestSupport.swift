import BiliAPI
import BiliModels
import BiliNetworking
import Foundation
import Synchronization
import Testing

// BiliAPITests 共用的 fixture 读取、HTTP 测试替身与评论结果的取值帮手：
// 每个 port 在本 target 内只保留一份可配置 stub。

func fixtureResponse(
    _ name: String,
    extension fileExtension: String = "json",
    contentType: String = "application/json; charset=utf-8"
) throws -> HTTPResponse {
    let url = try #require(
        Bundle.module.url(
            forResource: name,
            withExtension: fileExtension,
            subdirectory: "Fixtures"
        )
    )
    return HTTPResponse(
        statusCode: 200,
        headers: ["Content-Type": contentType],
        body: try Data(contentsOf: url)
    )
}

/// 把十六进制文本 fixture 还原为 protobuf 正文。
func hexFixtureResponse(_ name: String) throws -> HTTPResponse {
    let text = try fixtureResponse(name, extension: "hex").body
    let digits = String(decoding: text, as: UTF8.self).filter(\.isHexDigit)
    var body = Data()
    var index = digits.startIndex
    while index < digits.endIndex {
        let next = digits.index(index, offsetBy: 2)
        body.append(try #require(UInt8(digits[index..<next], radix: 16)))
        index = next
    }
    return HTTPResponse(
        statusCode: 200,
        headers: ["Content-Type": "application/octet-stream"],
        body: body
    )
}

func jsonResponse(_ source: String, statusCode: Int = 200) -> HTTPResponse {
    HTTPResponse(
        statusCode: statusCode,
        headers: ["Content-Type": "application/json"],
        body: Data(source.utf8)
    )
}

/// 以 2xx 返回的 HTML 风控页；各域都应视为请求受限，而不是解析失败。
func htmlRiskControlResponse() -> HTTPResponse {
    HTTPResponse(
        statusCode: 200,
        headers: ["Content-Type": "text/html; charset=utf-8"],
        body: Data("<!doctype html><title>fixture</title>".utf8)
    )
}

/// 字幕目录 fixture：主机是占位域名，换成允许的字幕来源后才能完成目录解析。
func allowedSubtitleCatalogResponse() throws -> HTTPResponse {
    let fixture = try fixtureResponse("subtitle-catalog")
    let source = String(decoding: fixture.body, as: UTF8.self)
        .replacingOccurrences(of: "subtitle.example.invalid", with: "aisubtitle.hdslb.com")
    return HTTPResponse(
        statusCode: fixture.statusCode,
        headers: fixture.headers,
        body: Data(source.utf8)
    )
}

/// 修改 fixture 顶层 `data` 对象后重新编码，保持其余字段不变。
func mutatedFixture(
    _ name: String,
    mutate: (inout [String: Any]) throws -> Void
) throws -> HTTPResponse {
    let fixture = try fixtureResponse(name)
    var root = try #require(
        JSONSerialization.jsonObject(with: fixture.body) as? [String: Any]
    )
    var data = try #require(root["data"] as? [String: Any])
    try mutate(&data)
    root["data"] = data
    return HTTPResponse(
        statusCode: fixture.statusCode,
        headers: fixture.headers,
        body: try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
    )
}

/// 按顺序回放 reply 并记录请求；可挂起一次请求，也记录 invalidate。
///
/// `answersWBINavOnce` 开启时，第一个 WBI key 的 nav 请求直接得到 nav fixture，不消费顺序队列，
/// 但照常记录（`waitForRequests` 的计数也包含它）。之后再取 nav 记为测试失败并按无响应抛错：
/// 同一 client 的多个签名请求必须复用 key，多取 nav 就是风控要避免的请求放大。
/// 只把 nav 当作签名前置的测试用它；验证 WBI key 取用、刷新、顺序或匿名性的测试仍显式排 nav。
final class StubTransport: HTTPTransport, HTTPTransportInvalidating, Sendable {
    enum Reply: Sendable {
        case response(HTTPResponse)
        /// 挂起到 `resumeSuspendedRequest()`；等待期间任务取消则抛出 `CancellationError`。
        case suspended(HTTPResponse)
        /// 返回响应前取消调用方任务。
        case cancellingCaller(HTTPResponse)
        case cancellation
    }

    private enum Gate {
        case closed
        case open
        case waiting(CheckedContinuation<Void, any Error>)
    }

    private struct State {
        var answeredWBINav = false
        var replies: [Reply]
        var requests: [HTTPRequest] = []
        var requestWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
        var gate = Gate.closed
        var invalidated = false
    }

    static let wbiNavPath = "/x/web-interface/nav"

    private let answersWBINavOnce: Bool
    private let state: Mutex<State>

    init(_ replies: [Reply], answersWBINavOnce: Bool = false) {
        state = Mutex(State(replies: replies))
        self.answersWBINavOnce = answersWBINavOnce
    }

    convenience init(responses: [HTTPResponse], answersWBINavOnce: Bool = false) {
        self.init(responses.map(Reply.response), answersWBINavOnce: answersWBINavOnce)
    }

    var wasInvalidated: Bool { state.withLock { $0.invalidated } }

    func capturedRequests() -> [HTTPRequest] { state.withLock { $0.requests } }

    /// 去掉 WBI key 的 nav 请求，只留下业务请求。
    func businessRequests() -> [HTTPRequest] {
        capturedRequests().filter { $0.url.path != Self.wbiNavPath }
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let isAutoAnsweredNav = answersWBINavOnce && request.url.path == Self.wbiNavPath
        let (reply, isRepeatedNav, ready) = state.withLock { state in
            state.requests.append(request)
            let count = state.requests.count
            let ready = state.requestWaiters.filter { $0.count <= count }.map(\.continuation)
            state.requestWaiters.removeAll { $0.count <= count }
            let isRepeatedNav = isAutoAnsweredNav && state.answeredWBINav
            state.answeredWBINav = state.answeredWBINav || isAutoAnsweredNav
            let reply =
                isAutoAnsweredNav || state.replies.isEmpty ? nil : state.replies.removeFirst()
            return (reply, isRepeatedNav, ready)
        }
        for waiter in ready { waiter.resume() }
        if isRepeatedNav {
            Issue.record("同一 transport 上再次请求了 WBI nav")
            throw StubTransportError.noReply
        }
        if isAutoAnsweredNav {
            return try fixtureResponse("nav")
        }
        switch reply {
        case nil:
            throw StubTransportError.noReply
        case .response(let response):
            return response
        case .cancellation:
            throw CancellationError()
        case .cancellingCaller(let response):
            withUnsafeCurrentTask { $0?.cancel() }
            return response
        case .suspended(let response):
            try await waitForGate()
            return response
        }
    }

    func invalidateAndCancel() {
        state.withLock { $0.invalidated = true }
    }

    func waitForRequests(_ count: Int) async {
        await withCheckedContinuation { continuation in
            let isReady = state.withLock { state in
                guard state.requests.count < count else { return true }
                state.requestWaiters.append((count, continuation))
                return false
            }
            if isReady { continuation.resume() }
        }
    }

    func resumeSuspendedRequest() {
        let waiting: CheckedContinuation<Void, any Error>? = state.withLock { state in
            defer { state.gate = .open }
            guard case .waiting(let continuation) = state.gate else { return nil }
            return continuation
        }
        waiting?.resume()
    }

    private func waitForGate() async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let result: Result<Void, any Error>? = state.withLock { state in
                    if case .open = state.gate { return .success(()) }
                    if Task.isCancelled { return .failure(CancellationError()) }
                    state.gate = .waiting(continuation)
                    return nil
                }
                if let result { continuation.resume(with: result) }
            }
        } onCancel: {
            let waiting: CheckedContinuation<Void, any Error>? = state.withLock { state in
                guard case .waiting(let continuation) = state.gate else { return nil }
                state.gate = .closed
                return continuation
            }
            waiting?.resume(throwing: CancellationError())
        }
    }
}

enum StubTransportError: Error {
    case noReply
}

extension BiliAPIClient {
    /// 只用一个 stub transport 的 client：认证会话失效时 invalidate 这个 stub 后继续沿用它。
    ///
    /// 验证失效后换入新 transport 的测试直接传 `transportFactory`。
    init(
        transport: any HTTPTransport,
        requestAuthorizer: (any HTTPRequestAuthorizing)? = nil,
        historyWriteAuthorizer: (any HTTPRequestAuthorizing)? = nil,
        accountWriteAuthorizer: (any HTTPSubjectBoundRequestAuthorizing)? = nil,
        timestampProvider: @escaping @Sendable () -> Int64 = {
            Int64(Date().timeIntervalSince1970)
        }
    ) {
        self.init(
            requestAuthorizer: requestAuthorizer,
            historyWriteAuthorizer: historyWriteAuthorizer,
            accountWriteAuthorizer: accountWriteAuthorizer,
            transportFactory: { transport },
            timestampProvider: timestampProvider
        )
    }
}

/// 按调用次序给出授权结果（最后一项重复）并记录请求；可挂起第 N 次授权。
actor StubAuthorizer: HTTPRequestAuthorizing {
    enum Outcome: Sendable {
        case authorize
        case fail(HTTPRequestAuthorizationFailureKind)
    }

    static let cookie = "FIXTURE_AUTHORIZED"

    private let outcomes: [Outcome]
    private let suspendingCall: Int?
    private var requests: [HTTPRequest] = []
    private var reachedSuspension = false
    private var resumed = false
    private var suspensionWaiters: [CheckedContinuation<Void, Never>] = []
    private var suspension: CheckedContinuation<Void, Never>?

    init(_ outcomes: Outcome..., suspendingCall: Int? = nil) {
        self.init(outcomes: outcomes, suspendingCall: suspendingCall)
    }

    init(outcomes: [Outcome], suspendingCall: Int? = nil) {
        self.outcomes = outcomes.isEmpty ? [.authorize] : outcomes
        self.suspendingCall = suspendingCall
    }

    var authorizationCount: Int { requests.count }

    func capturedRequests() -> [HTTPRequest] { requests }

    func capturedPaths() -> [String] { requests.map(\.url.path) }

    func authorize(_ request: HTTPRequest) async throws -> HTTPRequest {
        requests.append(request)
        let call = requests.count
        if call == suspendingCall {
            reachedSuspension = true
            for waiter in suspensionWaiters { waiter.resume() }
            suspensionWaiters.removeAll()
            if !resumed {
                await withCheckedContinuation { suspension = $0 }
            }
        }
        switch outcomes[min(call, outcomes.count) - 1] {
        case .fail(let kind):
            throw StubAuthorizationFailure(authorizationFailureKind: kind)
        case .authorize:
            var headers = request.headers
            headers["Cookie"] = Self.cookie
            return HTTPRequest(
                url: request.url,
                method: request.method,
                headers: headers,
                body: request.body
            )
        }
    }

    func waitUntilSuspended() async {
        guard !reachedSuspension else { return }
        await withCheckedContinuation { suspensionWaiters.append($0) }
    }

    func resume() {
        resumed = true
        suspension?.resume()
        suspension = nil
    }
}

/// 账户写授权器的替身：记录每次授权的请求与绑定的主体，结果与挂起规则同 `StubAuthorizer`（委托给它）。
actor StubSubjectBoundAuthorizer: HTTPSubjectBoundRequestAuthorizing {
    private let base: StubAuthorizer
    private(set) var subjects: [String] = []

    init(_ outcomes: StubAuthorizer.Outcome..., suspendingCall: Int? = nil) {
        base = StubAuthorizer(outcomes: outcomes, suspendingCall: suspendingCall)
    }

    func capturedRequests() async -> [HTTPRequest] { await base.capturedRequests() }

    func authorize(_ request: HTTPRequest, boundTo subject: String) async throws -> HTTPRequest {
        subjects.append(subject)
        return try await base.authorize(request)
    }

    func waitUntilSuspended() async { await base.waitUntilSuspended() }

    func resume() async { await base.resume() }
}

struct StubAuthorizationFailure: HTTPRequestAuthorizationFailure {
    let authorizationFailureKind: HTTPRequestAuthorizationFailureKind
}

/// 评论可读时取出正文与作者；不可读的标记返回 nil。
func available(_ comment: BiliModels.Comment) -> CommentDetails? {
    guard case .available(let details) = comment.payload else { return nil }
    return details
}

/// 按顺序交出预先准备的 transport：认证会话失效后 client 换入下一个，测试据此确认旧 transport
/// 被 invalidate、新 transport 没有收到旧请求；取用次数超过准备的数量即为测试错误。
final class SequentialTransportFactory: Sendable {
    private let transports: Mutex<[any HTTPTransport]>

    init(transports: [any HTTPTransport]) {
        self.transports = Mutex(transports)
    }

    func makeTransport() -> any HTTPTransport {
        transports.withLock { transports in
            precondition(!transports.isEmpty)
            return transports.removeFirst()
        }
    }
}

/// 发出的 urlencoded 表单体按字段名展开；写入请求的测试据此核对字段，不依赖字段顺序。
func formFields(_ request: HTTPRequest) -> [String: String] {
    var components = URLComponents()
    components.percentEncodedQuery = request.body.flatMap { String(data: $0, encoding: .utf8) }
    return fields(components.queryItems)
}

/// 请求 URL 的查询参数按字段名展开。
func queryFields(_ request: HTTPRequest) -> [String: String] {
    fields(URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems)
}

private func fields(_ items: [URLQueryItem]?) -> [String: String] {
    Dictionary(uniqueKeysWithValues: (items ?? []).map { ($0.name, $0.value ?? "") })
}
