import BiliAPI
import BiliApplication
import BiliAuth
import BiliBrowseFeature
import BiliModels
import BiliNetworking
import BiliPlayback
import Foundation
import XCTest

final class M46AuthenticatedSubtitleLifecycleProbeTests: XCTestCase {
    @MainActor
    func testAuthenticatedABASubtitleLifecycleWhenExplicitlyConfigured()
        async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let firstBVID = environment["BILIKIT_M46_PROBE_BVID_A"],
              let secondBVID = environment["BILIKIT_M46_PROBE_BVID_B"],
              Self.isValidBVID(firstBVID),
              Self.isValidBVID(secondBVID),
              firstBVID != secondBVID
        else {
            throw XCTSkip(
                "仅在显式提供两个不同的 M4.6 probe BVID 时运行签名 A/B 生命周期探针"
            )
        }

        let transportFactory: @Sendable () -> any HTTPTransport = {
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
        let api = BiliAPIClient(
            requestAuthorizer: BiliCredentialRequestAuthorizer(),
            transportFactory: transportFactory
        )
        let player = AVPlayerEngine()
        let videoModel = GuestVideoViewModel(
            useCase: GuestVideoUseCase(
                repository: BiliGuestRepository(service: api)
            ),
            playback: player
        )
        let subtitleModel = SubtitleViewModel(
            useCase: SubtitleUseCase(
                repository: BiliSubtitleRepository(client: api)
            ),
            timeline: player
        )
        defer {
            subtitleModel.reset()
            videoModel.reset()
        }

        var previousGeneration: UInt64?
        var completedSessions = 0
        var identitiesMatched = true
        var generationsAdvanced = true

        for (index, bvid) in [firstBVID, secondBVID, firstBVID].enumerated() {
            videoModel.selectVideo(bvid)
            await videoModel.waitForCurrentTask()
            guard case let .ready(context) = videoModel.state else {
                recordFailure("video-session-\(index + 1)")
                throw ProbeFailure.videoPreparationFailed(session: index + 1)
            }

            let contextIdentity = PlaybackItemIdentity(
                bvid: context.detail.bvid,
                cid: context.selectedPage.cid
            )
            let playerSnapshot = player.currentTimelineSnapshot
            identitiesMatched =
                identitiesMatched
                && playerSnapshot.identity == contextIdentity

            subtitleModel.selectVideo(contextIdentity)
            await subtitleModel.waitForCurrentTask()
            guard subtitleModel.state == .ready(contextIdentity),
                  !subtitleModel.tracks.isEmpty,
                  subtitleModel.selectedTrackID != nil
            else {
                recordFailure(
                    subtitleFailureCategory(
                        state: subtitleModel.state,
                        session: index + 1
                    )
                )
                throw ProbeFailure.subtitlePreparationFailed(
                    session: index + 1
                )
            }
            identitiesMatched =
                identitiesMatched
                && player.currentTimelineSnapshot.identity == contextIdentity

            if let previousGeneration {
                generationsAdvanced =
                    generationsAdvanced
                    && player.currentTimelineSnapshot
                        .discontinuityGeneration > previousGeneration
            }
            previousGeneration =
                player.currentTimelineSnapshot.discontinuityGeneration
            completedSessions += 1
        }

        guard completedSessions == 3,
              identitiesMatched,
              generationsAdvanced
        else {
            recordFailure("identity-or-generation")
            throw ProbeFailure.identityMismatch
        }

        subtitleModel.reset()
        await subtitleModel.waitForCurrentTask()
        videoModel.reset()
        guard player.currentTimelineSnapshot.identity == nil,
              subtitleModel.state == .idle
        else {
            recordFailure("cleanup")
            throw ProbeFailure.cleanupFailed
        }
        XCTContext.runActivity(
            named: "m46-subtitle-lifecycle sessions=3 "
                + "context-player-timeline-subtitle=equal "
                + "player-timeline-generation=advanced cleanup=complete"
        ) { _ in }
    }

    private static func isValidBVID(_ value: String) -> Bool {
        value.count == 12
            && value.hasPrefix("BV")
            && value.allSatisfy(\.isASCII)
            && value.dropFirst(2).allSatisfy {
                $0.isASCII && ($0.isLetter || $0.isNumber)
            }
    }

    private func recordFailure(_ category: String) {
        XCTContext.runActivity(
            named: "m46-subtitle-lifecycle failure=\(category)"
        ) { _ in }
    }

    private func subtitleFailureCategory(
        state: SubtitleViewState,
        session: Int
    ) -> String {
        let reason = switch state {
        case .idle:
            "idle"
        case .loadingCatalog:
            "loading-catalog"
        case .loadingTrack:
            "loading-track"
        case .ready:
            "incomplete-ready"
        case .unavailable:
            "unavailable"
        case let .failed(_, failure):
            switch failure {
            case .authenticationRequired:
                "authentication-required"
            case .requestRestricted:
                "request-restricted"
            case .invalidResponse:
                "invalid-response"
            case .unavailable:
                "failed-unavailable"
            }
        }
        return "subtitle-\(reason)-session-\(session)"
    }
}

private enum ProbeFailure: Error {
    case videoPreparationFailed(session: Int)
    case subtitlePreparationFailed(session: Int)
    case identityMismatch
    case cleanupFailed
}
