//
//  ContentView.swift
//  BiliKitMac
//
//  Created by shiinayane on 2026/07/21.
//

import BiliAuthFeature
import BiliGuestFeature
import BiliHistoryFeature
import SwiftUI

struct ContentView: View {
    @State private var feedModel: GuestFeedViewModel
    @State private var videoModel: GuestVideoViewModel
    @State private var authenticationModel: AuthenticationViewModel
    @State private var historyModel: WatchHistoryViewModel
    @State private var isAuthenticationPresented = false
    @State private var isHistoryPresented = false
    @State private var requestedBVID: String?
    private let playerContent: AnyView

    init(environment: AppEnvironment = .live) {
        _feedModel = State(initialValue: environment.makeFeedViewModel())
        _videoModel = State(initialValue: environment.makeVideoViewModel())
        _authenticationModel = State(
            initialValue: environment.makeAuthenticationViewModel()
        )
        _historyModel = State(
            initialValue: environment.makeWatchHistoryViewModel()
        )
        playerContent = environment.makePlayerView()
    }

    var body: some View {
        GuestNavigationView(
            feedModel: feedModel,
            videoModel: videoModel,
            requestedBVID: $requestedBVID
        ) {
            playerContent
        }
        .frame(minWidth: 1_080, minHeight: 680)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    if authenticationModel.isSignedIn {
                        isHistoryPresented = true
                    } else {
                        isAuthenticationPresented = true
                    }
                } label: {
                    Label("观看历史", systemImage: "clock.arrow.circlepath")
                }
                .accessibilityIdentifier("toolbar.history")
            }
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
        .sheet(isPresented: $isHistoryPresented) {
            WatchHistoryView(
                model: historyModel,
                onSelect: { bvid in
                    requestedBVID = bvid
                    isHistoryPresented = false
                },
                onAuthenticationRequired: {
                    isHistoryPresented = false
                    historyModel.reset()
                    authenticationModel.revalidate()
                    isAuthenticationPresented = true
                }
            )
        }
        .task {
            authenticationModel.restoreIfNeeded()
            await authenticationModel.waitForCurrentTask()
        }
        .onChange(of: authenticationModel.isSignedIn) { _, isSignedIn in
            guard !isSignedIn else { return }
            isHistoryPresented = false
            historyModel.reset()
        }
        .onDisappear {
            feedModel.cancel()
            videoModel.reset()
            authenticationModel.cancelTransientWork()
            historyModel.cancelTransientWork()
        }
    }
}

#Preview {
    ContentView()
}
