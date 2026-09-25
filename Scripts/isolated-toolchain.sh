# 由 run-quality-gates.sh 与 run-targeted-tests.sh source，不单独执行。
# 调用方先 cd 到仓库根并设置 artifact_root；SwiftPM／Xcode 只读写该任务临时根。

developer_dir="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
if [ ! -x "$developer_dir/usr/bin/xcodebuild" ]; then
    echo "需要完整 Xcode：$developer_dir" >&2
    exit 1
fi
export DEVELOPER_DIR="$developer_dir"

derived_data="$artifact_root/DerivedData"
mkdir -p "$artifact_root/tmp" "$artifact_root/ModuleCache.noindex"

# 用 $artifact_root/$1 作 HOME 运行其余参数组成的命令。
isolated() {
    isolated_home="$artifact_root/$1"
    shift
    mkdir -p "$isolated_home"
    env \
        HOME="$isolated_home" \
        CFFIXED_USER_HOME="$isolated_home" \
        XDG_CACHE_HOME="$isolated_home/.cache" \
        TMPDIR="$artifact_root/tmp" \
        CLANG_MODULE_CACHE_PATH="$artifact_root/ModuleCache.noindex" \
        SWIFTPM_MODULECACHE_OVERRIDE="$artifact_root/ModuleCache.noindex" \
        "$@"
}

package_test() {
    isolated swiftpm-home xcrun swift test \
        --package-path Packages/BiliKitCore \
        --scratch-path "$artifact_root/swiftpm" \
        --cache-path "$artifact_root/swiftpm-cache" \
        --config-path "$artifact_root/swiftpm-config" \
        --security-path "$artifact_root/swiftpm-security" \
        "$@"
}

app_xcodebuild() {
    isolated xcode-home xcodebuild \
        -quiet \
        -project BiliKitMac.xcodeproj \
        -scheme BiliKitMac \
        -configuration Debug \
        -destination 'platform=macOS' \
        -derivedDataPath "$derived_data" \
        -clonedSourcePackagesDirPath "$artifact_root/SourcePackages" \
        CODE_SIGNING_ALLOWED=NO \
        "$@"
}
