#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
app_dir="$project_dir/dist/Reset Meter.app"
generated_assets="$project_dir/.build/reset-meter-assets"
sign_identity="${RESET_METER_SIGN_IDENTITY:--}"

cd "$project_dir"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources" "$generated_assets"

if [[ "${RESET_METER_BUILD_SYSTEM:-}" == "native" ]]; then
    swift build -c release --arch arm64 --build-system native
    arm_bin="$(swift build -c release --arch arm64 --build-system native --show-bin-path)/ResetMeter"
    swift build -c release --arch x86_64 --build-system native
    x86_bin="$(swift build -c release --arch x86_64 --build-system native --show-bin-path)/ResetMeter"
    lipo -create "$arm_bin" "$x86_bin" -output "$app_dir/Contents/MacOS/ResetMeter"
else
    swift build -c release --arch arm64 --arch x86_64
    # Ask the toolchain where it put the universal product: the path moved between
    # Swift releases, and a hardcoded one silently packages a stale binary.
    binary="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/ResetMeter"
    if [[ ! -x "$binary" ]]; then
        print -u2 "Release binary not found at $binary"
        exit 1
    fi
    cp "$binary" "$app_dir/Contents/MacOS/ResetMeter"
fi

cp "$project_dir/Info.plist" "$app_dir/Contents/Info.plist"

for previous_asset in codex.png claude.png cursor.png antigravity.png codex.svg claude.svg cursor.svg antigravity.svg ResetMeter.icns; do
    previous_path="$app_dir/Contents/Resources/$previous_asset"
    [[ -e "$previous_path" ]] && unlink "$previous_path"
done

for svg_asset in codex.svg claude.svg antigravity.svg cursor.svg; do
    cp "$project_dir/Assets/$svg_asset" "$app_dir/Contents/Resources/$svg_asset"
done

/usr/bin/xcrun swift "$project_dir/scripts/generate-app-icon.swift" "$generated_assets/ResetMeter.icns"
cp "$generated_assets/ResetMeter.icns" "$app_dir/Contents/Resources/ResetMeter.icns"

xattr -cr "$app_dir"
if [[ "$sign_identity" == "-" ]]; then
    codesign --force --deep --options runtime --sign - "$app_dir"
else
    codesign --force --deep --options runtime --timestamp --sign "$sign_identity" "$app_dir"
fi
# Syncing services re-tag the bundle with Finder info between signing and
# verification, and codesign rejects that as detritus.
for attempt in 1 2 3; do
    xattr -cr "$app_dir"
    if codesign --verify --deep --strict "$app_dir"; then
        break
    elif (( attempt == 3 )); then
        exit 1
    fi
done

print "$app_dir"
