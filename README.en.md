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

<p align="center"><strong>Bilibili, done right on the Mac.</strong></p>

<p align="center">An unofficial, open-source Bilibili client built with native Mac technologies</p>

<p align="center">
  <img alt="macOS 15+" src="https://img.shields.io/badge/macOS-15%2B-195CFF?style=flat">
  <img alt="Apple Silicon" src="https://img.shields.io/badge/Apple%20Silicon-arm64-195CFF?style=flat">
  <img alt="Swift 6" src="https://img.shields.io/badge/Swift-6-FF607A?style=flat">
  <a href="https://github.com/shiinayane/BiliKit-Mac/releases/latest"><img alt="Latest release" src="https://img.shields.io/github/v/release/shiinayane/BiliKit-Mac?label=release&color=FF607A&style=flat"></a>
  <a href="LICENSE"><img alt="MIT License" src="https://img.shields.io/badge/license-MIT-4A5568?style=flat"></a>
</p>

<p align="center">
  <a href="https://github.com/shiinayane/BiliKit-Mac/releases/latest"><strong>Download BiliKit</strong></a>
</p>

<p align="center">
  <a href="README.md">简体中文</a> · <strong>English</strong> · <a href="README.ja.md">日本語</a>
</p>

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="Design/Marketing/v2/BiliKit-Home-Dark.png">
    <img src="Design/Marketing/v2/BiliKit-Home-Light.png" alt="BiliKit Home: Library and Favorites in the sidebar, a grid of recommended videos on the right">
  </picture>
</p>

## Why BiliKit

### Light and fast

A native Mac app, not a web page in a wrapper: under 10 MB to download and a few hundred MB of memory. Performance-sensitive parts such as video grids, comments and danmaku are drawn with AppKit and Core Animation, and playback runs on the system's AVPlayer.

### A video page built for watching

The description, comments and related videos sit right next to the player, and a timestamp in a comment jumps there with one click. Danmaku share the video's timeline, so seeking, pausing and changing speed never put them out of sync. When playback ends, BiliKit can continue through episodes and collections without wandering off into related videos; click an uploader to keep watching through their uploads in the sidebar without interrupting the current video.

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="Design/Marketing/v2/BiliKit-Video-Detail-Dark.png">
    <img src="Design/Marketing/v2/BiliKit-Video-Detail-Light.png" alt="BiliKit video page: danmaku and subtitles over the player, description and comments in the sidebar, related videos below">
  </picture>
</p>

### A real Mac app

One window, one sidebar: Home, Search, Watch Later and each of your favorites folders live there, and going back returns you to the list right where you left it. Right-click menus, keyboard shortcuts, Picture in Picture, media keys and Control Center work the way they do on a Mac; your sign-in information stays in the keychain, and the interface follows your system language (Simplified Chinese, Traditional Chinese, English and Japanese).

### Compared with the website and the official client

|  | Website / official Mac client | BiliKit |
| --- | --- | --- |
| Download size | Official client is close to 200 MB | Under 10 MB |
| Memory use | Official client often exceeds 1 GB | A few hundred MB |
| Recommendations | Mixed with ads, live streams and pop-ups | Videos only; promoted cards and non-video items are filtered out |
| After watching a video | Tabs keep piling up and the list you came from is gone | Go back in the same window, with the list right where you left it |
| Player | Web player | System player: Picture in Picture, full screen, media keys, Control Center |
| Without signing in | Limited resolution | 720P and 1080P available |

<sub>The official client is built on Electron; its tech stack and download size come from its official download (`pc_electron_mac/bili_mac.dmg`, September 2026).</sub>

## Keyboard shortcuts

| Key | Action |
| --- | --- |
| Space | Play / pause |
| ← / → | Back / forward 5 seconds |
| Hold ← / → | Temporarily play at 0.5× / 2×, back to normal on release |
| ↑ / ↓ | Volume |
| D | Toggle danmaku |
| C | Toggle subtitles |
| F | Enter / exit full screen |
| Q | Like / remove like (signed in) |
| Hold Q | Like, Coin, and Save (signed in) |
| W | Coin (signed in) |
| E | Save to Favorites… (signed in) |

## Installation

1. Download the [latest DMG](https://github.com/shiinayane/BiliKit-Mac/releases/latest).
2. Drag BiliKit into Applications and open it.

The installer is signed and notarized by Apple, and new versions are announced in the app.

You can also install it with Homebrew:

```sh
brew tap shiinayane/tap
brew trust --cask shiinayane/tap/bilikit
brew install --cask shiinayane/tap/bilikit
```

Requires an Apple Silicon Mac (M-series chip) and macOS 15 or later. On an Intel Mac, use
[1.0.0](https://github.com/shiinayane/BiliKit-Mac/releases/tag/v1.0.0), the last version that supports Intel.
For details on installing, uninstalling and updating, see the [distribution notes](DISTRIBUTION.md) (in Chinese).

## FAQ

<details>
<summary>Is this the official client?</summary>

No. BiliKit is an unofficial open-source project and is not affiliated with, endorsed or sponsored by Bilibili.
</details>

<details>
<summary>Is signing in safe?</summary>

You sign in by scanning Bilibili's official QR code with the Bilibili app, and your watch progress syncs to your Bilibili watch history. Your sign-in information is stored only in this Mac's keychain and is not synced to iCloud.
Apart from the update feed used to check for updates, BiliKit has no servers of its own and no analytics or ad SDKs, and it only likes, coins or saves when you do it yourself; it never follows or does anything else on your behalf. See the [privacy notes](PRIVACY.md) (in Chinese).
</details>

<details>
<summary>Will it support downloads, live streams or multiple accounts?</summary>

No. None of these are planned; BiliKit only aims to do one thing well: watching videos. See the [roadmap](docs/ROADMAP.md) (in Chinese) for other plans.
</details>

<details>
<summary>Building from source</summary>

Open `BiliKitMac.xcodeproj` in Xcode, choose the `BiliKitMac` scheme and "My Mac", then run. Full checks:

```sh
sh Scripts/run-quality-gates.sh app
```

The following documents are in Chinese:
[Architecture](docs/ARCHITECTURE.md) · [Security model](docs/SECURITY-MODEL.md) · [Release process](docs/release/README.md) ·
[Reporting security issues](SECURITY.md) · [App Icon sources](Design/AppIcon/v1/) · [Screenshots](Design/Marketing/v2/)
</details>

## License and notices

The source code is licensed under the [MIT License](LICENSE). The BiliKit name, icon and marketing materials are not covered by the MIT License; see the
[brand asset notice](BRAND-ASSETS.md) (in Chinese). Third-party dependencies are listed in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) (in Chinese).
Bilibili-related names and trademarks belong to their respective owners.
