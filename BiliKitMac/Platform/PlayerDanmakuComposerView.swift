import BiliApplication
import BiliModels
import BiliUI
import BiliVideoDetailFeature
import SwiftUI

/// 播放器 content overlay 上发送弹幕的输入胶囊：呼出时输入框取得焦点，回车发送，Esc 或右侧的 × 收起；「Aa」展开位置、
/// 字号与颜色一行；发送中转圈，失败时在下方说明原因并保留草稿。
///
/// 不按输入框失焦收起：点浮层上的按钮（「Aa」、颜色）也会拿走焦点，单击画面反而不会，失焦不等于用户想收起。
///
/// 放在 content overlay 里，窗口与 AVKit 独立全屏同一套。选项是胶囊上方同一浮层里的一行，不用 popover：popover 是
/// 另一个窗口，打开时输入框失去第一响应者，播放器快捷键就会重新接管按键（`PlayerKeyboardShortcutController
/// .focusedResponderOwnsKeys`）。同理发送中也不禁用输入框（禁用会让它交出焦点，失败后再改字就会触发 Q／W／E 等快捷键），
/// 重复发送由模型挡住。浮层一直挂着这个视图、收起时只淡出并禁用：被移除的视图收不到状态变化，焦点要等淡出结束才放下；
/// 一直挂着时收起当下就放下焦点，播放器快捷键马上恢复。状态与发送都在 `DanmakuComposerModel`，失败文案与写入结果胶囊
/// 同一来源（`AccountWriteStatusText`）。
struct PlayerDanmakuComposerView: View {
    @Bindable var model: DanmakuComposerModel
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(spacing: PlayerDanmakuComposerLayout.spacing) {
            if model.showsOptions {
                PlayerDanmakuOptionsRow(appearance: $model.appearance)
            }
            inputCapsule
            if let message = failureMessage {
                Text(message)
                    .font(.callout)
                    .padding(.horizontal, PlayerDanmakuComposerLayout.horizontalPadding)
                    .padding(.vertical, PlayerDanmakuComposerLayout.verticalPadding / 2)
                    .modifier(PlayerGlassCapsuleBackground())
                    .accessibilityAddTraits(.isStaticText)
            }
        }
        .frame(maxWidth: PlayerDanmakuComposerLayout.maximumWidth)
        .onExitCommand { model.dismiss() }
        // 每次呼出（含已呼出时再按回车）都把焦点交给输入框；挂上浮层时还没呼出，不抢焦点。
        .task(id: model.presentationID) {
            if model.isPresented { isFocused = true }
        }
        .onChange(of: model.isPresented) { _, isPresented in
            if !isPresented { isFocused = false }
        }
        // 失败说明在输入框下方，读屏焦点停在输入框里读不到，所以通告一次。
        .accessibilityAnnouncement(failureMessage, trigger: model.phase)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(AppStrings.localized("发送弹幕"))
    }

    private var inputCapsule: some View {
        HStack(spacing: PlayerDanmakuComposerLayout.spacing) {
            Button {
                model.showsOptions.toggle()
            } label: {
                Image(systemName: "textformat")
                    .foregroundStyle(model.showsOptions ? .primary : .secondary)
            }
            .buttonStyle(.plain)
            .help(AppStrings.localized("弹幕样式"))
            .accessibilityLabel(AppStrings.localized("弹幕样式"))
            .accessibilityValue(
                model.showsOptions ? AppStrings.localized("已展开") : AppStrings.localized("已收起")
            )
            TextField(AppStrings.localized("发个弹幕…"), text: $model.draft)
                .textFieldStyle(.plain)
                .focused($isFocused)
                .onSubmit { model.send() }
                .accessibilityLabel(AppStrings.localized("弹幕内容"))
            if model.isSending {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(AppStrings.localized("正在发送弹幕"))
            } else {
                Text(verbatim: "\(model.draft.count)/\(DanmakuPostText.maximumLength)")
                    .monospacedDigit()
                    .foregroundStyle(
                        model.draft.count > DanmakuPostText.maximumLength ? .red : .secondary
                    )
                    .accessibilityHidden(true)
            }
            Button {
                model.dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(AppStrings.localized("收起弹幕输入框（Esc）"))
            .accessibilityLabel(AppStrings.localized("收起弹幕输入框"))
        }
        .padding(.horizontal, PlayerDanmakuComposerLayout.horizontalPadding)
        .padding(.vertical, PlayerDanmakuComposerLayout.verticalPadding)
        .modifier(PlayerGlassCapsuleBackground())
    }

    private var failureMessage: String? {
        guard case .failed(let failure) = model.phase else { return nil }
        return switch failure {
        case .signInRequired:
            AppStrings.localized("登录后才能发弹幕。")
        case .noPlayback:
            AppStrings.localized("视频开始播放后才能发弹幕。")
        case .invalidText:
            AppStrings.localized("弹幕不能为空、不能换行，最多 \(DanmakuPostText.maximumLength) 个字。")
        case .coolingDown(let seconds):
            AppStrings.localized("发送太频繁，请 \(seconds) 秒后再试。")
        case .write(let report):
            AccountWriteStatusText.message(for: report)
        }
    }
}

/// 输入胶囊上方的样式一行：位置、字号与颜色，候选来自 `DanmakuPostStyle`。
private struct PlayerDanmakuOptionsRow: View {
    @Binding var appearance: DanmakuPostAppearance

    var body: some View {
        HStack(spacing: PlayerDanmakuComposerLayout.spacing * 2) {
            Picker(AppStrings.localized("位置"), selection: $appearance.mode) {
                ForEach(DanmakuPostStyle.modes, id: \.self) { mode in
                    Text(Self.title(for: mode)).tag(mode)
                }
            }
            .fixedSize()
            Picker(AppStrings.localized("字号"), selection: $appearance.fontSize) {
                ForEach(DanmakuPostStyle.fontSizes, id: \.self) { size in
                    Text(Self.title(forFontSize: size)).tag(size)
                }
            }
            .fixedSize()
            HStack(spacing: PlayerDanmakuComposerLayout.swatchSpacing) {
                ForEach(DanmakuPostStyle.colors, id: \.self) { rgb in
                    swatch(rgb)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(AppStrings.localized("颜色"))
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
        .padding(.horizontal, PlayerDanmakuComposerLayout.horizontalPadding)
        .padding(.vertical, PlayerDanmakuComposerLayout.verticalPadding)
        .modifier(PlayerGlassCapsuleBackground())
    }

    private func swatch(_ rgb: UInt32) -> some View {
        let isSelected = appearance.colorRGB == rgb
        return Button {
            appearance.colorRGB = rgb
        } label: {
            Circle()
                .fill(Self.color(rgb))
                .overlay(
                    Circle().strokeBorder(
                        .secondary,
                        lineWidth: PlayerDanmakuComposerLayout.swatchOutlineWidth
                    )
                )
                .frame(
                    width: PlayerDanmakuComposerLayout.swatchDiameter,
                    height: PlayerDanmakuComposerLayout.swatchDiameter
                )
                .padding(PlayerDanmakuComposerLayout.swatchSelectionInset)
                .overlay {
                    if isSelected {
                        Circle().strokeBorder(
                            .primary,
                            lineWidth: PlayerDanmakuComposerLayout.swatchSelectionWidth
                        )
                    }
                }
        }
        .buttonStyle(.plain)
        .help(Self.colorName(rgb))
        .accessibilityLabel(Self.colorName(rgb))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private static func title(for mode: DanmakuPresentationMode) -> String {
        switch mode {
        case .scrolling: AppStrings.localized("滚动")
        case .top: AppStrings.localized("顶部")
        case .bottom: AppStrings.localized("底部")
        }
    }

    private static func title(forFontSize size: Double) -> String {
        size < DanmakuEvent.standardFontSize
            ? AppStrings.localized("小字") : AppStrings.localized("标准字号")
    }

    private static func color(_ rgb: UInt32) -> Color {
        Color(
            .sRGB,
            red: Double((rgb >> 16) & 0xFF) / 255,
            green: Double((rgb >> 8) & 0xFF) / 255,
            blue: Double(rgb & 0xFF) / 255
        )
    }

    /// 读屏与悬停提示用的颜色名，按 `DanmakuPostStyle.colors` 的顺序；候选增加而这里没跟上时只读“颜色”，不读错名字。
    private static func colorName(_ rgb: UInt32) -> String {
        switch DanmakuPostStyle.colors.firstIndex(of: rgb) {
        case 0: AppStrings.localized("白色")
        case 1: AppStrings.localized("红色")
        case 2: AppStrings.localized("橙色")
        case 3: AppStrings.localized("黄色")
        case 4: AppStrings.localized("绿色")
        case 5: AppStrings.localized("青色")
        case 6: AppStrings.localized("蓝色")
        case 7: AppStrings.localized("紫色")
        default: AppStrings.localized("颜色")
        }
    }
}

/// 弹幕输入胶囊的几何与动效。
enum PlayerDanmakuComposerLayout {
    /// 胶囊最宽多少：够写满一条 100 字的弹幕的一部分，又不在宽屏全屏时横贯整个画面。
    static let maximumWidth: CGFloat = 520
    static let spacing: CGFloat = 8
    static let horizontalPadding: CGFloat = 14
    static let verticalPadding: CGFloat = 9
    static let swatchDiameter: CGFloat = 14
    /// 色块的细描边，让白色色块在浅色玻璃上也看得出边界。
    static let swatchOutlineWidth: CGFloat = 0.5
    static let swatchSelectionWidth: CGFloat = 1.5
    /// 选中圈与色块之间的间隙。
    static let swatchSelectionInset: CGFloat = 2
    static let swatchSpacing: CGFloat = 4
    /// 呼出与收起的淡入淡出时长，与播放器上“从头播放”按钮的淡出相同。
    static let fadeDurationSeconds = PlayerResumeNoticeDismissalPolicy.fadeDurationSeconds
}
