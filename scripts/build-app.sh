#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
app_dir="$project_dir/dist/Reset Meter.app"
binary="$project_dir/.build/apple/Products/Release/ResetMeter"
generated_assets="$project_dir/.build/reset-meter-assets"
sign_identity="${RESET_METER_SIGN_IDENTITY:--}"

cd "$project_dir"
swift build -c release --arch arm64 --arch x86_64

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
codesign --verify --deep --strict "$app_dir"

print "$app_dir"
