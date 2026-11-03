import AppKit

/// UP 主名片晚于详情到达时的过渡。
///
/// 名字颜色、计数与签名在 UP 主行自身的一次淡入里换成结果，而不是瞬间跳变。UP 主行在名片各状态下
/// 等高（按三行都在时计算，见 `NativePlaybackUploaderGeometry`），下方行不会位移，所以过渡只需要覆盖这一行，可以用
/// `NativePlaybackSidebarFade.crossfade`。
@MainActor
enum NativePlaybackUploaderProfileReveal {
    /// 同一行原地从“名片加载中”变为结果；首次配置与复用后的配置都不算。
    static func fades(
        from previous: VideoUploaderHeaderContent?,
        to next: VideoUploaderHeaderContent
    ) -> Bool {
        previous?.isProfileLoading == true && !next.isProfileLoading
    }
}
