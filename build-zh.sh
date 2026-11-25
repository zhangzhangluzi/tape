#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

xcrun swift build --configuration release --product Tape
bin_dir=$(xcrun swift build --configuration release --show-bin-path)
mkdir -p .build dist
stage=$(mktemp -d "$PWD/.build/tape-zh.XXXXXX")
app_name="Tape 中文版.app"
bundle="$stage/$app_name"
target="$PWD/dist/$app_name"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
install -m 755 "$bin_dir/Tape" "$bundle/Contents/MacOS/Tape"
cp icon/AppIcon.icns LICENSE "$bundle/Contents/Resources/"
cp Resources/Info.plist "$bundle/Contents/Info.plist"
info="$bundle/Contents/Info.plist"
/usr/bin/plutil -replace CFBundleDevelopmentRegion -string zh-Hans "$info"
/usr/bin/plutil -replace CFBundleExecutable -string Tape "$info"
/usr/bin/plutil -replace CFBundleIdentifier -string local.codex.tape-zh-cn "$info"
/usr/bin/plutil -replace CFBundleName -string 'Tape 中文版' "$info"
/usr/bin/plutil -replace CFBundleShortVersionString -string 0.5.0 "$info"
/usr/bin/plutil -replace CFBundleVersion -string 500 "$info"
/usr/bin/plutil -replace NSHumanReadableCopyright -string 'Copyright © 2026 Gustaf Eriksson' "$info"
/usr/bin/plutil -insert CFBundleIconFile -string AppIcon "$info"
/usr/bin/codesign --sign - --options runtime --entitlements Resources/Tape.entitlements "$bundle"
/usr/bin/codesign --verify --strict "$bundle"

if [[ -e "$target" ]]; then
    mv "$target" "$stage/previous.app"
fi
if ! mv "$bundle" "$target"; then
    if [[ -d "$stage/previous.app" ]]; then mv "$stage/previous.app" "$target"; fi
    exit 1
fi
printf '%s\n' "$target"
