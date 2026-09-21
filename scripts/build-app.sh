#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
app_dir="$project_dir/dist/Reset Meter.app"
generated_assets="$project_dir/.build/reset-meter-assets"
sign_identity="${RESET_METER_SIGN_IDENTITY:--}"

cd "$project_dir"
build_flags=(-c release --arch arm64 --arch x86_64)
swift build "${build_flags[@]}"

# Ask the toolchain where it put the universal product: the path moved between
# Swift releases, and a hardcoded one silently packages a stale binary.
binary="$(swift build "${build_flags[@]}" --show-bin-path)/ResetMeter"
if [[ ! -x "$binary" ]]; then
    print -u2 "Release binary not found at $binary"
    exit 1
fi

mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources" "$generated_assets"
cp "$binary" "$app_dir/Contents/MacOS/ResetMeter"
cp "$project_dir/Info.plist" "$app_dir/Contents/Info.plist"

for previous_asset in codex.png claude.png cursor.png codex.svg claude.svg cursor.svg ResetMeter.icns; do
    previous_path="$app_dir/Contents/Resources/$previous_asset"
    [[ -e "$previous_path" ]] && unlink "$previous_path"
done

cp "$project_dir/Assets/codex.svg" "$app_dir/Contents/Resources/codex.svg"
cp "$project_dir/Assets/claude.svg" "$app_dir/Contents/Resources/claude.svg"
cp "$project_dir/Assets/cursor.svg" "$app_dir/Contents/Resources/cursor.svg"

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
