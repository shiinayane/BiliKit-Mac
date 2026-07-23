#!/bin/zsh

set -euo pipefail

script_directory=${0:A:h}
repository_root=${script_directory:h}
rate=${1:-40}
duration=${2:-30}

if [[ "$rate" != 40 && "$rate" != 80 ]]; then
    print -u2 '负载只接受 40 或 80 events/s。'
    exit 2
fi
if [[ ! "$duration" =~ ^[1-9][0-9]*$ || "$duration" -gt 1800 ]]; then
    print -u2 '时长必须是 1–1800 秒的整数。'
    exit 2
fi

cd "$repository_root"
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
    xcrun swift run \
    --package-path Packages/BiliKitCore \
    BiliDanmakuProbe \
    --renderer-rate "$rate" \
    --duration "$duration"
