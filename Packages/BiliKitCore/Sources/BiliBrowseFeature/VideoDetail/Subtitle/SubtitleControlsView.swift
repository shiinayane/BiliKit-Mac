import BiliModels
import SwiftUI

struct SubtitleControlsView: View {
    let model: SubtitleViewModel

    var body: some View {
        HStack(spacing: 12) {
            Label("字幕", systemImage: "captions.bubble")
                .font(.headline)

            Spacer()

            switch model.state {
            case .idle, .loadingCatalog:
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("正在加载字幕")
            case .unavailable:
                Text("此视频没有可用字幕")
                    .foregroundStyle(.secondary)
            case let .failed(_, failure):
                Text(failure.message)
                    .foregroundStyle(.secondary)
                Button("重试", action: model.retry)
            case .loadingTrack, .ready:
                Picker(
                    "字幕轨道",
                    selection: Binding(
                        get: { model.selectedTrackID },
                        set: { model.selectTrack($0) }
                    )
                ) {
                    Text("关闭").tag(String?.none)
                    ForEach(model.tracks) { track in
                        Text(track.label).tag(Optional(track.id))
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 220)

                if case .loadingTrack = model.state {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("正在载入字幕轨道")
                }
            }
        }
        .accessibilityIdentifier("subtitle.controls")
    }
}

private extension SubtitleFailure {
    var message: String {
        switch self {
        case .authenticationRequired:
            "登录后可查看字幕"
        case .requestRestricted:
            "字幕暂时不可用"
        case .invalidResponse:
            "字幕格式暂不支持"
        case .unavailable:
            "字幕加载失败"
        }
    }
}

private extension SubtitleTrack {
    var label: String {
        switch kind {
        case .standard:
            displayName
        case .automatic:
            "\(displayName)（自动生成）"
        }
    }
}
