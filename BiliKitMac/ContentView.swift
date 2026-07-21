//
//  ContentView.swift
//  BiliKitMac
//
//  Created by shiinayane on 2026/07/21.
//

import BiliPlayback
import SwiftUI

struct ContentView: View {
    @State private var model: GuestAppModel
    private let playerEngine: AVPlayerEngine

    init(environment: AppEnvironment = .live) {
        _model = State(initialValue: environment.makeGuestAppModel())
        playerEngine = environment.playerEngine
    }

    var body: some View {
        GuestNavigationView(
            model: model,
            playerEngine: playerEngine
        )
        .frame(minWidth: 1_080, minHeight: 680)
        .onDisappear {
            Task {
                await model.cancel()
            }
        }
    }
}

#Preview {
    ContentView()
}
