import BiliNetworking
import Foundation
@preconcurrency import Network

private struct LoopbackResponseAlreadyStartedError: Error {}

public struct LoopbackRemoteResource: Sendable, Equatable {
    public let sourceURL: URL
    public let contentLength: Int64
    public let contentType: String
    public let headers: [String: String]

    public init(
        sourceURL: URL,
        contentLength: Int64,
        contentType: String,
        headers: [String: String] = [:]
    ) throws {
        guard contentLength > 0 else {
            throw LoopbackPlaybackServerError.invalidContentLength(contentLength)
        }

        self.sourceURL = sourceURL
        self.contentLength = contentLength
        self.contentType = contentType
        self.headers = headers
    }
}

/// 单个 progressive item 的来源选择状态。
///
/// 首个通过响应头验证的完整 URL 会固定给后续 Range。
public final class LoopbackProgressiveResource: @unchecked Sendable, Equatable {
    public let candidateURLs: [URL]
    public let contentLength: Int64
    public let contentType: String
    public let allowedUpstreamContentTypes: Set<String>
    public let headers: [String: String]

    private let lock = NSLock()
    private var selectedSourceURL: URL?

    public init(
        candidateURLs: [URL],
        contentLength: Int64,
        contentType: String,
        allowsOctetStreamWithContainerEvidence: Bool,
        headers: [String: String] = [:]
    ) throws {
        let mediaURLPolicy = BiliMediaCDNURLPolicy()
        guard !candidateURLs.isEmpty,
            candidateURLs.allSatisfy(mediaURLPolicy.allows)
        else {
            throw LoopbackPlaybackServerError.invalidProgressiveSource
        }
        guard contentLength > 0 else {
            throw LoopbackPlaybackServerError.invalidContentLength(contentLength)
        }
        guard contentType.caseInsensitiveCompare("video/mp4") == .orderedSame else {
            throw LoopbackPlaybackServerError.invalidProgressiveSource
        }
        self.candidateURLs = candidateURLs
        self.contentLength = contentLength
        self.contentType = contentType.lowercased()
        var allowed = Set([self.contentType])
        if allowsOctetStreamWithContainerEvidence {
            allowed.insert("application/octet-stream")
        }
        allowedUpstreamContentTypes = allowed
        self.headers = headers.filter { name, _ in
            name.caseInsensitiveCompare("Cookie") != .orderedSame
                && name.caseInsensitiveCompare("Authorization") != .orderedSame
                && name.caseInsensitiveCompare("Range") != .orderedSame
        }
    }

    public static func == (
        lhs: LoopbackProgressiveResource,
        rhs: LoopbackProgressiveResource
    ) -> Bool {
        lhs === rhs
    }

    fileprivate var eligibleSourceURLs: [URL] {
        lock.withLock {
            selectedSourceURL.map { [$0] } ?? candidateURLs
        }
    }

    fileprivate func select(_ url: URL) -> Bool {
        lock.withLock {
            if let selectedSourceURL {
                return selectedSourceURL == url
            }
            guard candidateURLs.contains(url) else { return false }
            selectedSourceURL = url
            return true
        }
    }
}

public enum LoopbackGeneratedResourceError: Error, Sendable, Equatable {
    case invalidMaximumContentLength(Int)
    case invalidMaximumLoadAttempts(Int)
    case invalidGeneratedContentLength(Int)
    case loadAttemptsExhausted
}

/// 首次请求时生成正文；成功后只缓存于当前 loopback 会话，失败可由后续请求重试。
public final class LoopbackGeneratedResource: @unchecked Sendable, Equatable {
    public let contentType: String

    private let lock = NSLock()
    private let maximumContentLength: Int
    private let loader: @Sendable () async throws -> Data
    private var generation: UInt64 = 0
    private var remainingLoadAttempts: Int
    private var invalidated = false
    private var cachedBody: Data?
    private var loadTask: Task<Data, any Error>?

    public init(
        contentType: String,
        maximumContentLength: Int,
        maximumLoadAttempts: Int = 2,
        loader: @escaping @Sendable () async throws -> Data
    ) throws {
        guard maximumContentLength > 0 else {
            throw LoopbackGeneratedResourceError.invalidMaximumContentLength(
                maximumContentLength
            )
        }
        guard maximumLoadAttempts > 0 else {
            throw LoopbackGeneratedResourceError.invalidMaximumLoadAttempts(
                maximumLoadAttempts
            )
        }
        self.contentType = contentType
        self.maximumContentLength = maximumContentLength
        self.remainingLoadAttempts = maximumLoadAttempts
        self.loader = loader
    }

    public static func == (
        lhs: LoopbackGeneratedResource,
        rhs: LoopbackGeneratedResource
    ) -> Bool {
        lhs === rhs
    }

    fileprivate func resolve() async throws -> Data {
        let pending = lock.withLock { () -> (UInt64, Task<Data, any Error>, Data?) in
            guard !invalidated else {
                return (generation, Task { throw CancellationError() }, nil)
            }
            if let cachedBody {
                let cached = cachedBody
                return (generation, Task { cached }, cached)
            }
            if let loadTask {
                return (generation, loadTask, nil)
            }
            guard remainingLoadAttempts > 0 else {
                return (
                    generation,
                    Task {
                        throw LoopbackGeneratedResourceError.loadAttemptsExhausted
                    },
                    nil
                )
            }
            remainingLoadAttempts -= 1
            generation &+= 1
            let loadGeneration = generation
            let task = Task {
                try await generateAndCache(generation: loadGeneration)
            }
            loadTask = task
            return (generation, task, nil)
        }
        if let cached = pending.2 {
            return cached
        }

        let body = try await pending.1.value
        try Task.checkCancellation()
        return body
    }

    private func generateAndCache(generation loadGeneration: UInt64) async throws -> Data {
        do {
            let body = try await loader()
            guard !body.isEmpty, body.count <= maximumContentLength else {
                throw LoopbackGeneratedResourceError.invalidGeneratedContentLength(
                    body.count
                )
            }
            let accepted = lock.withLock { () -> Bool in
                guard generation == loadGeneration, !invalidated else {
                    return false
                }
                cachedBody = body
                loadTask = nil
                return true
            }
            guard accepted else { throw CancellationError() }
            return body
        } catch {
            lock.withLock {
                if generation == loadGeneration {
                    loadTask = nil
                }
            }
            throw error
        }
    }

    fileprivate func cancel() {
        let task = lock.withLock { () -> Task<Data, any Error>? in
            generation &+= 1
            invalidated = true
            cachedBody = nil
            let task = loadTask
            loadTask = nil
            return task
        }
        task?.cancel()
    }
}

public enum LoopbackPlaybackResource: Sendable, Equatable {
    case inMemory(data: Data, contentType: String)
    case remote(LoopbackRemoteResource)
    case generated(LoopbackGeneratedResource)
    case progressive(LoopbackProgressiveResource)

    fileprivate var contentLength: Int64 {
        switch self {
        case .inMemory(let data, _):
            Int64(data.count)
        case .remote(let resource):
            resource.contentLength
        case .generated:
            preconditionFailure("Generated resources must be resolved before responding")
        case .progressive(let resource):
            resource.contentLength
        }
    }

    fileprivate var contentType: String {
        switch self {
        case .inMemory(_, let contentType):
            contentType
        case .remote(let resource):
            resource.contentType
        case .generated(let resource):
            resource.contentType
        case .progressive(let resource):
            resource.contentType
        }
    }
}

public struct LoopbackRouteRegistration: Sendable, Equatable {
    public let relativePath: String
    public let resource: LoopbackPlaybackResource

    public init(
        relativePath: String,
        resource: LoopbackPlaybackResource
    ) {
        self.relativePath = relativePath
        self.resource = resource
    }
}

public enum LoopbackPlaybackServerError: Error, Sendable, Equatable {
    case invalidContentLength(Int64)
    case invalidRoute(String)
    case duplicateRoute(String)
    case notStarted
    case listenerFailed(String)
    case invalidHTTPRequest
    case invalidProgressiveSource
}

struct LoopbackPlaybackServerDiagnostics: Sendable, Equatable {
    let isRunning: Bool
    let registeredRouteCount: Int
    let activeConnectionCount: Int
    let activeTaskCount: Int
}

private enum LoopbackRangeRequest {
    case ignored
    case satisfiable(headerValue: String, resolved: HTTPByteRange)
    case unsatisfiable
}

/// 向 AVPlayer 暴露最小、会话隔离的 HTTP/1.1 HLS/Range surface。
///
/// Server 只绑定 `127.0.0.1`，要求随机 path 与精确 Host，并对远端媒体强制 Range。
/// `stop` 会原子移除 listener、route、connection 与上游 Task，可安全重复调用。
public final class LoopbackPlaybackServer: @unchecked Sendable {
    private static let maximumHeaderBytes = 16 * 1_024

    private let queue: DispatchQueue
    private let lock = NSLock()
    private let rangeClient: HTTPRangeClient
    private let rangeStreamer: any HTTPRangeStreaming
    private let sessionToken: String
    private var listener: NWListener?
    private var port: NWEndpoint.Port?
    private var routes: [String: LoopbackPlaybackResource] = [:]
    private var requestCounts: [String: Int] = [:]
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var connectionTasks: [ObjectIdentifier: Task<Void, Never>] = [:]
    private var connectionTargets: [ObjectIdentifier: String] = [:]

    public init(
        rangeClient: HTTPRangeClient = HTTPRangeClient(),
        rangeStreamer: any HTTPRangeStreaming = HTTPRangeStreamingClient(),
        queueLabel: String = "com.shiinayane.BiliKit.loopback-playback"
    ) {
        self.rangeClient = rangeClient
        self.rangeStreamer = rangeStreamer
        queue = DispatchQueue(label: queueLabel)
        sessionToken = UUID().uuidString.replacingOccurrences(of: "-", with: "")
    }

    deinit {
        stop()
    }

    /// 启动并等待 listener 得到实际端口；调用方取消会同步撤销未完成的启动。
    public func start() async throws {
        if lock.withLock({ self.listener != nil && self.port != nil }) {
            return
        }

        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(
            host: NWEndpoint.Host("127.0.0.1"),
            port: .any
        )
        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            throw LoopbackPlaybackServerError.listenerFailed(
                String(reflecting: type(of: error))
            )
        }

        let startBox = StartContinuationBox()
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            switch state {
            case .ready:
                guard let self, let boundPort = listener?.port else {
                    startBox.resume(
                        throwing: LoopbackPlaybackServerError.listenerFailed(
                            "Listener became ready without a port"
                        )
                    )
                    return
                }
                self.lock.withLock {
                    self.port = boundPort
                }
                startBox.resume()
            case .failed(let error):
                startBox.resume(
                    throwing: LoopbackPlaybackServerError.listenerFailed(
                        String(describing: error)
                    )
                )
            case .cancelled:
                startBox.resume(
                    throwing: LoopbackPlaybackServerError.listenerFailed(
                        "Listener cancelled before becoming ready"
                    )
                )
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        lock.withLock {
            self.listener = listener
        }

        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                startBox.install(continuation)
                listener.start(queue: queue)
            }
            try Task.checkCancellation()
        } onCancel: {
            startBox.resume(throwing: CancellationError())
            self.cancelStart(listener)
        }
    }

    /// 把资源登记在本 session token 下；返回 URL 不泄露远端来源。
    public func register(
        _ resource: LoopbackPlaybackResource,
        at relativePath: String
    ) throws -> URL {
        try register([
            LoopbackRouteRegistration(
                relativePath: relativePath,
                resource: resource
            )
        ])[0]
    }

    /// 先验证完整集合，再在同一锁内登记，避免 master 可见时轨道 route 仍不完整。
    public func register(
        _ registrations: [LoopbackRouteRegistration]
    ) throws -> [URL] {
        var seen = Set<String>()
        let prepared = try registrations.map { registration in
            let url = try url(for: registration.relativePath)
            guard seen.insert(url.path).inserted else {
                throw LoopbackPlaybackServerError.duplicateRoute(
                    registration.relativePath
                )
            }
            return (url, registration.resource)
        }
        try lock.withLock {
            for (url, _) in prepared where routes[url.path] != nil {
                throw LoopbackPlaybackServerError.duplicateRoute(url.path)
            }
            for (url, resource) in prepared {
                routes[url.path] = resource
            }
        }
        return prepared.map(\.0)
    }

    public func unregister(relativePaths: [String]) throws {
        let routesToRemove = try relativePaths.map { try url(for: $0).path }
        let state = lock.withLock {
            () -> (
                [LoopbackPlaybackResource],
                [NWConnection],
                [Task<Void, Never>]
            ) in
            let removed = routesToRemove.compactMap { routes.removeValue(forKey: $0) }
            let routeSet = Set(routesToRemove)
            let connectionIDs = connectionTargets.compactMap { id, target in
                routeSet.contains(target) ? id : nil
            }
            let connectionsToCancel = connectionIDs.compactMap {
                connections.removeValue(forKey: $0)
            }
            let tasksToCancel = connectionIDs.compactMap {
                connectionTasks.removeValue(forKey: $0)
            }
            for id in connectionIDs {
                connectionTargets.removeValue(forKey: id)
            }
            return (removed, connectionsToCancel, tasksToCancel)
        }
        cancelGeneratedResources(in: state.0)
        for connection in state.1 {
            connection.cancel()
        }
        for task in state.2 {
            task.cancel()
        }
    }

    public func url(for relativePath: String) throws -> URL {
        guard isValidRoute(relativePath) else {
            throw LoopbackPlaybackServerError.invalidRoute(relativePath)
        }
        guard let port = lock.withLock({ self.port }) else {
            throw LoopbackPlaybackServerError.notStarted
        }

        let route = "/\(sessionToken)/\(relativePath)"
        return try requireURL(
            "http://127.0.0.1:\(port.rawValue)\(route)"
        )
    }

    /// 关闭 listener、所有活动连接与远端 Range Task，并清空内存 route。
    public func stop() {
        let state = lock.withLock {
            () -> (
                NWListener?,
                [NWConnection],
                [Task<Void, Never>],
                [LoopbackPlaybackResource]
            ) in
            let state = (
                listener,
                Array(connections.values),
                Array(connectionTasks.values),
                Array(routes.values)
            )
            listener = nil
            port = nil
            routes.removeAll()
            requestCounts.removeAll()
            connections.removeAll()
            connectionTasks.removeAll()
            connectionTargets.removeAll()
            return state
        }

        state.0?.cancel()
        for connection in state.1 {
            connection.cancel()
        }
        for task in state.2 {
            task.cancel()
        }
        cancelGeneratedResources(in: state.3)
        rangeStreamer.invalidate()
    }

    func diagnosticsSnapshot() -> LoopbackPlaybackServerDiagnostics {
        lock.withLock {
            LoopbackPlaybackServerDiagnostics(
                isRunning: listener != nil && port != nil,
                registeredRouteCount: routes.count,
                activeConnectionCount: connections.count,
                activeTaskCount: connectionTasks.count
            )
        }
    }

    func requestCount(method: String, at relativePath: String) throws -> Int {
        let route = try url(for: relativePath).path
        return lock.withLock {
            requestCounts[requestKey(method: method, target: route), default: 0]
        }
    }

    private func accept(_ connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        lock.withLock {
            connections[id] = connection
        }
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .cancelled, .failed:
                self?.removeConnection(id)
            default:
                break
            }
        }
        connection.start(queue: queue)
        receiveRequestHeader(on: connection, id: id, accumulated: Data())
    }

    private func cancelStart(_ listener: NWListener) {
        lock.withLock {
            guard self.listener === listener else { return }
            self.listener = nil
            port = nil
            listener.cancel()
        }
    }

    private func receiveRequestHeader(
        on connection: NWConnection,
        id: ObjectIdentifier,
        accumulated: Data
    ) {
        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: Self.maximumHeaderBytes
        ) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if error != nil {
                connection.cancel()
                return
            }

            var buffer = accumulated
            if let data {
                buffer.append(data)
            }
            guard buffer.count <= Self.maximumHeaderBytes else {
                self.sendStatus(431, reason: "Request Header Fields Too Large", on: connection)
                return
            }

            let delimiter = Data("\r\n\r\n".utf8)
            if let headerEnd = buffer.range(of: delimiter)?.upperBound {
                let header = buffer.subdata(in: 0..<headerEnd)
                self.beginResponse(for: header, on: connection, id: id)
            } else if isComplete {
                self.sendStatus(400, reason: "Bad Request", on: connection)
            } else {
                self.receiveRequestHeader(
                    on: connection,
                    id: id,
                    accumulated: buffer
                )
            }
        }
    }

    private func beginResponse(
        for headerData: Data,
        on connection: NWConnection,
        id: ObjectIdentifier
    ) {
        let request: LoopbackHTTPRequest
        do {
            request = try LoopbackHTTPRequest.parse(headerData)
        } catch {
            sendStatus(400, reason: "Bad Request", on: connection)
            return
        }

        guard request.method == "GET" || request.method == "HEAD" else {
            sendStatus(
                405,
                reason: "Method Not Allowed",
                headers: ["Allow": "GET, HEAD"],
                on: connection
            )
            return
        }
        guard let expectedHostHeader,
            request.headers["host"] == expectedHostHeader
        else {
            sendStatus(400, reason: "Bad Request", on: connection)
            return
        }
        guard request.target.hasPrefix("/\(sessionToken)/") else {
            sendStatus(404, reason: "Not Found", on: connection)
            return
        }
        guard
            let resource = lock.withLock({ () -> LoopbackPlaybackResource? in
                guard let resource = routes[request.target] else { return nil }
                connectionTargets[id] = request.target
                requestCounts[
                    requestKey(method: request.method, target: request.target),
                    default: 0
                ] += 1
                return resource
            })
        else {
            sendStatus(404, reason: "Not Found", on: connection)
            return
        }

        let task = Task { [weak self, weak connection] in
            guard let self, let connection else { return }
            do {
                try await self.respond(
                    to: request,
                    with: resource,
                    on: connection
                )
            } catch is CancellationError {
                connection.cancel()
            } catch is LoopbackResponseAlreadyStartedError {
                connection.cancel()
            } catch {
                self.sendStatus(502, reason: "Bad Gateway", on: connection)
            }
        }
        let accepted = lock.withLock { () -> Bool in
            guard connections[id] != nil,
                connectionTargets[id] == request.target,
                routes[request.target] == resource
            else {
                return false
            }
            connectionTasks[id] = task
            return true
        }
        if !accepted {
            task.cancel()
            connection.cancel()
        }
    }

    private func requestKey(method: String, target: String) -> String {
        "\(method.uppercased()) \(target)"
    }

    private func respond(
        to request: LoopbackHTTPRequest,
        with resource: LoopbackPlaybackResource,
        on connection: NWConnection
    ) async throws {
        if case .generated(let generated) = resource {
            let body = try await generated.resolve()
            try Task.checkCancellation()
            try await respond(
                to: request,
                with: .inMemory(
                    data: body,
                    contentType: generated.contentType
                ),
                on: connection
            )
            return
        }
        if request.method == "HEAD" {
            sendResponse(
                status: 200,
                reason: "OK",
                headers: responseHeaders(
                    for: resource,
                    bodyLength: 0,
                    range: nil,
                    isHead: true
                ),
                body: Data(),
                on: connection
            )
            return
        }

        let requestedRange: HTTPByteRange?
        switch parseRange(
            request.headers["range"],
            contentLength: resource.contentLength
        ) {
        case .ignored:
            requestedRange = nil
        case .satisfiable(_, let range):
            requestedRange = range
        case .unsatisfiable:
            sendStatus(
                416,
                reason: "Range Not Satisfiable",
                headers: [
                    "Accept-Ranges": "bytes",
                    "Cache-Control": "no-store",
                    "Content-Range": "bytes */\(resource.contentLength)",
                    "Content-Type": resource.contentType,
                ],
                on: connection
            )
            return
        }

        switch resource {
        case .inMemory(let data, _):
            let body: Data
            if let requestedRange {
                body = data.subdata(
                    in: Int(requestedRange.start)..<(Int(requestedRange.endInclusive) + 1)
                )
            } else {
                body = data
            }
            sendResponse(
                status: requestedRange == nil ? 200 : 206,
                reason: requestedRange == nil ? "OK" : "Partial Content",
                headers: responseHeaders(
                    for: resource,
                    bodyLength: body.count,
                    range: requestedRange,
                    isHead: false
                ),
                body: body,
                on: connection
            )
        case .remote(let remote):
            guard let requestedRange else {
                sendStatus(400, reason: "Range Required", on: connection)
                return
            }
            let result = try await rangeClient.fetch(
                from: [remote.sourceURL],
                range: requestedRange,
                headers: remote.headers
            )
            try Task.checkCancellation()
            sendResponse(
                status: 206,
                reason: "Partial Content",
                headers: responseHeaders(
                    for: resource,
                    bodyLength: result.body.count,
                    range: requestedRange,
                    isHead: false
                ),
                body: result.body,
                on: connection
            )
        case .progressive(let progressive):
            guard let requestedRange else {
                sendStatus(400, reason: "Range Required", on: connection)
                return
            }
            guard
                case .satisfiable(let rangeHeader, _) = parseRange(
                    request.headers["range"],
                    contentLength: resource.contentLength
                )
            else {
                sendStatus(400, reason: "Bad Request", on: connection)
                return
            }
            try await streamProgressive(
                progressive,
                rangeHeader: rangeHeader,
                range: requestedRange,
                on: connection
            )
        case .generated:
            preconditionFailure("Generated resource was not resolved")
        }
    }

    private func streamProgressive(
        _ resource: LoopbackProgressiveResource,
        rangeHeader: String,
        range: HTTPByteRange,
        on connection: NWConnection
    ) async throws {
        var lastError: (any Error)?
        for sourceURL in resource.eligibleSourceURLs {
            try Task.checkCancellation()
            let responseStarted = LockedFlag()
            do {
                let result = try await rangeStreamer.stream(
                    from: sourceURL,
                    rangeHeader: rangeHeader,
                    expectedRange: range,
                    expectedCompleteLength: resource.contentLength,
                    headers: resource.headers,
                    allowedContentTypes: resource.allowedUpstreamContentTypes,
                    onResponse: { [weak connection] _ in
                        guard resource.select(sourceURL), let connection else {
                            throw CancellationError()
                        }
                        try await Self.sendHead(
                            status: 206,
                            reason: "Partial Content",
                            headers: [
                                "Accept-Ranges": "bytes",
                                "Cache-Control": "no-store",
                                "Connection": "close",
                                "Content-Length": "\(range.length)",
                                "Content-Range":
                                    "bytes \(range.start)-\(range.endInclusive)/\(resource.contentLength)",
                                "Content-Type": resource.contentType,
                            ],
                            on: connection
                        )
                        responseStarted.set()
                    },
                    onChunk: { [weak connection] chunk in
                        guard let connection else { throw CancellationError() }
                        try await Self.sendChunk(chunk, on: connection)
                    }
                )
                guard result.byteCount == range.length else {
                    throw HTTPRangeStreamingError.bodyLengthMismatch(
                        expected: range.length,
                        actual: result.byteCount
                    )
                }
                connection.cancel()
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
                if responseStarted.value {
                    throw LoopbackResponseAlreadyStartedError()
                }
            }
        }
        throw lastError ?? LoopbackPlaybackServerError.invalidProgressiveSource
    }

    private static func sendHead(
        status: Int,
        reason: String,
        headers: [String: String],
        on connection: NWConnection
    ) async throws {
        let head =
            (["HTTP/1.1 \(status) \(reason)"]
            + headers.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }
            + ["", ""])
            .joined(separator: "\r\n")
        try await sendChunk(Data(head.utf8), on: connection)
    }

    private static func sendChunk(
        _ data: Data,
        on connection: NWConnection
    ) async throws {
        try Task.checkCancellation()
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, any Error>) in
            connection.send(
                content: data,
                completion: .contentProcessed { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            )
        }
        try Task.checkCancellation()
    }

    private func responseHeaders(
        for resource: LoopbackPlaybackResource,
        bodyLength: Int,
        range: HTTPByteRange?,
        isHead: Bool
    ) -> [String: String] {
        var headers = [
            "Accept-Ranges": "bytes",
            "Cache-Control": "no-store",
            "Content-Type": resource.contentType,
            "Content-Length": isHead
                ? "\(resource.contentLength)"
                : "\(bodyLength)",
        ]
        if let range {
            headers["Content-Range"] =
                "bytes \(range.start)-\(range.endInclusive)/\(resource.contentLength)"
        }
        return headers
    }

    private func parseRange(
        _ value: String?,
        contentLength: Int64
    ) -> LoopbackRangeRequest {
        guard let value else { return .ignored }
        let components = value.split(
            separator: "=",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        guard components.count == 2,
            components[0].lowercased() == "bytes",
            !components[1].contains(",")
        else {
            return .ignored
        }

        let bounds = components[1].split(
            separator: "-",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        guard bounds.count == 2 else {
            return .ignored
        }

        if bounds[0].isEmpty {
            guard let suffixLength = Int64(bounds[1]) else {
                return .ignored
            }
            guard suffixLength > 0 else {
                return suffixLength == 0 ? .unsatisfiable : .ignored
            }
            let boundedLength = min(suffixLength, contentLength)
            guard
                let range = try? HTTPByteRange(
                    start: contentLength - boundedLength,
                    endInclusive: contentLength - 1
                )
            else {
                return .ignored
            }
            return .satisfiable(headerValue: value, resolved: range)
        }

        guard let start = Int64(bounds[0]), start >= 0 else {
            return .ignored
        }
        guard start < contentLength else {
            return .unsatisfiable
        }

        let endInclusive: Int64
        if bounds[1].isEmpty {
            endInclusive = contentLength - 1
        } else {
            guard let requestedEnd = Int64(bounds[1]), requestedEnd >= start else {
                return .ignored
            }
            endInclusive = min(requestedEnd, contentLength - 1)
        }
        guard
            let range = try? HTTPByteRange(
                start: start,
                endInclusive: endInclusive
            )
        else {
            return .ignored
        }
        return .satisfiable(headerValue: value, resolved: range)
    }

    private func sendStatus(
        _ status: Int,
        reason: String,
        headers: [String: String] = [:],
        on connection: NWConnection
    ) {
        sendResponse(
            status: status,
            reason: reason,
            headers: headers,
            body: Data(),
            on: connection
        )
    }

    private func sendResponse(
        status: Int,
        reason: String,
        headers: [String: String],
        body: Data,
        on connection: NWConnection
    ) {
        var responseHeaders = headers
        responseHeaders["Connection"] = "close"
        responseHeaders["Content-Length"] =
            responseHeaders["Content-Length"]
            ?? "\(body.count)"
        let head =
            (["HTTP/1.1 \(status) \(reason)"]
            + responseHeaders.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }
            + ["", ""])
            .joined(separator: "\r\n")
        var response = Data(head.utf8)
        response.append(body)

        connection.send(
            content: response,
            completion: .contentProcessed { _ in
                connection.cancel()
            }
        )
    }

    private func removeConnection(_ id: ObjectIdentifier) {
        let task = lock.withLock { () -> Task<Void, Never>? in
            connections.removeValue(forKey: id)
            connectionTargets.removeValue(forKey: id)
            return connectionTasks.removeValue(forKey: id)
        }
        task?.cancel()
    }

    private func isValidRoute(_ route: String) -> Bool {
        guard !route.isEmpty,
            !route.hasPrefix("/"),
            !route.hasSuffix("/"),
            !route.contains("..")
        else {
            return false
        }
        let allowed = CharacterSet.alphanumerics.union(
            CharacterSet(charactersIn: "-._/")
        )
        return route.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    private func cancelGeneratedResources(
        in resources: [LoopbackPlaybackResource]
    ) {
        for case .generated(let resource) in resources {
            resource.cancel()
        }
    }

    private var expectedHostHeader: String? {
        lock.withLock {
            port.map { "127.0.0.1:\($0.rawValue)" }
        }
    }
}

private struct LoopbackHTTPRequest: Sendable {
    let method: String
    let target: String
    let headers: [String: String]

    static func parse(_ data: Data) throws -> Self {
        guard let text = String(data: data, encoding: .utf8) else {
            throw LoopbackPlaybackServerError.invalidHTTPRequest
        }
        let lines = text.components(separatedBy: "\r\n")
        let requestLine = lines[0].split(separator: " ")
        guard requestLine.count == 3,
            requestLine[2].hasPrefix("HTTP/1.")
        else {
            throw LoopbackPlaybackServerError.invalidHTTPRequest
        }

        let rawTarget = String(requestLine[1])
        let target = rawTarget.split(separator: "?", maxSplits: 1)[0]
        var headers: [String: String] = [:]
        for line in lines.dropFirst() where !line.isEmpty {
            guard let separator = line.firstIndex(of: ":") else {
                throw LoopbackPlaybackServerError.invalidHTTPRequest
            }
            let name = line[..<separator].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: separator)...]
                .trimmingCharacters(in: .whitespaces)
            let normalizedName = name.lowercased()
            guard normalizedName != "host" || headers[normalizedName] == nil else {
                throw LoopbackPlaybackServerError.invalidHTTPRequest
            }
            headers[normalizedName] = value
        }
        return Self(
            method: String(requestLine[0]),
            target: String(target),
            headers: headers
        )
    }
}

private final class StartContinuationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, any Error>?
    private var result: Result<Void, any Error>?

    func install(_ continuation: CheckedContinuation<Void, any Error>) {
        let pendingResult = lock.withLock { () -> Result<Void, any Error>? in
            if let result {
                return result
            }
            self.continuation = continuation
            return nil
        }
        if let pendingResult {
            continuation.resume(with: pendingResult)
        }
    }

    func resume() {
        resume(with: .success(()))
    }

    func resume(throwing error: any Error) {
        resume(with: .failure(error))
    }

    private func resume(with result: Result<Void, any Error>) {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, any Error>? in
            guard self.result == nil else { return nil }
            self.result = result
            let continuation = self.continuation
            self.continuation = nil
            return continuation
        }
        continuation?.resume(with: result)
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = false

    var value: Bool { lock.withLock { storage } }

    func set() {
        lock.withLock { storage = true }
    }
}

private func requireURL(_ value: String) throws -> URL {
    guard let url = URL(string: value) else {
        throw LoopbackPlaybackServerError.invalidRoute(value)
    }
    return url
}
