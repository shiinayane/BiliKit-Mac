# M1 Real Playback Validation — 2026-07-21

## Result

PASS for the tested sample and environment. A guest AVC video track and AAC
audio track reached `AVPlayer` through the loopback DASH-to-HLS bridge, played
past 1 second, then resumed after forward and backward seeks.

This is evidence for the current environment only. It does not close the M1
gate because macOS 15 runtime coverage, long-duration resource auditing, and a
broader CDN/failure matrix remain outstanding.

## Environment

- Date: 2026-07-21 (Asia/Tokyo)
- Hardware architecture: Apple Silicon (`arm64`)
- Runtime: macOS 26.5.2 (25F84)
- Toolchain: Xcode 26.6 (17F113), Swift 6.3.3
- Package deployment target: macOS 15

The deployment target confirms compilation compatibility, not execution on
macOS 15. The configured GitHub Actions `macos-15` runner must still complete
the runtime checks after these changes are pushed.

## Sample and selected representations

- BVID: `BV1h4KU66ENd`
- CID: `40123826438`
- Guest request quality: 32 (480p at validation time)
- Video: representation 32, `avc1.640033`, 486634 bit/s
- Audio: representation 30216, `mp4a.40.2`, 65676 bit/s
- Candidate CDN host families observed: `bilivideo.com`, `akamaized.net`
- Asset duration reported by AVFoundation: 1753.03 seconds

Signed media URLs and API response bodies are intentionally not recorded. The
sample and guest endpoint are dynamic and may stop working independently of the
bridge implementation.

## Reproduction

Run explicitly from the repository root; this probe performs live network
requests and is not part of CI:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcrun swift run \
  --package-path Packages/BiliKitCore \
  BiliPlaybackProbe \
  --bvid BV1h4KU66ENd \
  --cid 40123826438 \
  --play-seconds 1 \
  --forward-seek 30 \
  --backward-seek 5
```

Recorded result:

```text
ready: duration=1753.03s
play: reached=1.03s
seek-forward: target=30.00s ok
seek-backward: target=5.00s ok
RESULT: PASS
```

The probe prints only BVID/CID, codec metadata, bandwidth, CDN hostnames, and
playback results. It does not accept credentials and does not print signed media
URLs or response bodies.

## Supporting regression checks

- Swift Package tests: 25 passed, including synthetic AVPlayer startup/seek,
  strict Range validation, CDN fallback, invalid body rejection, and
  cancellation/replacement.
- App unit tests: 1 passed with an unsigned macOS build.
- Fresh SwiftPM compile commands target `arm64-apple-macosx15.0`; the probe
  Mach-O reports `minos 15.0`.
- The built App reports `LSMinimumSystemVersion` as `15.0`.

## Remaining M1 evidence

- Run the same core chain on the GitHub Actions `macos-15` runner; cover Intel
  if a machine is available.
- Measure audio/video synchronization over a longer interval and after repeated seeks.
- Inject real or controlled 403, invalid `Content-Range`, and HTML error responses
  while retaining a valid backup CDN.
- Audit connections, live tasks, and memory across repeated replacement and
  long-duration playback.
