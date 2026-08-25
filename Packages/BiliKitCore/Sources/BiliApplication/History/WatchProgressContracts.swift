import BiliModels
import Foundation

/// 从当前详情与当前播放器 item 共同解析出的非秘密写入目标。
public struct WatchProgressTarget: Sendable, Equatable {
    public let aid: Int64
    public let identity: PlaybackItemIdentity
    public let loadIntent: PlaybackLoadIntent

    public init?(
        aid: Int64,
        identity: PlaybackItemIdentity,
        loadIntent: PlaybackLoadIntent
    ) {
        guard aid > 0, identity.cid > 0, !identity.bvid.isEmpty else { return nil }
        self.aid = aid
        self.identity = identity
        self.loadIntent = loadIntent
    }
}

/// Bilibili Web 播放器当前使用的 heartbeat 动作。
public enum WatchProgressEvent: Int, Sendable, Equatable {
    case periodic = 0
    case started = 1
    case paused = 2
    case resumed = 3
    case ended = 4
}

/// 一次进程内播放会话的非秘密协议事实；不持久化，也不包含账户身份或凭据。
public struct WatchProgressReport: Sendable, Equatable {
    public let target: WatchProgressTarget
    public let event: WatchProgressEvent
    public let sessionStartTimestamp: Int64
    public let sessionID: String
    public let generation: UInt64
    public let sequence: UInt64
    public let positionSeconds: Int
    public let maximumPositionSeconds: Int
    public let durationSeconds: Int?
    public let elapsedSeconds: Int
    public let playedSeconds: Int
    public let completed: Bool

    public init?(
        target: WatchProgressTarget,
        event: WatchProgressEvent,
        sessionStartTimestamp: Int64,
        sessionID: String,
        generation: UInt64,
        sequence: UInt64,
        positionSeconds: Double,
        maximumPositionSeconds: Double,
        durationSeconds: Double?,
        elapsedSeconds: Double,
        playedSeconds: Double,
        completed: Bool
    ) {
        guard sessionStartTimestamp > 0,
            Self.isValidSessionID(sessionID),
            generation > 0,
            sequence > 0,
            !completed || event == .ended,
            positionSeconds.isFinite,
            maximumPositionSeconds.isFinite,
            elapsedSeconds.isFinite,
            playedSeconds.isFinite,
            positionSeconds >= 0,
            maximumPositionSeconds >= positionSeconds,
            elapsedSeconds >= 0,
            playedSeconds >= 0
        else { return nil }

        let validDuration = durationSeconds.flatMap { value -> Double? in
            guard value.isFinite, value > 0 else { return nil }
            return value
        }
        let boundedPosition =
            validDuration.map { min(positionSeconds, $0) }
            ?? positionSeconds
        let boundedMaximum =
            validDuration.map {
                min(max(maximumPositionSeconds, boundedPosition), $0)
            } ?? max(maximumPositionSeconds, boundedPosition)
        guard boundedPosition <= Double(Int.max),
            boundedMaximum <= Double(Int.max),
            elapsedSeconds <= Double(Int.max),
            playedSeconds <= Double(Int.max),
            validDuration.map({ $0 <= Double(Int.max) }) ?? true
        else { return nil }

        self.target = target
        self.event = event
        self.sessionStartTimestamp = sessionStartTimestamp
        self.sessionID = sessionID
        self.generation = generation
        self.sequence = sequence
        self.positionSeconds = Int(boundedPosition.rounded(.down))
        self.maximumPositionSeconds = Int(boundedMaximum.rounded(.down))
        self.durationSeconds = validDuration.map { Int($0.rounded(.down)) }
        self.elapsedSeconds = Int(elapsedSeconds.rounded(.down))
        self.playedSeconds = Int(playedSeconds.rounded(.down))
        self.completed = completed
    }

    private static func isValidSessionID(_ value: String) -> Bool {
        value.count == 32
            && value.allSatisfy {
                $0.isASCII && ($0.isNumber || ("a"..."f").contains(String($0)))
            }
    }
}

public enum WatchProgressError: Error, Sendable, Equatable {
    case authenticationRequired
    case authenticationInvalid
    case requestRestricted
    case serviceRejected(code: Int)
    case unavailable
    case invalidResponse
}

public protocol WatchProgressRepository: Sendable {
    func report(_ progress: WatchProgressReport) async throws
}

/// 进程级 writer：所有窗口最多一个在途写入；认证代次变化会取消全部旧等待者。
///
/// 每个窗口 session 自身最多向这里提交一个调用，因此等待规模由存活窗口数而不是播放事件数决定。
public actor SerializedWatchProgressRepository: WatchProgressRepository,
    AuthenticatedSessionInvalidating
{
    private let base: any WatchProgressRepository
    private var tail: Task<Void, Never>?
    private var operations: [UUID: Task<Void, Error>] = [:]
    private var operationCountWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var authenticationGeneration: UInt64 = 0

    public init(base: any WatchProgressRepository) {
        self.base = base
    }

    public func report(_ progress: WatchProgressReport) async throws {
        let operationID = UUID()
        let predecessor = tail
        let expectedGeneration = authenticationGeneration
        let base = base
        let operation = Task {
            if let predecessor {
                await predecessor.value
            }
            try Task.checkCancellation()
            try self.requireAuthenticationGeneration(expectedGeneration)
            try await base.report(progress)
            try self.requireAuthenticationGeneration(expectedGeneration)
        }
        operations[operationID] = operation
        resumeOperationCountWaiters()
        tail = Task { _ = try? await operation.value }

        do {
            try await withTaskCancellationHandler {
                try await operation.value
            } onCancel: {
                operation.cancel()
            }
            operations[operationID] = nil
        } catch {
            operations[operationID] = nil
            throw error
        }
    }

    public func invalidateAuthenticatedSession() {
        authenticationGeneration &+= 1
        for operation in operations.values {
            operation.cancel()
        }
    }

    private func requireAuthenticationGeneration(_ expected: UInt64) throws {
        guard expected == authenticationGeneration else {
            throw CancellationError()
        }
    }

    func waitForOperationCountForTesting(_ expected: Int) async {
        if operations.count >= expected { return }
        await withCheckedContinuation {
            operationCountWaiters.append((expected, $0))
        }
    }

    private func resumeOperationCountWaiters() {
        let ready = operationCountWaiters.filter { operations.count >= $0.0 }
        operationCountWaiters.removeAll { operations.count >= $0.0 }
        for waiter in ready {
            waiter.1.resume()
        }
    }
}

public struct WatchProgressUseCase: Sendable {
    private let repository: any WatchProgressRepository

    public init(repository: any WatchProgressRepository) {
        self.repository = repository
    }

    public func report(_ progress: WatchProgressReport) async throws {
        try await repository.report(progress)
    }
}
