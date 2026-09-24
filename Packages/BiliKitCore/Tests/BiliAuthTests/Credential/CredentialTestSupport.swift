import BiliNetworking
import Foundation
import Synchronization

@testable import BiliAuth

func makeFixtureCredential(
    expiresAt: Date = Date(timeIntervalSince1970: 4_102_444_800)
) throws -> WebCredential {
    try WebCredential(
        cookies: WebCredentialCookieName.allCases.map { name in
            WebCredentialCookie(
                name: name,
                value: "FIXTURE_\(name.rawValue)_VALUE",
                domain: ".bilibili.com",
                path: "/",
                isSecure: true,
                isHTTPOnly: name == .session,
                expiresAt: expiresAt
            )
        }
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

/// 本 target 唯一的 `WebCredentialStoring` 替身；load/save/delete 错误只触发一次。
final class MemoryWebCredentialStore: WebCredentialStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var credential: WebCredential?
    private var nextLoadError: (any Error)?
    private var nextSaveError: (any Error)?
    private var nextDeleteError: (any Error)?
    private let events: AuthEventRecorder?
    private(set) var deleteCount = 0
    private(set) var saveCount = 0

    init(
        credential: WebCredential? = nil,
        loadError: (any Error)? = nil,
        saveError: (any Error)? = nil,
        deleteError: (any Error)? = nil,
        events: AuthEventRecorder? = nil
    ) {
        self.credential = credential
        nextLoadError = loadError
        nextSaveError = saveError
        nextDeleteError = deleteError
        self.events = events
    }

    func load() throws -> WebCredential? {
        try lock.withLock {
            if let nextLoadError {
                self.nextLoadError = nil
                throw nextLoadError
            }
            return credential
        }
    }

    func save(_ credential: WebCredential) throws {
        try lock.withLock {
            if let nextSaveError {
                self.nextSaveError = nil
                throw nextSaveError
            }
            self.credential = credential
            saveCount += 1
        }
    }

    func delete() throws {
        try lock.withLock {
            if let nextDeleteError {
                self.nextDeleteError = nil
                events?.append("credential-delete-failed")
                throw nextDeleteError
            }
            credential = nil
            deleteCount += 1
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
        for waiter in arrivalWaiters {
            waiter.resume()
        }
        arrivalWaiters.removeAll()
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

enum StubAuthError: Error {
    case offline
    case missingResponse
    case storeUnavailable
}

func navigationResponse(
    isLogin: Bool,
    includesIdentity: Bool = false
) -> HTTPResponse {
    let identityFields =
        includesIdentity
        ? ",\"mid\":42,\"uname\":\"  Fixture Account  \""
            + ",\"face\":\"//i0.hdslb.com/fixture/avatar.png\""
        : ""
    return HTTPResponse(
        statusCode: 200,
        headers: ["Content-Type": "application/json"],
        body: Data(
            "{\"code\":0,\"data\":{\"isLogin\":\(isLogin)\(identityFields)}}".utf8
        )
    )
}
