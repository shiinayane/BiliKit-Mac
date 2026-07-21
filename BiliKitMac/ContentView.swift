//
//  ContentView.swift
//  BiliKitMac
//
//  Created by shiinayane on 2026/07/21.
//

import BiliPlayback
import SwiftUI

struct ContentView: View {
    private let playerEngine: AVPlayerEngine

    init(environment: AppEnvironment = .live) {
        playerEngine = environment.playerEngine
    }

    var body: some View {
        VStack {
            PlayerHostView(player: playerEngine.player)
                .frame(minWidth: 640, minHeight: 360)
            Text("M1 playback spike")
                .foregroundStyle(.secondary)
        }
        .padding()
    }
}

#Preview {
    ContentView()
}
