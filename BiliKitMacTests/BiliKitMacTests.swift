//
//  BiliKitMacTests.swift
//  BiliKitMacTests
//
//  Created by shiinayane on 2026/07/21.
//

import BiliModels
import BiliPlayback
import Testing
@testable import BiliKit

struct BiliKitMacTests {
    @Test
    @MainActor
    func liveEnvironmentCreatesPlaybackRequest() {
        let manifest = PlaybackManifest(
            videoRepresentations: [],
            audioRepresentations: []
        )

        let request = AppEnvironment.live.makePlaybackRequest(manifest)

        #expect(request.manifest == manifest)
        #expect(request.preferredVideoRepresentationID == nil)
        #expect(request.preferredAudioRepresentationID == nil)
        #expect(request.mediaHeaders.isEmpty)
    }
}
