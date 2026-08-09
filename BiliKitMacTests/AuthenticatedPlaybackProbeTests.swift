import BiliAPI
import BiliModels
import BiliNetworking
import Foundation
import XCTest

@testable import BiliAuth

final class AuthenticatedPlaybackProbeTests: XCTestCase {
    @MainActor
    func testAuthenticatedPlaybackQualityWhenExplicitlyConfigured() async throws {
        guard let input = try LocalProbeInput.load() else {
            throw XCTSkip("仅在显式提供安全本机输入文件时运行登录画质探针")
        }
        Self.recordStage("input-ready")

        let anonymousTransport = Self.ephemeralTransport()
        defer { anonymousTransport.invalidateAndCancel() }
        let anonymousClient = BiliAPIClient(transport: anonymousTransport)
        let bvid: String
        if let configuredBVID = input["bvid"] {
            guard Self.isValidBVID(configuredBVID) else {
                throw ProbeFailure.invalidRequest
            }
            bvid = configuredBVID
        } else if input["select-popular-first"] == "true" {
            let page = try await anonymousClient.popular(page: 1, pageSize: 1)
            bvid = try XCTUnwrap(page.videos.first?.bvid)
        } else {
            throw ProbeFailure.invalidRequest
        }
        let pages = try await anonymousClient.pages(for: bvid)
        let cid = try XCTUnwrap(pages.first?.cid)
        let anonymous = try await anonymousClient.playback(for: bvid, cid: cid)
        Self.recordStage("anonymous-complete")

        let authenticatedTransport = Self.ephemeralTransport()
        defer { authenticatedTransport.invalidateAndCancel() }
        let authorizer = BiliCredentialRequestAuthorizer()
        guard case .signedIn = try await authorizer.restoreAccountSession() else {
            throw ProbeFailure.missingAuthenticatedSession
        }
        let authenticatedClient = BiliAPIClient(
            transport: authenticatedTransport,
            requestAuthorizer: ProbeAuthenticatedRequestAuthorizer(
                base: authorizer
            )
        )
        Self.recordStage("authenticated-started")
        let authenticated = try await authenticatedClient.playback(
            for: bvid,
            cid: cid
        )
        Self.recordStage("authenticated-complete")

        let anonymousSummary = try Self.summary(anonymous)
        let authenticatedSummary = try Self.summary(authenticated)
        let higher =
            authenticatedSummary.maximumHeight > anonymousSummary.maximumHeight
        let summary = [
            "authenticated-playback-quality",
            "anonymous-http=2xx",
            "anonymous-business=0",
            "anonymous-avc=\(anonymousSummary.videoCount)",
            "anonymous-aac=\(anonymousSummary.audioCount)",
            "anonymous-quality=\(anonymousSummary.qualityIDs)",
            "anonymous-heights=\(anonymousSummary.heights)",
            "anonymous-max-height=\(anonymousSummary.maximumHeight)",
            "authenticated-http=2xx",
            "authenticated-business=0",
            "authenticated-avc=\(authenticatedSummary.videoCount)",
            "authenticated-aac=\(authenticatedSummary.audioCount)",
            "authenticated-quality=\(authenticatedSummary.qualityIDs)",
            "authenticated-heights=\(authenticatedSummary.heights)",
            "authenticated-max-height=\(authenticatedSummary.maximumHeight)",
            "higher=\(higher)",
            "cookie-forwarded=false",
        ].joined(separator: " ")
        XCTContext.runActivity(named: summary) { _ in }
    }

    @MainActor
    private static func recordStage(_ stage: String) {
        FileHandle.standardError.write(
            Data("authenticated-playback-stage stage=\(stage)\n".utf8)
        )
        XCTContext.runActivity(
            named: "authenticated-playback-stage stage=\(stage)"
        ) { _ in }
    }

    private static func summary(_ playback: VideoPlayback) throws -> Summary {
        guard Set(playback.mediaHeaders.keys) == ["Referer", "User-Agent"],
            playback.mediaHeaders.keys.allSatisfy({
                $0.caseInsensitiveCompare("Cookie") != .orderedSame
            })
        else {
            throw ProbeFailure.credentialReachedMediaHeaders
        }
        let videos = playback.manifest.videoRepresentations
        let audio = playback.manifest.audioTracks.flatMap(\.representations)
        let heights = Array(
            Set(videos.compactMap { $0.videoAttributes?.height })
        ).sorted()
        guard let maximumHeight = heights.max() else {
            throw ProbeFailure.missingVideoRepresentation
        }
        return Summary(
            videoCount: videos.count,
            audioCount: audio.count,
            qualityIDs: videos.map(\.id).sorted(),
            heights: heights,
            maximumHeight: maximumHeight
        )
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

    private struct Summary {
        let videoCount: Int
        let audioCount: Int
        let qualityIDs: [Int]
        let heights: [Int]
        let maximumHeight: Int
    }

    private enum ProbeFailure: Error {
        case invalidRequest
        case missingAuthenticatedSession
        case missingVideoRepresentation
        case credentialReachedMediaHeaders
    }
}

private struct ProbeAuthenticatedRequestAuthorizer: HTTPRequestAuthorizing {
    let base: BiliCredentialRequestAuthorizer

    func authorize(_ request: HTTPRequest) async throws -> HTTPRequest {
        do {
            return try await base.authorize(request)
        } catch BiliRequestAuthorizationError.missingCredential {
            throw ProbeAuthorizationRaceFailure()
        }
    }
}

private struct ProbeAuthorizationRaceFailure: HTTPRequestAuthorizationFailure {
    let authorizationFailureKind = HTTPRequestAuthorizationFailureKind.denied
}
