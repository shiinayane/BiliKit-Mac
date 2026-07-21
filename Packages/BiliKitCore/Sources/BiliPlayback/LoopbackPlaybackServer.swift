@preconcurrency import Network
import BiliNetworking
import Foundation

public struct LoopbackRemoteResource: Sendable, Equatable {
    public let candidateURLs: [URL]
    public let contentLength: Int64
    public let contentType: String
    public let headers: [String: String]

    public init(
        candidateURLs: [URL],
        contentLength: Int64,
        contentType: String,
        headers: [String: String] = [:]
    ) throws {
        guard !candidateURLs.isEmpty else {
            throw LoopbackPlaybackServerError.noRemoteCandidates
        }
        guard contentLength > 0 else {
            throw LoopbackPlaybackServerError.invalidContentLength(contentLength)
        }

        self.candidateURLs = candidateURLs
        self.contentLength = contentLength
        self.contentType = contentType
        self.headers = headers
    }
}

public enum LoopbackPlaybackResource: Sendable, Equatable {
    case inMemory(data: Data, contentType: String)
    case remote(LoopbackRemoteResource)

    fileprivate var contentLength: Int64 {
        switch self {
        case let .inMemory(data, _):
            Int64(data.count)
        case let .remote(resource):
            resource.contentLength
        }
    }

    fileprivate var contentType: String {
        switch self {
        case let .inMemory(_, contentType):
            contentType
        case let .remote(resource):
            resource.contentType
        }
    }
}

public enum LoopbackPlaybackServerError: Error, Sendable, Equatable {
    case noRemoteCandidates
    case invalidContentLength(Int64)
    case invalidRoute(String)
    case notStarted
    case listenerFailed(String)
    case invalidHTTPRequest
    case invalidRangeHeader
}

struct LoopbackPlaybackServerDiagnostics: Sendable, Equatable {
    let isRunning: Bool
    let registeredRouteCount: Int
    let activeConnectionCount: Int
    let activeTaskCount: Int
}

public final class LoopbackPlaybackServer: @unchecked Sendable {
    private static let maximumHeaderBytes = 16 * 1_024

    private let queue: DispatchQueue
    private let lock = NSLock()
    private let rangeClient: HTTPRangeClient
    private let sessionToken: String
    private var listener: NWListener?
    private var port: NWEndpoint.Port?
    private var routes: [String: LoopbackPlaybackResource] = [:]
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var connectionTasks: [ObjectIdentifier: Task<Void, Never>] = [:]

    public init(
        rangeClient: HTTPRangeClient = HTTPRangeClient(),
        queueLabel: String = "com.shiinayane.BiliKit.loopback-playback"
    ) {
        self.rangeClient = rangeClient
        queue = DispatchQueue(label: queueLabel)
        sessionToken = UUID().uuidString.replacingOccurrences(of: "-", with: "")
    }

    deinit {
        stop()
    }

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
            case let .failed(error):
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

        try await withCheckedThrowingContinuation { continuation in
            startBox.install(continuation)
            listener.start(queue: queue)
        }
    }

    public func register(
        _ resource: LoopbackPlaybackResource,
        at relativePath: String
    ) throws -> URL {
        let url = try url(for: relativePath)
        let route = url.path
        lock.withLock {
            routes[route] = resource
        }
        return url
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

    public func stop() {
        let state = lock.withLock { () -> (
            NWListener?,
            [NWConnection],
            [Task<Void, Never>]
        ) in
            let state = (
                listener,
                Array(connections.values),
                Array(connectionTasks.values)
            )
            listener = nil
            port = nil
            routes.removeAll()
            connections.removeAll()
            connectionTasks.removeAll()
            return state
        }

        state.0?.cancel()
        state.1.forEach { $0.cancel() }
        state.2.forEach { $0.cancel() }
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
        guard request.target.hasPrefix("/\(sessionToken)/"),
              let resource = lock.withLock({ routes[request.target] })
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
            } catch {
                self.sendStatus(502, reason: "Bad Gateway", on: connection)
            }
        }
        lock.withLock {
            connectionTasks[id] = task
        }
    }

    private func respond(
        to request: LoopbackHTTPRequest,
        with resource: LoopbackPlaybackResource,
        on connection: NWConnection
    ) async throws {
        let requestedRange = try parseRange(
            request.headers["range"],
            contentLength: resource.contentLength
        )

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

        switch resource {
        case let .inMemory(data, _):
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
        case let .remote(remote):
            guard let requestedRange else {
                sendStatus(400, reason: "Range Required", on: connection)
                return
            }
            let result = try await rangeClient.fetch(
                from: remote.candidateURLs,
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
        }
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
            headers["Content-Range"] = "bytes \(range.start)-\(range.endInclusive)/\(resource.contentLength)"
        }
        return headers
    }

    private func parseRange(
        _ value: String?,
        contentLength: Int64
    ) throws -> HTTPByteRange? {
        guard let value else { return nil }
        guard value.lowercased().hasPrefix("bytes="),
              !value.contains(",")
        else {
            throw LoopbackPlaybackServerError.invalidRangeHeader
        }

        let bounds = value.dropFirst("bytes=".count).split(
            separator: "-",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        guard bounds.count == 2,
              let start = Int64(bounds[0]),
              start >= 0,
              start < contentLength
        else {
            throw LoopbackPlaybackServerError.invalidRangeHeader
        }

        let endInclusive: Int64
        if bounds[1].isEmpty {
            endInclusive = contentLength - 1
        } else {
            guard let requestedEnd = Int64(bounds[1]), requestedEnd >= start else {
                throw LoopbackPlaybackServerError.invalidRangeHeader
            }
            endInclusive = min(requestedEnd, contentLength - 1)
        }
        return try HTTPByteRange(start: start, endInclusive: endInclusive)
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
        responseHeaders["Content-Length"] = responseHeaders["Content-Length"]
            ?? "\(body.count)"
        let head = (["HTTP/1.1 \(status) \(reason)"]
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
            headers[name.lowercased()] = value
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

private func requireURL(_ value: String) throws -> URL {
    guard let url = URL(string: value) else {
        throw LoopbackPlaybackServerError.invalidRoute(value)
    }
    return url
}
