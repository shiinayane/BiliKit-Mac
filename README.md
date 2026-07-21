# BiliKit for macOS

BiliKit is an early-stage, native and unofficial Bilibili client for macOS. The project focuses on reliable playback, a restrained browsing experience, and interaction patterns that belong on the Mac.

> BiliKit is a third-party project and is not affiliated with, endorsed by, or sponsored by Bilibili. Bilibili names and trademarks belong to their respective owners.

## Status

The repository is currently in M1: playback feasibility validation. Synthetic
and opt-in real AVC/AAC DASH samples now reach AVPlayer through a loopback HTTP
bridge. The real probe is a development tool rather than product UI, and the M1
runtime matrix is not complete. It is not ready for daily use or distribution.

- Minimum deployment target: macOS 15
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
- `BiliNetworking`: transport abstraction, strict Range validation, CDN fallback,
  cancellation, and log redaction.
- `BiliPlayback`: SIDX parsing, HLS playlist generation, loopback media proxy,
  and player boundaries.

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

## Opt-in real playback probe

`BiliPlaybackProbe` resolves the first part of a supplied BVID, requests a guest
AVC/AAC DASH manifest, and checks ready-to-play, initial playback, and forward
and backward seeks. It performs live network requests and is intentionally not
part of CI or the App target:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcrun swift run \
  --package-path Packages/BiliKitCore \
  BiliPlaybackProbe \
  --bvid BV1h4KU66ENd \
  --play-seconds 1 \
  --forward-seek 30 \
  --backward-seek 5
```

The public guest endpoint and media URLs are dynamic. A previously recorded
BVID can disappear or stop allowing the requested quality, so probe failure is
not by itself proof of a playback regression. The probe never prints signed
media URLs or response bodies. See the
[current validation record](docs/validation/M1-real-playback-2026-07-21.md).

## Security and implementation boundaries

- Cookies and tokens belong in Keychain and memory only.
- Do not put credentials in fixtures, logs, UserDefaults, SwiftData, or crash reports.
- Community APIs are reverse-engineered and must be treated as replaceable, testable, and failure-prone.
- GPL projects may be studied for public behavior and data formats, but their source, comments, fixtures, and assets must not be copied into this MIT repository.
- v1 deliberately excludes downloading, live streaming, uploads, private messages, multiple accounts, and region bypassing.

Third-party dependency notices are tracked in [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md).
