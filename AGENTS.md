# BiliKit 仓库说明

本文件只保留每次任务都需要知道、且不能可靠地从代码中推导的项目规则。

## 项目

BiliKit 是原生、macOS-first、第三方且非官方的 B 站浏览与播放客户端，使用 Swift 6、
SwiftUI 和 AVPlayer，最低支持 macOS 15。App 产品与公开 Swift 模块名为 `BiliKit`；
仓库、Xcode 工程和内部 App target 保留 `BiliKitMac`。

当前产品范围和实施顺序见 [`docs/ROADMAP.md`](docs/ROADMAP.md)。不要擅自加入下载、转码、
媒体导出、直播、多账号、区域解锁或复杂写操作。

## 代码边界

```text
Bili*Feature ──> BiliApplication ──> BiliModels
                         ↑ ports
             BiliAPI / BiliAuth / BiliPlayback
                         └──> BiliNetworking

BiliKit App = App/ + Composition/ + Platform/
```

- Feature 之间不直接 import；跨页面协调留在 App 层。
- `BiliApplication` 不出现 endpoint DTO、SwiftUI/AppKit/AVKit、具体 client、Keychain
  或 Cookie；具体 adapter 只在 Composition 可见。
- 继续使用一个仓库内 Swift Package；没有真实发布或工具链边界时不增加第二个
  `Package.swift`，不创建空 target、占位 Repository 或 `Common`/`Shared`/`Utils`。
- 依赖方向由 `Scripts/check-architecture.sh` 检查，不能绕过脚本。
- `references/` 只用于研究，不进入 target、fixture 或发布包；实现不得复制第三方源码。

## 安全与运行时

- Cookie、QR key、token、refresh token 和完整认证 URL 只存在于 `BiliAuth` 的短生命周期
  内存与 Keychain，不进入 Feature、UserDefaults、日志、fixture、截图或验证记录。
- 认证、远端来源、重定向、本地服务器、字幕、弹幕或缓存改动先读取对应
  `docs/security/` 文档，并覆盖失败路径。
- 可变网络、认证和播放会话必须有明确 owner、取消和清理点；旧结果用 identity 或
  generation 隔离。页面关闭、登出、切换视频和替换播放项后不能留下活动资源。
- 游客 API、图片、媒体 CDN 和 loopback 请求不得携带认证授权器；loopback server
  只绑定 `127.0.0.1`。
- Probe 和 fixture 不保存个人内容、秘密、完整远端响应或未脱敏 URL。

## 工作与验证

- 修改前读取相关代码、测试、ADR、路线图和威胁模型。用户要求定义结果；现有实现和旧计划
  只描述历史，不限制根据新证据调整实现。
- 修复优先复现问题；异步测试使用事件、状态或 continuation 判断完成，固定时间只作超时。
- 外部 CLI 在受限网络中报告认证或连接失败时，先在获准联网的等价只读环境复核，
  不要直接要求用户重新登录或修改凭据。
- 保留已有工作树改动。没有用户明确要求时，不提交、不推送、不创建 PR、不改写 Git 历史。
- reviewer、subagent、Plan mode 和专项 Skill 都按任务需要使用，不是必经流程。

每次只运行覆盖改动的最高一层：

```sh
sh Scripts/run-quality-gates.sh static   # 文档、脚本和静态配置
sh Scripts/run-quality-gates.sh package  # Package 代码；包含 static
sh Scripts/run-quality-gates.sh app      # App/Xcode/composition；包含 package
```

涉及签名、Keychain、真实 UI、播放或性能时，再运行能够观察该行为的真实检查；build、mock、
截图和一次 trace 不能互相替代。只有实际证据支持时才更新路线图完成状态。
