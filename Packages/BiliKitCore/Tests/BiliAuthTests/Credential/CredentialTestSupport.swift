import BiliApplication
import BiliNetworking
import Foundation
import Synchronization

@testable import BiliAuth

/// `userID` 给出时 `DedeUserID` 用这个数字（账户写入按它绑定账户），否则与其他 Cookie 一样是占位值。
func makeFixtureCredential(
    expiresAt: Date = Date(timeIntervalSince1970: 4_102_444_800),
    userID: String? = nil
) throws -> AccountCredential {
    try AccountCredential(
        cookies: WebCredentialCookieName.allCases.map { name in
            WebCredentialCookie(
                name: name,
                value: name == .userID
                    ? userID ?? "FIXTURE_\(name.rawValue)_VALUE"
                    : "FIXTURE_\(name.rawValue)_VALUE",
                domain: ".bilibili.com",
                path: "/",
                isSecure: true,
                isHTTPOnly: name == .session,
                expiresAt: expiresAt
            )
        },
        appAccessToken: AppAccessToken(
            value: fixtureAppAccessTokenValue,
            refreshToken: fixtureAppRefreshTokenValue,
            expiresAt: expiresAt
        )
    )
}

/// 测试凭据的 access_token：32 个 `f`，满足十六进制形状，也是秘密扫描放行的假值。
let fixtureAppAccessTokenValue = String(repeating: "f", count: 32)
/// 测试凭据的 refresh_token：32 个 `0`，理由同上。
let fixtureAppRefreshTokenValue = String(repeating: "0", count: 32)

/// 账户会话校验（nav）授权器放行的 path；本 target 的读授权器测试与认证服务测试共用。
let navigationAllowedPaths: Set<String> = [
    "/x/web-interface/nav"
]

/// 本 target 唯一的读授权器组装：默认只放行 nav，transport 不回放任何响应。
func makeCredentialAuthorizer(
    store: MemoryAccountCredentialStore,
    allowedPaths: Set<String> = navigationAllowedPaths,
    transport: RecordingAuthTransport = RecordingAuthTransport(),
    isConfirmedSignedOut: @escaping @Sendable () -> Bool = { false }
) -> BiliCredentialRequestAuthorizer {
    BiliCredentialRequestAuthorizer(
        store: store,
        allowedPaths: allowedPaths,
        transport: transport,
        isConfirmedSignedOut: isConfirmedSignedOut
    )
}

/// 按发生顺序记录登出链路中的删除与失效事件。
final class AuthEventRecorder: Sendable {
    private let storage = Mutex<[String]>([])

    func append(_ event: String) {
        storage.withLock { $0.append(event) }
    }

    func values() -> [String] {
        storage.withLock { $0 }
    }
}

/// 本 target 唯一的 `AccountCredentialStoring` 替身；load/save/delete 错误只触发一次。
final class MemoryAccountCredentialStore: AccountCredentialStoring, Sendable {
    private struct State {
        var credential: AccountCredential?
        var nextLoadError: (any Error)?
        var nextSaveError: (any Error)?
        var nextDeleteError: (any Error)?
        var deleteCount = 0
        var saveCount = 0
    }

    private let state: Mutex<State>
    private let events: AuthEventRecorder?

    var deleteCount: Int { state.withLock { $0.deleteCount } }
    var saveCount: Int { state.withLock { $0.saveCount } }

    init(
        credential: AccountCredential? = nil,
        loadError: (any Error)? = nil,
        saveError: (any Error)? = nil,
        deleteError: (any Error)? = nil,
        events: AuthEventRecorder? = nil
    ) {
        state = Mutex(
            State(
                credential: credential,
                nextLoadError: loadError,
                nextSaveError: saveError,
                nextDeleteError: deleteError
            )
        )
        self.events = events
    }

    func load() throws -> AccountCredential? {
        try state.withLock { state in
            if let nextLoadError = state.nextLoadError {
                state.nextLoadError = nil
                throw nextLoadError
            }
            return state.credential
        }
    }

    func save(_ credential: AccountCredential) throws {
        try state.withLock { state in
            if let nextSaveError = state.nextSaveError {
                state.nextSaveError = nil
                throw nextSaveError
            }
            state.credential = credential
            state.saveCount += 1
        }
    }

    func delete() throws {
        try state.withLock { state in
            if let nextDeleteError = state.nextDeleteError {
                state.nextDeleteError = nil
                events?.append("credential-delete-failed")
                throw nextDeleteError
            }
            state.credential = nil
            state.deleteCount += 1
            events?.append("credential-deleted")
        }
    }
}

/// 本 target 唯一的 `HTTPTransport` 替身：按顺序回放响应或错误并记录请求。
///
/// `suspendingRequest` 指定的第 N 个请求在发出时取走自己的结果，然后挂起到
/// `resumeSuspendedRequest()` 或所属 Task 被取消；`waitForSuspendedRequest()` 用 continuation
/// 等它到达，不轮询。`invalidationEvent` 让 `invalidateAndCancel()` 写入事件记录。
actor RecordingAuthTransport: HTTPTransport, HTTPTransportInvalidating {
    private var queuedResponses: [HTTPResponse]
    private var queuedErrors: [any Error]
    private let suspendingRequest: Int?
    private let invalidationEvent: (recorder: AuthEventRecorder, name: String)?
    private(set) var requests: [HTTPRequest] = []
    private(set) var suspendedRequestWasCancelled = false
    private var suspendedRequestArrived = false
    private var suspendedRequestCancelled = false
    private var arrivalWaiters: [CheckedContinuation<Void, Never>] = []
    private var suspension: CheckedContinuation<Bool, Never>?

    init(
        responses: [HTTPResponse] = [],
        errors: [any Error] = [],
        suspendingRequest: Int? = nil,
        invalidationEvent: (recorder: AuthEventRecorder, name: String)? = nil
    ) {
        queuedResponses = responses
        queuedErrors = errors
        self.suspendingRequest = suspendingRequest
        self.invalidationEvent = invalidationEvent
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        requests.append(request)
        let outcome = nextOutcome()
        guard requests.count == suspendingRequest else {
            return try outcome.get()
        }

        suspendedRequestArrived = true
        arrivalWaiters.resumeAll()
        let resumed = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if suspendedRequestCancelled {
                    continuation.resume(returning: false)
                } else {
                    suspension = continuation
                }
            }
        } onCancel: {
            Task { await self.cancelSuspendedRequest() }
        }
        guard resumed else {
            suspendedRequestWasCancelled = true
            throw CancellationError()
        }
        return try outcome.get()
    }

    func waitForSuspendedRequest() async {
        guard !suspendedRequestArrived else { return }
        await withCheckedContinuation { continuation in
            arrivalWaiters.append(continuation)
        }
    }

    func resumeSuspendedRequest() {
        suspension?.resume(returning: true)
        suspension = nil
    }

    nonisolated func invalidateAndCancel() {
        guard let invalidationEvent else { return }
        invalidationEvent.recorder.append(invalidationEvent.name)
    }

    private func cancelSuspendedRequest() {
        suspendedRequestCancelled = true
        suspension?.resume(returning: false)
        suspension = nil
    }

    private func nextOutcome() -> Result<HTTPResponse, any Error> {
        if !queuedErrors.isEmpty {
            return .failure(queuedErrors.removeFirst())
        }
        guard !queuedResponses.isEmpty else {
            return .failure(StubAuthError.missingResponse)
        }
        return .success(queuedResponses.removeFirst())
    }
}

/// 本 target 唯一的 `AuthenticatedSessionInvalidating` 替身。
///
/// 每次失效向 `events`（若有）写入 `api-invalidated`；`suspends` 为 true 时失效开始后挂起到
/// `resumeInvalidation()`，`waitUntilInvalidationStarts()` 用 continuation 等它开始，不轮询。
actor RecordingSessionInvalidator: AuthenticatedSessionInvalidating {
    private let events: AuthEventRecorder?
    private let suspends: Bool
    private var started = false
    private var isResumed = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var suspended: [CheckedContinuation<Void, Never>] = []

    init(events: AuthEventRecorder? = nil, suspends: Bool = false) {
        self.events = events
        self.suspends = suspends
    }

    func invalidateAuthenticatedSession() async {
        events?.append("api-invalidated")
        started = true
        startWaiters.resumeAll()
        guard suspends, !isResumed else { return }
        await withCheckedContinuation { continuation in
            suspended.append(continuation)
        }
    }

    func waitUntilInvalidationStarts() async {
        guard !started else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func resumeInvalidation() {
        isResumed = true
        suspended.resumeAll()
    }
}

enum StubAuthError: Error {
    case offline
    case missingResponse
    case storeUnavailable
}

/// 与线上 nav 同形：未登录时 `code` 为 -101、`data.isLogin` 为 false；`code` 可显式覆盖。
func navigationResponse(
    isLogin: Bool,
    includesIdentity: Bool = false,
    code: Int? = nil
) -> HTTPResponse {
    let code = code ?? (isLogin ? 0 : -101)
    let identityFields =
        includesIdentity
        ? ",\"mid\":42,\"uname\":\"  Fixture Account  \""
            + ",\"face\":\"//i0.hdslb.com/fixture/avatar.png\""
        : ""
    return HTTPResponse(
        statusCode: 200,
        headers: ["Content-Type": "application/json"],
        body: Data(
            "{\"code\":\(code),\"data\":{\"isLogin\":\(isLogin)\(identityFields)}}".utf8
        )
    )
}

extension Array where Element == CheckedContinuation<Void, Never> {
    /// 放行并清空全部挂起者；本 target 的替身共用。
    mutating func resumeAll() {
        let pending = self
        removeAll()
        for continuation in pending {
            continuation.resume()
        }
    }
}
