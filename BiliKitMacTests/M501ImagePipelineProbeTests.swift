import AppKit
import Combine
import Darwin.Mach
import Foundation
@preconcurrency import Network
import SwiftUI
import XCTest

final class M501ImagePipelineProbeTests: XCTestCase {
    @MainActor
    private static var retainedProbeWindows: [NSWindow] = []

    @MainActor
    func testAsyncImageRecreationAndProtocolCacheWhenExplicitlyConfigured()
        async throws
    {
        guard
            ProcessInfo.processInfo.environment[
                "BILIKIT_M501_IMAGE_PROBE"
            ] == "1"
        else {
            throw XCTSkip("仅在显式启用 M5.0.1 图片探针时运行")
        }

        URLCache.shared.removeAllCachedResponses()
        let imageData = try Self.syntheticCoverPNG()
        let server = M501ImageLoopbackServer(imageData: imageData)
        try await server.start()
        defer {
            server.stop()
            URLCache.shared.removeAllCachedResponses()
        }

        let entryCountPerPolicy = 25
        let entries = try (0..<(entryCountPerPolicy * 2)).map { index in
            let policy: M501ImageCachePolicy =
                index < entryCountPerPolicy ? .cacheable : .noStore
            return M501ImageEntry(
                id: index,
                url: try server.url(for: index, policy: policy)
            )
        }

        let baselineRSS = Self.residentMemoryBytes()
        let firstExpectation = expectation(
            description: "first image generation completed"
        )
        let firstState = M501ImagePhaseState(
            expectedCount: entries.count,
            firstCompletion: firstExpectation.fulfill
        )
        let hostingView = NSHostingView(
            rootView: AnyView(
                M501ImageProbeGrid(entries: entries, state: firstState)
            )
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 820),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.animationBehavior = .none
        window.contentView = hostingView
        hostingView.layoutSubtreeIfNeeded()

        await fulfillment(of: [firstExpectation], timeout: 20)
        let firstCounts = server.requestCounts()
        let firstRSS = Self.residentMemoryBytes()

        hostingView.rootView = AnyView(EmptyView())
        hostingView.layoutSubtreeIfNeeded()
        await Task.yield()

        let secondExpectation = expectation(
            description: "second image generation completed"
        )
        let secondState = M501ImagePhaseState(
            expectedCount: entries.count,
            firstCompletion: secondExpectation.fulfill
        )
        hostingView.rootView = AnyView(
            M501ImageProbeGrid(entries: entries, state: secondState)
        )
        hostingView.layoutSubtreeIfNeeded()

        await fulfillment(of: [secondExpectation], timeout: 20)
        let secondCounts = server.requestCounts()
        let secondRSS = Self.residentMemoryBytes()

        hostingView.rootView = AnyView(EmptyView())
        await Task.yield()
        let cleanupRSS = Self.residentMemoryBytes()
        Self.retainedProbeWindows.append(window)

        XCTAssertEqual(firstState.successCount, entries.count)
        XCTAssertEqual(secondState.successCount, entries.count)
        XCTAssertGreaterThanOrEqual(
            firstCounts.cacheable,
            entryCountPerPolicy
        )
        XCTAssertGreaterThanOrEqual(
            firstCounts.noStore,
            entryCountPerPolicy
        )

        let cacheableRevisit = max(
            0,
            secondCounts.cacheable - firstCounts.cacheable
        )
        let noStoreRevisit = max(
            0,
            secondCounts.noStore - firstCounts.noStore
        )
        XCTContext.runActivity(
            named: [
                "m501-image-local",
                "images=\(entries.count)",
                "first-cacheable=\(firstCounts.cacheable)",
                "first-no-store=\(firstCounts.noStore)",
                "revisit-cacheable=\(cacheableRevisit)",
                "revisit-no-store=\(noStoreRevisit)",
                "success-first=\(firstState.successCount)",
                "success-second=\(secondState.successCount)",
                "rss-baseline-mib=\(Self.formattedMiB(baselineRSS))",
                "rss-first-mib=\(Self.formattedMiB(firstRSS))",
                "rss-second-mib=\(Self.formattedMiB(secondRSS))",
                "rss-cleanup-mib=\(Self.formattedMiB(cleanupRSS))",
                "cleanup=complete",
            ].joined(separator: " ")
        ) { _ in }
    }

    @MainActor
    func testLazyGridOffscreenReturnWhenExplicitlyConfigured()
        async throws
    {
        try Self.requireExplicitProbe()
        URLCache.shared.removeAllCachedResponses()
        let server = M501ImageLoopbackServer(
            imageData: try Self.syntheticCoverPNG()
        )
        try await server.start()
        defer {
            server.stop()
            URLCache.shared.removeAllCachedResponses()
        }

        let entries = try (0..<50).map { index in
            M501ImageEntry(
                id: index,
                url: try server.url(for: index, policy: .cacheable)
            )
        }
        let topExpectation = expectation(description: "top image appeared")
        let bottomExpectation = expectation(
            description: "bottom image appeared"
        )
        let topReturnExpectation = expectation(
            description: "top image reappeared"
        )
        let scrollState = M501ImageScrollState(
            topID: 0,
            bottomID: entries.count - 1,
            topCompletion: topExpectation.fulfill,
            bottomCompletion: bottomExpectation.fulfill,
            topReturnCompletion: topReturnExpectation.fulfill
        )
        let hostingView = NSHostingView(
            rootView: AnyView(
                M501ImageScrollProbeRoot(
                    entries: entries,
                    state: scrollState
                )
            )
        )
        let window = Self.probeWindow(
            contentView: hostingView,
            height: 420
        )
        defer {
            hostingView.rootView = AnyView(EmptyView())
            Self.retainedProbeWindows.append(window)
        }

        await fulfillment(of: [topExpectation], timeout: 20)
        scrollState.targetID = entries.count - 1
        await fulfillment(of: [bottomExpectation], timeout: 20)
        let bottomRequests = server.requestCounts().cacheable

        scrollState.targetID = 0
        await fulfillment(of: [topReturnExpectation], timeout: 20)
        let finalRequests = server.requestCounts().cacheable

        XCTContext.runActivity(
            named: [
                "m501-image-scroll",
                "images=\(entries.count)",
                "requests-through-bottom=\(bottomRequests)",
                "return-requests=\(max(0, finalRequests - bottomRequests))",
                "top-disappeared=\(scrollState.topDidDisappear ? 1 : 0)",
                "top-appearances=\(scrollState.topAppearanceCount)",
                "cleanup=complete",
            ].joined(separator: " ")
        ) { _ in }
    }

    private static func requireExplicitProbe() throws {
        guard
            ProcessInfo.processInfo.environment[
                "BILIKIT_M501_IMAGE_PROBE"
            ] == "1"
        else {
            throw XCTSkip("仅在显式启用 M5.0.1 图片探针时运行")
        }
    }

    @MainActor
    private static func probeWindow(
        contentView: NSView,
        height: CGFloat = 820
    ) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: height),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.animationBehavior = .none
        window.contentView = contentView
        contentView.layoutSubtreeIfNeeded()
        return window
    }

    private static func syntheticCoverPNG() throws -> Data {
        let width = 640
        let height = 360
        guard
            let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else {
            throw M501ImageProbeError.imageCreationFailed
        }
        context.setFillColor(
            CGColor(
                red: 0.12,
                green: 0.42,
                blue: 0.78,
                alpha: 1
            )
        )
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage(),
            let data = NSBitmapImageRep(cgImage: image).representation(
                using: .png,
                properties: [:]
            )
        else {
            throw M501ImageProbeError.imageCreationFailed
        }
        return data
    }

    private static func residentMemoryBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info_data_t>.stride
                / MemoryLayout<natural_t>.stride
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(
                to: integer_t.self,
                capacity: Int(count)
            ) { reboundPointer in
                task_info(
                    mach_task_self_,
                    task_flavor_t(MACH_TASK_BASIC_INFO),
                    reboundPointer,
                    &count
                )
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return UInt64(info.resident_size)
    }

    private static func formattedMiB(_ bytes: UInt64) -> String {
        String(format: "%.1f", Double(bytes) / 1_048_576)
    }
}

private struct M501ImageEntry: Identifiable {
    let id: Int
    let url: URL
}

@MainActor
private final class M501ImagePhaseState: ObservableObject {
    @Published private(set) var appearanceCounts: [Int: Int] = [:]

    private let expectedCount: Int
    private let firstCompletion: () -> Void
    private var didCompleteFirst = false

    init(
        expectedCount: Int,
        firstCompletion: @escaping () -> Void
    ) {
        self.expectedCount = expectedCount
        self.firstCompletion = firstCompletion
    }

    var successCount: Int {
        appearanceCounts.count
    }

    func recordSuccess(_ id: Int) {
        appearanceCounts[id, default: 0] += 1
        if appearanceCounts.count == expectedCount, !didCompleteFirst {
            didCompleteFirst = true
            firstCompletion()
        }
    }
}

@MainActor
private final class M501ImageScrollState: ObservableObject {
    @Published var targetID: Int?
    @Published private(set) var topDidDisappear = false
    @Published private(set) var topAppearanceCount = 0

    private let topID: Int
    private let bottomID: Int
    private let topCompletion: () -> Void
    private let bottomCompletion: () -> Void
    private let topReturnCompletion: () -> Void
    private var didCompleteTop = false
    private var didCompleteBottom = false
    private var didCompleteTopReturn = false

    init(
        topID: Int,
        bottomID: Int,
        topCompletion: @escaping () -> Void,
        bottomCompletion: @escaping () -> Void,
        topReturnCompletion: @escaping () -> Void
    ) {
        self.topID = topID
        self.bottomID = bottomID
        self.topCompletion = topCompletion
        self.bottomCompletion = bottomCompletion
        self.topReturnCompletion = topReturnCompletion
    }

    func recordAppearance(_ id: Int) {
        if id == topID {
            topAppearanceCount += 1
            if !didCompleteTop {
                didCompleteTop = true
                topCompletion()
            } else if !didCompleteTopReturn {
                didCompleteTopReturn = true
                topReturnCompletion()
            }
        } else if id == bottomID, !didCompleteBottom {
            didCompleteBottom = true
            bottomCompletion()
        }
    }

    func recordDisappearance(_ id: Int) {
        if id == topID {
            topDidDisappear = true
        }
    }
}

private struct M501ImageScrollProbeRoot: View {
    let entries: [M501ImageEntry]
    @ObservedObject var state: M501ImageScrollState

    private let columns = Array(
        repeating: GridItem(.fixed(128), spacing: 8),
        count: 5
    )

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(entries) { entry in
                        AsyncImage(url: entry.url) { phase in
                            switch phase {
                            case .success(let image):
                                image
                                    .resizable()
                                    .scaledToFill()
                                    .onAppear {
                                        state.recordAppearance(entry.id)
                                    }
                                    .onDisappear {
                                        state.recordDisappearance(entry.id)
                                    }
                            case .empty, .failure:
                                Color.clear
                            @unknown default:
                                Color.clear
                            }
                        }
                        .frame(width: 128, height: 72)
                        .clipped()
                        .id(entry.id)
                    }
                }
                .padding(16)
            }
            .onChange(of: state.targetID) { _, targetID in
                guard let targetID else { return }
                proxy.scrollTo(targetID, anchor: .center)
            }
        }
    }
}

private struct M501ImageProbeGrid: View {
    let entries: [M501ImageEntry]
    @ObservedObject var state: M501ImagePhaseState

    private let columns = Array(
        repeating: GridItem(.fixed(128), spacing: 8),
        count: 5
    )

    var body: some View {
        LazyVGrid(columns: columns, spacing: 8) {
            ForEach(entries) { entry in
                AsyncImage(url: entry.url) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                            .onAppear {
                                state.recordSuccess(entry.id)
                            }
                    case .empty, .failure:
                        Color.clear
                    @unknown default:
                        Color.clear
                    }
                }
                .frame(width: 128, height: 72)
                .clipped()
            }
        }
        .frame(width: 672)
        .padding(16)
    }
}

private enum M501ImageCachePolicy: Sendable {
    case cacheable
    case noStore
}

private struct M501ImageRequestCounts: Sendable {
    let cacheable: Int
    let noStore: Int
}

private final class M501ImageLoopbackServer: @unchecked Sendable {
    private static let maximumHeaderBytes = 16 * 1_024

    private let imageData: Data
    private let queue = DispatchQueue(
        label: "com.shiinayane.BiliKit.m501-image-probe"
    )
    private let lock = NSLock()
    private let routeToken = UUID().uuidString
        .replacingOccurrences(of: "-", with: "")
    private var listener: NWListener?
    private var port: NWEndpoint.Port?
    private var routes: [String: M501ImageCachePolicy] = [:]
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var cacheableRequestCount = 0
    private var noStoreRequestCount = 0

    init(imageData: Data) {
        self.imageData = imageData
    }

    deinit {
        stop()
    }

    func start() async throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(
            host: NWEndpoint.Host("127.0.0.1"),
            port: .any
        )
        let listener = try NWListener(using: parameters)
        let startBox = M501ImageStartContinuationBox()
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            switch state {
            case .ready:
                guard let self, let boundPort = listener?.port else {
                    startBox.resume(
                        throwing: M501ImageProbeError.listenerFailed
                    )
                    return
                }
                self.lock.withLock {
                    self.port = boundPort
                }
                startBox.resume()
            case .failed, .cancelled:
                startBox.resume(
                    throwing: M501ImageProbeError.listenerFailed
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

    func url(
        for index: Int,
        policy: M501ImageCachePolicy
    ) throws -> URL {
        guard let port = lock.withLock({ self.port }) else {
            throw M501ImageProbeError.listenerFailed
        }
        let path = "/\(routeToken)/image-\(index).png"
        lock.withLock {
            routes[path] = policy
        }
        guard
            let url = URL(
                string: "http://127.0.0.1:\(port.rawValue)\(path)"
            )
        else {
            throw M501ImageProbeError.invalidURL
        }
        return url
    }

    func requestCounts() -> M501ImageRequestCounts {
        lock.withLock {
            M501ImageRequestCounts(
                cacheable: cacheableRequestCount,
                noStore: noStoreRequestCount
            )
        }
    }

    func stop() {
        let state = lock.withLock { () -> (NWListener?, [NWConnection]) in
            let state = (listener, Array(connections.values))
            listener = nil
            port = nil
            routes.removeAll()
            connections.removeAll()
            return state
        }
        state.0?.cancel()
        for connection in state.1 {
            connection.cancel()
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
                _ = self?.lock.withLock {
                    self?.connections.removeValue(forKey: id)
                }
            default:
                break
            }
        }
        connection.start(queue: queue)
        receiveHeader(
            on: connection,
            accumulated: Data()
        )
    }

    private func receiveHeader(
        on connection: NWConnection,
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
                connection.cancel()
                return
            }
            if buffer.range(of: Data("\r\n\r\n".utf8)) != nil {
                respond(to: buffer, on: connection)
            } else if isComplete {
                connection.cancel()
            } else {
                receiveHeader(on: connection, accumulated: buffer)
            }
        }
    }

    private func respond(
        to header: Data,
        on connection: NWConnection
    ) {
        guard
            let text = String(data: header, encoding: .utf8),
            let requestLine = text.split(separator: "\r\n").first
        else {
            connection.cancel()
            return
        }
        let parts = requestLine.split(separator: " ")
        guard parts.count == 3, parts[0] == "GET" else {
            connection.cancel()
            return
        }
        let path = String(parts[1])
        guard let policy = lock.withLock({ routes[path] }) else {
            connection.cancel()
            return
        }
        lock.withLock {
            switch policy {
            case .cacheable:
                cacheableRequestCount += 1
            case .noStore:
                noStoreRequestCount += 1
            }
        }

        let cacheControl =
            policy == .cacheable
            ? "public, max-age=3600"
            : "no-store"
        let responseHead = [
            "HTTP/1.1 200 OK",
            "Cache-Control: \(cacheControl)",
            "Connection: close",
            "Content-Length: \(imageData.count)",
            "Content-Type: image/png",
            "",
            "",
        ].joined(separator: "\r\n")
        var response = Data(responseHead.utf8)
        response.append(imageData)
        connection.send(
            content: response,
            completion: .contentProcessed { _ in
                connection.cancel()
            }
        )
    }
}

private final class M501ImageStartContinuationBox: @unchecked Sendable {
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
        let continuation = lock.withLock {
            () -> CheckedContinuation<Void, any Error>? in
            guard self.result == nil else { return nil }
            self.result = result
            let continuation = self.continuation
            self.continuation = nil
            return continuation
        }
        continuation?.resume(with: result)
    }
}

private enum M501ImageProbeError: Error {
    case imageCreationFailed
    case listenerFailed
    case invalidURL
}
