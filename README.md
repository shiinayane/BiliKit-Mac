<p align="center">
  <img
    src="Design/AppIcon/v1/Marketing/BiliKit-AppIcon-Default-256.png"
    width="136"
    height="136"
    alt="BiliKit App Icon Default"
  >
  &nbsp;&nbsp;
  <img
    src="Design/AppIcon/v1/Marketing/BiliKit-AppIcon-Dark-256.png"
    width="136"
    height="136"
    alt="BiliKit App Icon Dark"
  >
</p>

<h1 align="center">BiliKit</h1>

<p align="center"><strong>在 Mac 上，好好看 B 站。</strong></p>

<p align="center">第三方开源 B 站客户端，用 Mac 原生技术写成</p>

<p align="center">
  <img alt="平台 macOS 15+" src="https://img.shields.io/badge/macOS-15%2B-195CFF?style=flat">
  <img alt="Apple Silicon" src="https://img.shields.io/badge/Apple%20Silicon-arm64-195CFF?style=flat">
  <img alt="Swift 6" src="https://img.shields.io/badge/Swift-6-FF607A?style=flat">
  <a href="https://github.com/shiinayane/BiliKit-Mac/releases/latest"><img alt="最新版本" src="https://img.shields.io/github/v/release/shiinayane/BiliKit-Mac?label=%E7%89%88%E6%9C%AC&color=FF607A&style=flat"></a>
  <a href="LICENSE"><img alt="MIT License" src="https://img.shields.io/badge/许可证-MIT-4A5568?style=flat"></a>
</p>

<p align="center">
  <a href="https://github.com/shiinayane/BiliKit-Mac/releases/latest"><strong>下载 BiliKit</strong></a>
</p>

<p align="center">
  <strong>简体中文</strong> · <a href="README.en.md">English</a> · <a href="README.ja.md">日本語</a>
</p>

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="Design/Marketing/v2/BiliKit-Home-Dark.png">
    <img src="Design/Marketing/v2/BiliKit-Home-Light.png" alt="BiliKit 首页：侧栏的资料库与收藏夹，右侧是推荐视频网格">
  </picture>
</p>

## 为什么用 BiliKit

### 轻，而且快

原生 Mac App，不是套了壳的网页：安装包不到 10 MB，运行内存百兆级。视频网格、评论和弹幕这些对性能敏感的地方用 AppKit 和 Core Animation 绘制，播放交给系统的 AVPlayer。

### 为看视频设计的播放页

简介、评论和相关推荐就在播放器旁边，评论里的时间戳点一下就跳过去。弹幕和画面共用一条时间轴，拖动、暂停、倍速都不会错位。播放结束后可以按分 P 和合集接着播，不会跳去相关推荐；点开 UP 主，可以在侧栏顺着投稿看下去，正在播放的视频不中断。

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="Design/Marketing/v2/BiliKit-Video-Detail-Dark.png">
    <img src="Design/Marketing/v2/BiliKit-Video-Detail-Light.png" alt="BiliKit 视频页：播放器上的弹幕与字幕，侧栏的简介与评论，下方的相关推荐">
  </picture>
</p>

### 一个真正的 Mac App

一个窗口、一条侧栏：推荐、搜索、稍后再看和每个收藏夹都在里面，返回时列表停在原来的位置。右键菜单、键盘快捷键、画中画、媒体键和控制中心都按 Mac 的习惯来；登录信息只存在钥匙串里，界面跟随系统语言（简体中文、繁体中文、英文和日文）。

### 和网页版、官方客户端比

|  | 网页版 / 官方 Mac 客户端 | BiliKit |
| --- | --- | --- |
| 安装包 | 官方客户端近 200 MB | 不到 10 MB |
| 运行内存 | 官方客户端常常上 GB | 百兆级 |
| 推荐流 | 夹着推广、直播和各种弹窗 | 只有视频，推广卡片和非视频条目被过滤 |
| 看完一个视频 | 新标签页越开越多，回不到刚才的列表 | 同一个窗口里返回，列表停在原来的位置 |
| 播放器 | 网页播放器 | 系统播放器：画中画、全屏、媒体键、控制中心 |
| 不登录时 | 清晰度受限 | 可以选 720P 和 1080P |

<sub>官方客户端基于 Electron，技术栈与安装包大小取自其官方下载地址（`pc_electron_mac/bili_mac.dmg`，2026 年 9 月）。</sub>

## 快捷键

| 按键 | 作用 |
| --- | --- |
| 空格 | 播放 / 暂停 |
| ← / → | 后退 / 前进 5 秒 |
| 按住 ← / → | 临时 0.5 倍 / 2 倍速，松开恢复 |
| ↑ / ↓ | 音量 |
| D | 弹幕开关 |
| C | 字幕开关 |
| F | 进入 / 退出全屏 |
| Q | 点赞 / 取消点赞（登录后） |
| 按住 Q | 三连（登录后） |
| W | 投币（登录后） |
| E | 收藏到…（登录后） |

## 安装

1. 下载[最新版 DMG](https://github.com/shiinayane/BiliKit-Mac/releases/latest)。
2. 把 BiliKit 拖进“应用程序”，打开即可。

安装包经 Apple 签名和公证，新版本会在应用内提示。

也可以用 Homebrew 安装：

```sh
brew tap shiinayane/tap
brew trust --cask shiinayane/tap/bilikit
brew install --cask shiinayane/tap/bilikit
```

需要 Apple Silicon Mac（M 系列芯片）和 macOS 15 或更高版本。Intel Mac 请使用
[1.0.0](https://github.com/shiinayane/BiliKit-Mac/releases/tag/v1.0.0)，这是最后一个支持 Intel 的版本。
安装、卸载和更新的细节见[分发说明](DISTRIBUTION.md)。

## 常见问题

<details>
<summary>这是官方客户端吗？</summary>

不是。BiliKit 是第三方开源项目，和哔哩哔哩没有隶属、认可或赞助关系。
</details>

<details>
<summary>登录安全吗？</summary>

用 B 站 App 扫官方二维码登录，观看进度会同步到你的 B 站观看历史。登录信息只保存在这台 Mac 的钥匙串里，不同步到 iCloud。
除了检查更新用的更新源，BiliKit 没有自己的服务器，也没有统计或广告 SDK，点赞、投币和收藏只在你自己操作时发出，不会替你关注或做别的操作。详见[隐私说明](PRIVACY.md)。
</details>

<details>
<summary>会支持下载、直播或多账号吗？</summary>

不会。这些都不在计划里，BiliKit 只想把看视频这件事做好。其余计划见[路线图](docs/ROADMAP.md)。
</details>

<details>
<summary>从源码构建</summary>

用 Xcode 打开 `BiliKitMac.xcodeproj`，选择 `BiliKitMac` scheme 和 “My Mac” 运行。完整检查：

```sh
sh Scripts/run-quality-gates.sh app
```

[架构](docs/ARCHITECTURE.md) · [安全模型](docs/SECURITY-MODEL.md) · [发布流程](docs/release/README.md) ·
[安全问题报告](SECURITY.md) · [App Icon 源文件](Design/AppIcon/v1/) · [宣传截图](Design/Marketing/v2/)
</details>

## 许可证与声明

源代码使用 [MIT License](LICENSE)。BiliKit 名称、图标和宣传素材不在 MIT 授权范围内，见
[品牌资产权利声明](BRAND-ASSETS.md)；第三方依赖见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
哔哩哔哩相关名称与商标归其权利人所有。
