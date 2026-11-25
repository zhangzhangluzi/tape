#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

app_name="Tape 中文版.app"
bundle_id=local.codex.tape-zh-cn
destination="$PWD/dist"
if [[ $# -eq 1 && "$1" == --install ]]; then
    destination=/Applications
elif [[ $# -ne 0 ]]; then
    printf '用法：%s [--install]\n' "$0" >&2
    exit 2
fi

mkdir -p .build "$destination"
if [[ ! -w "$destination" ]]; then
    printf '无法写入 %s。请使用有安装权限的账户。\n' "$destination" >&2
    exit 1
fi
target="$destination/$app_name"

xcrun swift build --configuration release --product Tape
bin_dir=$(xcrun swift build --configuration release --show-bin-path)
stage=$(mktemp -d "$destination/.tape-zh.XXXXXX")
bundle="$stage/$app_name"
previous="$stage/previous.app"
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
/usr/bin/plutil -replace CFBundleVersion -string 501 "$info"
/usr/bin/plutil -replace NSHumanReadableCopyright -string 'Copyright © 2026 Gustaf Eriksson' "$info"
/usr/bin/plutil -insert CFBundleIconFile -string AppIcon "$info"
/usr/bin/codesign --sign - --options runtime --entitlements Resources/Tape.entitlements "$bundle"
/usr/bin/codesign --verify --strict "$bundle"

if [[ -e "$target" || -L "$target" ]]; then
    existing_id=$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "$target/Contents/Info.plist" 2>/dev/null || true)
    if [[ -L "$target" || "$existing_id" != "$bundle_id" ]]; then
        printf '目标位置已有其他文件，构建结果保存在 %s。\n' "$bundle" >&2
        exit 1
    fi
    mv "$target" "$previous"
fi
if ! mv "$bundle" "$target"; then
    if [[ -d "$previous" ]]; then mv "$previous" "$target"; fi
    exit 1
fi
if [[ -d "$previous" ]]; then
    backup=$(mktemp -d "$PWD/.build/previous-tape.XXXXXX")
    mv "$previous" "$backup/$app_name"
fi
rmdir "$stage"
printf '%s\n' "$target"
