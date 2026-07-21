//
//  ContentView.swift
//  BiliKitMac
//
//  Created by shiinayane on 2026/07/21.
//

import BiliAPI
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
        VStack {
            PlayerHostView(player: playerEngine.player)
                .frame(minWidth: 640, minHeight: 360)
            Text(statusText)
                .foregroundStyle(.secondary)
        }
        .padding()
    }

    private var statusText: String {
        switch model.selectionState {
        case .idle:
            "M2 游客数据层已就绪"
        case .loading:
            "正在加载视频…"
        case .preparingPlayback:
            "正在准备播放…"
        case let .ready(context):
            context.detail.title
        case .failed:
            "加载失败"
        }
    }
}

#Preview {
    ContentView()
}
