#!/bin/sh

set -eu
umask 077

fail() {
    echo "Danmaku Lab performance preparation failed: $1" >&2
    exit 1
}

[ "$#" -eq 2 ] \
    || fail "usage: $0 /private/tmp/task-specific-artifact-root calibration|adjudication"
artifact_root=$1
decision_mode=$2
case "$decision_mode" in
    calibration|adjudication) ;;
    *) fail "decision mode must be calibration or adjudication" ;;
esac
case "$artifact_root" in
    /private/tmp/*) ;;
    *) fail "artifact root must be a task-specific directory under /private/tmp" ;;
esac
artifact_name=${artifact_root#/private/tmp/}
case "$artifact_name" in
    ""|.|..|*/*) fail "artifact root must be one task-specific directory" ;;
esac
[ ! -e "$artifact_root" ] || fail "artifact root already exists"

repository_root=$(CDPATH= cd -- "$(dirname "$0")/../../.." && pwd -P)
cd "$repository_root"
[ -z "$(git status --porcelain)" ] \
    || fail "formal performance builds require a clean worktree"

developer_dir=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
[ -x "$developer_dir/usr/bin/xcodebuild" ] || fail "full Xcode is required"
export DEVELOPER_DIR=$developer_dir

mkdir -p \
    "$artifact_root/build" \
    "$artifact_root/cache" \
    "$artifact_root/config" \
    "$artifact_root/security" \
    "$artifact_root/module-cache" \
    "$artifact_root/raw" \
    "$artifact_root/frozen" \
    "$artifact_root/claimed-samples" \
    "$artifact_root/lab-results" \
    "$artifact_root/summaries"

if ! CLANG_MODULE_CACHE_PATH="$artifact_root/module-cache" \
    SWIFTPM_MODULECACHE_OVERRIDE="$artifact_root/module-cache" \
    xcrun swift build \
        --configuration release \
        --product DanmakuLab \
        --package-path Tools/DanmakuLab \
        --scratch-path "$artifact_root/build" \
        --cache-path "$artifact_root/cache" \
        --config-path "$artifact_root/config" \
        --security-path "$artifact_root/security" \
        >"$artifact_root/build.log" 2>&1
then
    tail -100 "$artifact_root/build.log" >&2
    fail "Release build failed"
fi

binary_path=$(CLANG_MODULE_CACHE_PATH="$artifact_root/module-cache" \
    SWIFTPM_MODULECACHE_OVERRIDE="$artifact_root/module-cache" \
    xcrun swift build \
        --configuration release \
        --show-bin-path \
        --package-path Tools/DanmakuLab \
        --scratch-path "$artifact_root/build" \
        --cache-path "$artifact_root/cache" \
        --config-path "$artifact_root/config" \
        --security-path "$artifact_root/security")/DanmakuLab
[ -x "$binary_path" ] || fail "Release binary was not produced"
binary_directory=$(CDPATH= cd -- "$(dirname "$binary_path")" && pwd -P)
binary_path="$binary_directory/$(basename "$binary_path")"
binary_sha256=$(shasum -a 256 "$binary_path" | awk '{print $1}')
package_resolved_sha256=$(shasum -a 256 Tools/DanmakuLab/Package.resolved | awk '{print $1}')
xctrace_version=$(xcrun xctrace version 2>&1 || echo unavailable)

{
    echo "prepared-at-utc=$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo "git-head=$(git rev-parse HEAD)"
    echo "architecture=$(uname -m)"
    echo "macos-version=$(sw_vers -productVersion)"
    echo "macos-build=$(sw_vers -buildVersion)"
    echo "xcode-version=$("$developer_dir/usr/bin/xcodebuild" -version | tr '\n' ' ')"
    echo "swift-version=$(xcrun swift --version | tr '\n' ' ')"
    echo "xctrace-version=$(echo "$xctrace_version" | tr '\n' ' ')"
    echo "machine-model=$(sysctl -n hw.model)"
    echo "physical-memory-bytes=$(sysctl -n hw.memsize)"
    echo "configuration=Release"
    echo "signing=unsigned SwiftPM developer executable"
    echo "renderer-process-policy=one renderer per process"
    echo "telemetry-policy=disabled"
} >"$artifact_root/environment.txt"
echo "$binary_path" >"$artifact_root/binary-path.txt"
echo "$binary_sha256" >"$artifact_root/binary-sha256.txt"
echo "$package_resolved_sha256" >"$artifact_root/package-resolved-sha256.txt"
{
    echo "protocol-version=4"
    echo "decision-mode=$decision_mode"
    echo "binary-sha256=$binary_sha256"
    echo "package-resolved-sha256=$package_resolved_sha256"
    echo "presets=steady-80@1,burst-320@1,capacity-640@1"
    echo "renderer-dimension=separate-static-registry-identity"
    echo "logical-ticks-per-second=30"
    echo "warmup-seconds=5"
    echo "measurement-seconds=30"
    echo "trace-setup-allowance-seconds=60"
    echo "repetitions-per-template=3"
    echo "templates=Time Profiler,Animation Hitches,Allocations"
    echo "aggregation=all-valid-repetitions-must-pass-and-spread-must-stay-within-budget"
    echo "process-policy=fresh-process-per-sample"
} >"$artifact_root/benchmark-manifest.txt"
benchmark_manifest_sha256=$(shasum -a 256 "$artifact_root/benchmark-manifest.txt" | awk '{print $1}')
echo "$benchmark_manifest_sha256" >"$artifact_root/benchmark-manifest-sha256.txt"
chmod 0444 \
    "$artifact_root/benchmark-manifest.txt" \
    "$artifact_root/benchmark-manifest-sha256.txt"
{
    echo "# Danmaku Lab decision thresholds"
    echo
    echo "- decision-mode: $decision_mode"
    if [ "$decision_mode" = calibration ]; then
        echo "- policy: calibration samples never produce ACCEPTED"
        echo "- thresholds: NOT SET"
    else
        echo "- target-display-refresh-hz: TODO"
        echo "- maximum-display-refresh-deviation-hz: TODO"
        echo "- maximum-detected-main-thread-hang-ms: TODO"
        echo "- maximum-measurement-duration-deviation-ms: TODO"
        echo "- maximum-hitch-count-in-measurement-window: TODO"
        echo "- maximum-hitch-duration-ms: TODO"
        echo "- maximum-process-cpu-percent: TODO"
        echo "- maximum-main-thread-cpu-percent: TODO"
        echo "- maximum-rss-mib: TODO"
        echo "- maximum-physical-footprint-mib: TODO"
        echo "- maximum-persistent-allocation-growth-mib: TODO"
        echo "- maximum-peak-active-presentations: TODO"
        echo "- maximum-drop-fraction-steady-80: TODO"
        echo "- maximum-drop-fraction-burst-320: TODO"
        echo "- maximum-drop-fraction-capacity-640: TODO"
        echo "- maximum-rss-relative-spread-percent: TODO"
        echo "- maximum-physical-footprint-relative-spread-percent: TODO"
        echo "- maximum-measurement-duration-relative-spread-percent: TODO"
        echo "- maximum-drop-fraction-relative-spread-percent: TODO"
        echo "- maximum-peak-active-relative-spread-percent: TODO"
        echo "- maximum-process-cpu-relative-spread-percent: TODO"
        echo "- maximum-main-thread-cpu-relative-spread-percent: TODO"
        echo "- maximum-detected-main-thread-hang-relative-spread-percent: TODO"
        echo "- maximum-hitch-count-relative-spread-percent: TODO"
        echo "- maximum-hitch-duration-relative-spread-percent: TODO"
        echo "- maximum-allocation-growth-relative-spread-percent: TODO"
        echo "- policy: any valid sample outside an approved threshold remains REVISE"
    fi
} >"$artifact_root/thresholds.md"
system_profiler SPDisplaysDataType -detailLevel mini \
    >"$artifact_root/display-environment.txt"
pmset -g batt >"$artifact_root/power-environment.txt"

echo "Prepared Release binary:"
echo "DANMAKU_LAB_PERFORMANCE_ROOT='$artifact_root' '$binary_path'"
echo
echo "Launch it in a dedicated terminal, select the registered preset, and click Prepare:"
echo "$binary_path"
echo
echo "Review the frozen decision mode before recording:"
echo "$artifact_root/thresholds.md"
echo
echo "Then run record-performance-trace.sh from a second terminal before clicking Run repetition."
