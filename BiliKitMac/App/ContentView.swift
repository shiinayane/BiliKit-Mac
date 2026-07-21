//
//  ContentView.swift
//  BiliKitMac
//
//  Created by shiinayane on 2026/07/21.
//

import BiliGuestFeature
import SwiftUI

struct ContentView: View {
    @State private var feedModel: GuestFeedViewModel
    @State private var videoModel: GuestVideoViewModel
    private let playerContent: AnyView

    init(environment: AppEnvironment = .live) {
        _feedModel = State(initialValue: environment.makeFeedViewModel())
        _videoModel = State(initialValue: environment.makeVideoViewModel())
        playerContent = environment.makePlayerView()
    }

    var body: some View {
        GuestNavigationView(
            feedModel: feedModel,
            videoModel: videoModel
        ) {
            playerContent
        }
        .frame(minWidth: 1_080, minHeight: 680)
        .onDisappear {
            feedModel.cancel()
            videoModel.reset()
        }
    }
}

#Preview {
    ContentView()
}
