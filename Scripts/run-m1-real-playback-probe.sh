#!/bin/zsh

set -euo pipefail

script_directory=${0:A:h}
repository_root=${script_directory:h}
probe_directory=""

cleanup() {
    if [[ -n "$probe_directory"
        && "$probe_directory" == /tmp/BiliKitMac-m1-playback-probe.*
        && -d "$probe_directory" ]]; then
        rm -rf -- "$probe_directory"
    fi
}
trap cleanup EXIT INT TERM

printf '%s' '请输入要验证的公开视频 BVID：' >&2
IFS= read -rs probe_bvid
printf '\n' >&2
if [[ ${#probe_bvid} -ne 12 || ! "$probe_bvid" =~ ^BV[A-Za-z0-9]{10}$ ]]; then
    print -u2 'BVID 格式无效。'
    exit 2
fi

printf '%s' '请输入要验证的分 P CID（首分 P 可直接回车）：' >&2
IFS= read -rs probe_cid
printf '\n' >&2
if [[ -n "$probe_cid" && ! "$probe_cid" =~ ^[1-9][0-9]*$ ]]; then
    print -u2 'CID 必须为正整数。'
    exit 2
fi

probe_directory=$(mktemp -d /tmp/BiliKitMac-m1-playback-probe.XXXXXX)
chmod 700 "$probe_directory"
input_file="$probe_directory/input.plist"
/usr/bin/plutil -create xml1 "$input_file"
/usr/bin/plutil -insert bvid -string "$probe_bvid" "$input_file"
if [[ -n "$probe_cid" ]]; then
    /usr/bin/plutil -insert cid -string "$probe_cid" "$input_file"
fi
chmod 600 "$input_file"
unset probe_bvid probe_cid

cd "$repository_root"
print '正在运行本机真实播放探针……'
set +e
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
    xcrun swift run \
    --package-path Packages/BiliKitCore \
    BiliPlaybackProbe \
    --input-file "$input_file" \
    --play-seconds 30 \
    --forward-seek 30 \
    --backward-seek 5 \
    --seek-cycles 6 \
    --replacement-cycles 12 \
    --max-memory-growth-mib 64
probe_status=$?
set -e

if [[ $probe_status -ne 0 ]]; then
    print -u2 '真实播放探针失败；临时输入已清理。'
    exit $probe_status
fi
print '探针完成；BVID、CID、完整 URL、远端响应和临时输入均未保留。'
