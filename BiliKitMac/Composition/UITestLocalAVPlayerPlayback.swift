#if DEBUG
    @preconcurrency import AVFoundation
    import BiliApplication
    import BiliModels
    import Foundation
    import Observation

    @MainActor
    @Observable
    final class UITestLocalAVPlayerResourceRegistry {
        static let shared = UITestLocalAVPlayerResourceRegistry()

        private(set) var activeItems = 0
        private(set) var activeObservers = 0
        private(set) var activeMediaDirectories = 0

        private init() {}

        func itemInstalled() {
            activeItems += 1
        }

        func itemRemoved() {
            precondition(activeItems > 0)
            activeItems -= 1
        }

        func observerInstalled() {
            activeObservers += 1
        }

        func observerRemoved() {
            precondition(activeObservers > 0)
            activeObservers -= 1
        }

        func mediaDirectoryCreated() {
            activeMediaDirectories += 1
        }

        func mediaDirectoryRemoved() {
            precondition(activeMediaDirectories > 0)
            activeMediaDirectories -= 1
        }
    }

    /// 仅供显式 UITest/App test 使用的真实本地 AVPlayer owner。
    ///
    /// 媒体是进程私有临时目录中的确定性 WAV；不访问网络，也不代表远端播放通过。
    @MainActor
    @Observable
    final class UITestLocalAVPlayerPlayback: PlaybackControlling {
        let player: AVPlayer

        private(set) var isLoaded = false
        private(set) var itemAlias = "none"
        private(set) var itemGeneration = 0
        private(set) var positionMilliseconds = 0
        private(set) var status = "stopped"
        private(set) var lastStoppedItemAlias = "none"
        private(set) var startedLoadGeneration = 0
        private(set) var settledLoadGeneration = 0

        private let mediaStore = UITestLocalMediaStore()
        private let resourceRegistry = UITestLocalAVPlayerResourceRegistry.shared
        private var installedItem: AVPlayerItem?
        private var timeObserver: Any?
        private var loadGeneration = 0
        private var registeredMediaDirectory = false

        init() {
            let player = AVPlayer()
            player.isMuted = true
            self.player = player
        }

        var activeObserverCount: Int {
            timeObserver == nil ? 0 : 1
        }

        var mediaDirectoryExists: Bool {
            mediaStore.directoryExists
        }

        func playbackFailureEvents() -> AsyncStream<PlaybackFailureEvent> {
            AsyncStream { continuation in
                continuation.finish()
            }
        }

        var probeValue: String {
            [
                "item=\(itemAlias)",
                "generation=\(itemGeneration)",
                "timeMillis=\(positionMilliseconds)",
                "status=\(status)",
                "observerCount=\(activeObserverCount)",
                "installed=\(installedItem != nil && player.currentItem === installedItem ? 1 : 0)",
                "lastStopped=\(lastStoppedItemAlias)",
                "startedLoadGeneration=\(startedLoadGeneration)",
                "settledLoadGeneration=\(settledLoadGeneration)",
                "playerIdentity=\(ObjectIdentifier(player))",
                "itemIdentity=\(installedItem.map { String(describing: ObjectIdentifier($0)) } ?? "none")",
                "activeItems=\(resourceRegistry.activeItems)",
                "activeObservers=\(resourceRegistry.activeObservers)",
                "activeMediaDirectories=\(resourceRegistry.activeMediaDirectories)",
            ].joined(separator: ";")
        }

        func load(
            _ playback: VideoPlayback,
            identity: PlaybackItemIdentity,
            intent: PlaybackLoadIntent
        ) async throws {
            loadGeneration += 1
            let requestedGeneration = loadGeneration
            startedLoadGeneration = requestedGeneration
            defer {
                settledLoadGeneration = max(
                    settledLoadGeneration,
                    requestedGeneration
                )
            }

            clearCurrentItem()
            let mediaURL = try mediaStore.url(for: identity.bvid)
            if !registeredMediaDirectory {
                registeredMediaDirectory = true
                resourceRegistry.mediaDirectoryCreated()
            }
            let asset = AVURLAsset(url: mediaURL)
            let isPlayable: Bool
            do {
                isPlayable = try await asset.load(.isPlayable)
            } catch {
                guard requestedGeneration == loadGeneration else {
                    throw CancellationError()
                }
                throw error
            }
            guard requestedGeneration == loadGeneration else {
                throw CancellationError()
            }
            guard isPlayable else {
                throw UITestLocalAVPlayerError.mediaIsNotPlayable
            }

            try await Task.sleep(for: .milliseconds(200))
            try Task.checkCancellation()
            guard requestedGeneration == loadGeneration else {
                throw CancellationError()
            }

            let item = AVPlayerItem(asset: asset)
            installedItem = item
            itemAlias = identity.bvid
            itemGeneration += 1
            positionMilliseconds = 0
            status = "waiting"
            isLoaded = true
            player.replaceCurrentItem(with: item)
            resourceRegistry.itemInstalled()
            installTimeObserver(
                for: item,
                loadGeneration: requestedGeneration
            )
            player.play()
            updateStatus(at: .zero)
        }

        func pause() {
            player.pause()
            updateStatus(at: player.currentTime())
        }

        func stop() {
            loadGeneration += 1
            clearCurrentItem()
            mediaStore.removeAll()
            if registeredMediaDirectory, !mediaStore.directoryExists {
                registeredMediaDirectory = false
                resourceRegistry.mediaDirectoryRemoved()
            }
        }

        private func installTimeObserver(
            for item: AVPlayerItem,
            loadGeneration: Int
        ) {
            precondition(timeObserver == nil)
            timeObserver = player.addPeriodicTimeObserver(
                forInterval: CMTime(value: 1, timescale: 20),
                queue: .main
            ) { [weak self, weak item] time in
                Task { @MainActor in
                    guard let self, let item,
                        self.loadGeneration == loadGeneration,
                        self.installedItem === item,
                        self.player.currentItem === item
                    else {
                        return
                    }
                    self.updateStatus(at: time)
                }
            }
            resourceRegistry.observerInstalled()
        }

        private func clearCurrentItem() {
            if let timeObserver {
                player.removeTimeObserver(timeObserver)
                self.timeObserver = nil
                resourceRegistry.observerRemoved()
            }

            player.pause()
            if installedItem != nil {
                lastStoppedItemAlias = itemAlias
                resourceRegistry.itemRemoved()
            }
            player.replaceCurrentItem(with: nil)
            installedItem = nil
            itemAlias = "none"
            positionMilliseconds = 0
            status = "stopped"
            isLoaded = false
        }

        private func updateStatus(at time: CMTime) {
            if time.seconds.isFinite, time.seconds >= 0 {
                positionMilliseconds = Int(
                    (time.seconds * 1_000).rounded(.down)
                )
            }

            switch player.timeControlStatus {
            case .paused:
                status = installedItem == nil ? "stopped" : "paused"
            case .waitingToPlayAtSpecifiedRate:
                status = "waiting"
            case .playing:
                status = "playing"
            @unknown default:
                status = "unknown"
            }
        }
    }

    private enum UITestLocalAVPlayerError: Error {
        case mediaIsNotPlayable
    }

    private final class UITestLocalMediaStore {
        private let directory: URL

        var directoryExists: Bool {
            FileManager.default.fileExists(atPath: directory.path)
        }

        init() {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "BiliKitLocalAVPlayer-\(UUID().uuidString)",
                    isDirectory: true
                )
        }

        func url(for alias: String) throws -> URL {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let safeAlias = alias.filter {
                $0.isASCII
                    && ($0.isLetter || $0.isNumber || $0 == "-")
            }
            let filename = safeAlias.isEmpty ? "fixture" : safeAlias
            let url = directory.appendingPathComponent("\(filename).wav")
            guard !FileManager.default.fileExists(atPath: url.path) else {
                return url
            }

            let frequency: Double = alias.hasSuffix("B") ? 660 : 440
            try Self.waveData(frequency: frequency).write(
                to: url,
                options: .atomic
            )
            return url
        }

        func removeAll() {
            try? FileManager.default.removeItem(at: directory)
        }

        deinit {
            removeAll()
        }

        private static func waveData(frequency: Double) -> Data {
            let sampleRate: UInt32 = 8_000
            let durationSeconds: UInt32 = 8
            let bytesPerSample: UInt16 = 2
            let sampleCount = sampleRate * durationSeconds
            let dataSize = sampleCount * UInt32(bytesPerSample)

            var data = Data()
            data.append(contentsOf: Array("RIFF".utf8))
            appendLittleEndian(36 + dataSize, to: &data)
            data.append(contentsOf: Array("WAVEfmt ".utf8))
            appendLittleEndian(UInt32(16), to: &data)
            appendLittleEndian(UInt16(1), to: &data)
            appendLittleEndian(UInt16(1), to: &data)
            appendLittleEndian(sampleRate, to: &data)
            appendLittleEndian(sampleRate * UInt32(bytesPerSample), to: &data)
            appendLittleEndian(bytesPerSample, to: &data)
            appendLittleEndian(UInt16(16), to: &data)
            data.append(contentsOf: Array("data".utf8))
            appendLittleEndian(dataSize, to: &data)

            for index in 0..<sampleCount {
                let phase =
                    2 * Double.pi * frequency
                    * Double(index) / Double(sampleRate)
                let sample = Int16((sin(phase) * 4_000).rounded())
                appendLittleEndian(UInt16(bitPattern: sample), to: &data)
            }
            return data
        }

        private static func appendLittleEndian(
            _ value: UInt16,
            to data: inout Data
        ) {
            data.append(UInt8(truncatingIfNeeded: value))
            data.append(UInt8(truncatingIfNeeded: value >> 8))
        }

        private static func appendLittleEndian(
            _ value: UInt32,
            to data: inout Data
        ) {
            data.append(UInt8(truncatingIfNeeded: value))
            data.append(UInt8(truncatingIfNeeded: value >> 8))
            data.append(UInt8(truncatingIfNeeded: value >> 16))
            data.append(UInt8(truncatingIfNeeded: value >> 24))
        }
    }
#endif
