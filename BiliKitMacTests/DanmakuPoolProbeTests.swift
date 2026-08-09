import BiliApplication
import BiliModels
import BiliNetworking
import Foundation
import XCTest

#if DEBUG
    @testable import BiliAPI
    @testable import BiliAuth

    final class DanmakuPoolProbeTests: XCTestCase {
        @MainActor
        func testPoolVariantsWhenExplicitlyConfigured() async throws {
            guard let input = try LocalProbeInput.load(),
                let bvid = input["bvid"],
                Self.isValidBVID(bvid)
            else {
                throw XCTSkip("仅在显式提供安全本机输入文件时运行弹幕池探针")
            }
            Self.recordStage("input-ready")

            let anonymousTransport = Self.ephemeralTransport()
            defer { anonymousTransport.invalidateAndCancel() }
            let anonymousClient = BiliAPIClient(transport: anonymousTransport)
            let pages = try await anonymousClient.pages(for: bvid)
            guard let cid = pages.first?.cid else {
                throw ProbeFailure.missingVideoPage
            }
            let identity = PlaybackItemIdentity(bvid: bvid, cid: cid)

            let wbiAnonymous = await Self.outcome {
                try await anonymousClient.danmakuPoolProbe(
                    index: 1,
                    for: identity
                )
            }
            Self.recordStage("anonymous-complete")

            let authorizer = BiliCredentialRequestAuthorizer()
            guard case .signedIn = try await authorizer.restoreAccountSession() else {
                throw ProbeFailure.missingAuthenticatedSession
            }
            let authenticatedTransport = Self.ephemeralTransport()
            defer { authenticatedTransport.invalidateAndCancel() }
            let authenticatedClient = BiliAPIClient(
                transport: authenticatedTransport,
                requestAuthorizer: authorizer
            )
            let wbiAuthenticated = await Self.outcome {
                try await authenticatedClient.danmakuPoolProbe(
                    index: 1,
                    for: identity
                )
            }
            Self.recordStage("authenticated-complete")

            let summary = [
                "danmaku-pool-spike",
                "wbi-anonymous=\(wbiAnonymous)",
                "wbi-authenticated=\(wbiAuthenticated)",
            ].joined(separator: " ")
            XCTContext.runActivity(named: summary) { _ in }
        }

        private static func outcome(
            _ operation: () async throws -> DanmakuPoolProbeSummary
        ) async -> String {
            do {
                let summary = try await operation()
                let modes = summary.rawModeCounts
                    .sorted { $0.key < $1.key }
                    .map { "\($0.key)x\($0.value)" }
                    .joined(separator: "_")
                return [
                    "ready",
                    "bytes-\(summary.bytes)",
                    "raw-\(summary.rawEventCount)",
                    "basic-\(summary.basicEventCount)",
                    "modes-\(modes.isEmpty ? "none" : modes)",
                ].joined(separator: "_")
            } catch let error as BiliAPIError {
                return error.description
            } catch is CancellationError {
                return "cancelled"
            } catch {
                return "unexpected-error"
            }
        }

        @MainActor
        private static func recordStage(_ stage: String) {
            let value = "danmaku-pool-stage stage=\(stage)"
            FileHandle.standardError.write(Data("\(value)\n".utf8))
            XCTContext.runActivity(named: value) { _ in }
        }

        private static func ephemeralTransport() -> URLSessionTransport {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpShouldSetCookies = false
            configuration.httpCookieStorage = nil
            configuration.urlCache = nil
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.timeoutIntervalForRequest = 15
            configuration.timeoutIntervalForResource = 30
            return URLSessionTransport(
                configuration: configuration,
                redirectPolicy: .reject
            )
        }

        private static func isValidBVID(_ value: String) -> Bool {
            value.count == 12
                && value.hasPrefix("BV")
                && value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
        }

        private enum ProbeFailure: Error {
            case missingVideoPage
            case missingAuthenticatedSession
        }
    }
#endif
