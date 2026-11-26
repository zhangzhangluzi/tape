#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

app_name="Tape 中文版.app"
archive_name="${app_name%.app}.zip"
bundle_id=local.codex.tape-zh-cn
signing_identity=${CODE_SIGN_IDENTITY:--}

if [[ $# -gt 1 ]]; then
    printf '用法：%s [--install | --package]\n' "$0" >&2
    exit 2
fi
mode=${1---install}
case "$mode" in
    --install) destination=/Applications ;;
    --package) destination="$PWD/dist" ;;
    *)
        printf '用法：%s [--install | --package]\n' "$0" >&2
        exit 2
        ;;
esac

mkdir -p .build "$destination"
if [[ ! -w "$destination" ]]; then
    printf '无法写入 %s。请使用有安装权限的账户。\n' "$destination" >&2
    exit 1
fi
xcrun swift build --configuration release --product Tape
bin_dir=$(xcrun swift build --configuration release --show-bin-path)
work_dir=$(mktemp -d "$destination/.tape-zh.XXXXXX")
cleanup() {
    xcrun swift -e 'import Foundation; try FileManager.default.removeItem(atPath: CommandLine.arguments[1])' "$work_dir"
}
trap cleanup EXIT
stage="$work_dir/build.noindex"
bundle="$stage/$app_name"
if [[ "$mode" == --install ]]; then
    bundle="$stage/Tape.next"
fi
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
install -m 755 "$bin_dir/Tape" "$bundle/Contents/MacOS/Tape"
cp icon/AppIcon.icns LICENSE "$bundle/Contents/Resources/"
cp Resources/Info.plist "$bundle/Contents/Info.plist"
info="$bundle/Contents/Info.plist"
/usr/bin/plutil -replace CFBundleDevelopmentRegion -string zh-Hans "$info"
/usr/bin/plutil -replace CFBundleExecutable -string Tape "$info"
/usr/bin/plutil -replace CFBundleIdentifier -string "$bundle_id" "$info"
/usr/bin/plutil -replace CFBundleName -string 'Tape 中文版' "$info"
/usr/bin/plutil -replace CFBundleShortVersionString -string 0.5.0 "$info"
/usr/bin/plutil -replace CFBundleVersion -string 504 "$info"
/usr/bin/plutil -replace NSHumanReadableCopyright -string 'Copyright © 2026 Gustaf Eriksson' "$info"
/usr/bin/plutil -insert CFBundleIconFile -string AppIcon "$info"
/usr/bin/codesign --sign "$signing_identity" --options runtime --entitlements Resources/Tape.entitlements "$bundle"
/usr/bin/codesign --verify --strict "$bundle"

archive_bundle() {
    /usr/bin/ditto -c -k --sequesterRsrc --keepParent "$1" "$2"
}

if [[ "$mode" == --package ]]; then
    archive="$destination/$archive_name"
    if [[ -d "$archive" ]]; then
        printf '目标位置已存在目录 %s。\n' "$archive" >&2
        exit 1
    fi
    archive_bundle "$bundle" "$stage/$archive_name"
    mv -fh "$stage/$archive_name" "$archive"
    printf '%s\n' "$archive"
    exit 0
fi

target="$destination/$app_name"
replace=no
if [[ -e "$target" || -L "$target" ]]; then
    existing_id=$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "$target/Contents/Info.plist" 2>/dev/null || true)
    if [[ -L "$target" || "$existing_id" != "$bundle_id" ]]; then
        printf '目标位置已有其他文件 %s。\n' "$target" >&2
        exit 1
    fi
    backup=$(mktemp -d "$PWD/.build/previous-tape.XXXXXX")
    archive_bundle "$target" "$backup/$archive_name"
    replace=yes
fi

# Keep the application path occupied throughout an update.
xcrun swift -e '
import AppKit
import Darwin

let args = CommandLine.arguments
let running = NSRunningApplication.runningApplications(withBundleIdentifier: args[3])
guard !running.contains(where: { !$0.isTerminated }) else {
    fputs("请从顶部菜单栏退出 Tape，再更新。\n", stderr)
    exit(1)
}
let flags = UInt32((args[4] == "yes" ? RENAME_SWAP : RENAME_EXCL) | RENAME_NOFOLLOW_ANY)
guard renamex_np(args[1], args[2], flags) == 0 else {
    perror("安装 Tape 中文版")
    exit(1)
}
' "$bundle" "$target" "$bundle_id" "$replace"
printf '%s\n' "$target"
