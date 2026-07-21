# BiliKit for macOS

BiliKit is an early-stage, native and unofficial Bilibili client for macOS. The project focuses on reliable playback, a restrained browsing experience, and interaction patterns that belong on the Mac.

> BiliKit is a third-party project and is not affiliated with, endorsed by, or sponsored by Bilibili. Bilibili names and trademarks belong to their respective owners.

## Status

The repository is currently in M0: project baseline and minimal module scaffolding. It is not ready for daily use or distribution.

- Minimum deployment target: macOS 14
- Language: Swift 6
- UI: SwiftUI with AppKit/AVKit bridges where appropriate
- Playback direction: AVPlayer-first with a clean-room DASH-to-HLS bridge
- License: MIT

See [the roadmap](docs/ROADMAP.md) for current milestones and acceptance gates, and [the research baseline](docs/RESEARCH-native-macos-client.md) for product and technical evidence.

## Repository layout

```text
BiliKitMac/                 macOS app shell and feature UI
Packages/BiliKitCore/       local Swift package with core modules
BiliKitMacTests/            app integration tests
BiliKitMacUITests/          critical UI flow tests
docs/                       roadmap, ADRs, and research
references/                 ignored local research checkouts
```

The first package modules are:

- `BiliModels`: stable cross-module value types.
- `BiliNetworking`: transport abstraction, HTTP client, and log redaction.
- `BiliPlayback`: player boundary and resolved playback requests.

## Build

The commands below avoid code signing and keep Derived Data outside the repository:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild \
  -project BiliKitMac.xcodeproj \
  -scheme BiliKitMac \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/BiliKitMac-derived \
  CODE_SIGNING_ALLOWED=NO \
  build-for-testing
```

Run package tests independently:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcrun swift test --package-path Packages/BiliKitCore
```

The active developer directory on an individual machine may differ. Opening `BiliKitMac.xcodeproj` in Xcode remains the normal development workflow.

## Security and implementation boundaries

- Cookies and tokens belong in Keychain and memory only.
- Do not put credentials in fixtures, logs, UserDefaults, SwiftData, or crash reports.
- Community APIs are reverse-engineered and must be treated as replaceable, testable, and failure-prone.
- GPL projects may be studied for public behavior and data formats, but their source, comments, fixtures, and assets must not be copied into this MIT repository.
- v1 deliberately excludes downloading, live streaming, uploads, private messages, multiple accounts, and region bypassing.

Third-party dependency notices are tracked in [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md).

