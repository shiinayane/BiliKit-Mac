# V1 核心能力证据索引

这些记录保留了无法仅由单元测试替代的真实网络、签名 App、系统播放器、安全和性能证据。
它们是带日期的复核材料，不是当前发布合格证明。

| 记录 | 保留原因 | 主要边界 |
| --- | --- | --- |
| [`M1 播放可行性`](../validation/M1-real-playback-2026-07-21.md) | macOS 15 云端与本机真实媒体轨道、受控播放回归 | 样本有限，不代表当前服务端与全部 codec |
| [`M3 Keychain 与授权`](../validation/M3-keychain-authorization-2026-07-21.md) | 签名 test host 的 Keychain 与请求授权边界 | 不证明 Developer ID、升级、卸载或换签名 |
| [`M4 总收口`](../validation/M4-closeout-2026-07-23.md) | 真实 App、长时 probe、scheduler 和资源收口 | 单机、带日期，不是全局性能保证 |
| [`播放器输入、全屏与 PiP`](../validation/M5.0-player-input-fullscreen-pip-2026-08-07.md) | 系统输入、engine ownership 和生命周期契约 | 未覆盖所有硬件、辅助功能与窗口组合 |
| [`登录态自动画质`](../validation/authenticated-playback-quality-2026-08-08.md) | 登录路径、失败安全和单 item 原生 ABR | 不承诺 4K、HEVC/AV1 或服务端长期稳定 |
| [`AVPlayer 原生字幕`](../validation/native-avplayer-subtitles-2026-08-07.md) | 原生字幕呈现和真实观察 | 样本、样式、VoiceOver 与非对白字幕有限 |
| [`语义音轨与 HLS metadata`](../validation/semantic-audio-hls-stage7-2026-08-09.md) | media selection、I-frame 与 A→B→A 清理 | 登录内容和可用音轨受服务端影响 |
| [`充电专属 durl 试看`](../validation/upower-progressive-preview-2026-08-23.md) | progressive preview 的生产合同与结束边界 | 只覆盖记录中的公开响应和 fresh App 样本 |

发布前仍必须重新取得当前 Release/Archive、签名、公证、staple、Gatekeeper、干净账户安装、
真实 Intel、VoiceOver/FKA 和隐私声明等证据；详见
[`release/CHECKLIST.md`](../release/CHECKLIST.md)。
