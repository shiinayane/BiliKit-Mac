//
//  ContentView.swift
//  BiliKitMac
//
//  Created by shiinayane on 2026/07/21.
//

import BiliAuthFeature
import BiliGuestFeature
import SwiftUI

struct ContentView: View {
    @State private var feedModel: GuestFeedViewModel
    @State private var videoModel: GuestVideoViewModel
    @State private var authenticationModel: AuthenticationViewModel
    @State private var isAuthenticationPresented = false
    private let playerContent: AnyView

    init(environment: AppEnvironment = .live) {
        _feedModel = State(initialValue: environment.makeFeedViewModel())
        _videoModel = State(initialValue: environment.makeVideoViewModel())
        _authenticationModel = State(
            initialValue: environment.makeAuthenticationViewModel()
        )
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
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    isAuthenticationPresented = true
                } label: {
                    Label("账号", systemImage: "person.crop.circle")
                }
                .accessibilityIdentifier("toolbar.account")
            }
        }
        .sheet(isPresented: $isAuthenticationPresented) {
            AuthenticationView(model: authenticationModel)
        }
        .onDisappear {
            feedModel.cancel()
            videoModel.reset()
            authenticationModel.cancelTransientWork()
        }
    }
}

#Preview {
    ContentView()
}
