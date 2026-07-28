#!/bin/zsh

set -euo pipefail

script_directory=${0:A:h}
repository_root=${script_directory:h}
probe_directory=""

cleanup() {
    if [[ -n "$probe_directory"
        && "$probe_directory" == /tmp/BiliKitMac-m4-danmaku-probe.*
        && -d "$probe_directory" ]]; then
        rm -rf -- "$probe_directory"
    fi
}
trap cleanup EXIT INT TERM

printf '请输入一条带普通弹幕的公开视频 BVID：'
IFS= read -r probe_bvid
if [[ ${#probe_bvid} -ne 12 || ! "$probe_bvid" =~ ^BV[[:alnum:]]{10}$ ]]; then
    print -u2 'BVID 格式无效。'
    exit 2
fi

printf '请输入要验证的分 P CID（首分 P 可直接回车）：'
IFS= read -r probe_cid
if [[ -n "$probe_cid" && ! "$probe_cid" =~ ^[1-9][0-9]*$ ]]; then
    print -u2 'CID 必须为正整数。'
    exit 2
fi

probe_directory=$(mktemp -d /tmp/BiliKitMac-m4-danmaku-probe.XXXXXX)
chmod 700 "$probe_directory"
input_file="$probe_directory/input.plist"
test_log="$probe_directory/raw-test.log"
/usr/bin/plutil -create xml1 "$input_file"
/usr/bin/plutil -insert bvid -string "$probe_bvid" "$input_file"
/usr/bin/plutil -insert segment -string 1 "$input_file"
if [[ -n "$probe_cid" ]]; then
    /usr/bin/plutil -insert cid -string "$probe_cid" "$input_file"
fi
chmod 600 "$input_file"
unset probe_bvid probe_cid

cd "$repository_root"
print '正在运行 M4.3 生产弹幕 decoder 与调度探针……'
set +e
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
    xcrun swift run \
    --package-path Packages/BiliKitCore \
    BiliDanmakuProbe \
    --input-file "$input_file" > "$test_log" 2>&1
probe_status=$?
set -e

rg 'danmaku-production|RESULT:|failed:' "$test_log" || true
if [[ $probe_status -ne 0 ]]; then
    print -u2 '探针失败；原始输出已清理。'
    exit $probe_status
fi
if ! rg -q 'danmaku-production segment=ready decoded=[1-9][0-9]* scheduled=[1-9][0-9]* cache=1' "$test_log"; then
    print -u2 '探针未到达生产 decoder 与调度内核。'
    exit 1
fi

print '探针完成；BVID、CID、URL、弹幕正文、远端响应和原始产物均未保留。'
