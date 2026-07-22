#!/bin/zsh

set -euo pipefail

script_directory=${0:A:h}
repository_root=${script_directory:h}
test_log="$repository_root/test.log"

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

arguments=(
    --bvid "$probe_bvid"
    --segment-index 1
)
if [[ -n "$probe_cid" ]]; then
    arguments+=(--cid "$probe_cid")
fi

cd "$repository_root"
print '正在运行 M4.3 生产弹幕 decoder 与调度探针……'
set +e
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
    xcrun swift run \
    --package-path Packages/BiliKitCore \
    BiliDanmakuProbe \
    "${arguments[@]}" > "$test_log" 2>&1
probe_status=$?
set -e

rg 'danmaku-production|RESULT:|failed:' "$test_log" || true
if [[ $probe_status -ne 0 ]]; then
    print -u2 "探针失败；完整脱敏构建日志位于 $test_log"
    exit $probe_status
fi
if ! rg -q 'danmaku-production segment=ready decoded=[1-9][0-9]* scheduled=[1-9][0-9]* cache=1' "$test_log"; then
    print -u2 '探针未到达生产 decoder 与调度内核。'
    exit 1
fi

print "探针完成；完整脱敏构建日志位于 $test_log"
