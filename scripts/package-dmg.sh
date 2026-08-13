#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
sign_identity="${RESET_METER_SIGN_IDENTITY:--}"
notary_profile="${RESET_METER_NOTARY_PROFILE:-}"
app_path="$("$project_dir/scripts/build-app.sh" | tail -n 1)"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app_path/Contents/Info.plist")"
suffix=""
[[ "$sign_identity" == "-" ]] && suffix="-unsigned"
dmg_path="$project_dir/dist/Reset-Meter-$version$suffix.dmg"
staging_dir="$(mktemp -d '/tmp/reset-meter-dmg.XXXXXX')"

cleanup() {
    rm -rf "$staging_dir"
}
trap cleanup EXIT

ditto "$app_path" "$staging_dir/Reset Meter.app"
ln -s /Applications "$staging_dir/Applications"
cp "$project_dir/INSTALL.txt" "$staging_dir/Read Me.txt"

hdiutil create \
    -quiet \
    -volname "Reset Meter" \
    -srcfolder "$staging_dir" \
    -format UDZO \
    -ov \
    "$dmg_path"

if [[ "$sign_identity" != "-" ]]; then
    codesign --force --timestamp --sign "$sign_identity" "$dmg_path"
fi

if [[ -n "$notary_profile" ]]; then
    if [[ "$sign_identity" == "-" ]]; then
        print -u2 "RESET_METER_NOTARY_PROFILE requires a Developer ID signing identity."
        exit 1
    fi
    xcrun notarytool submit "$dmg_path" --keychain-profile "$notary_profile" --wait
    xcrun stapler staple "$dmg_path"
    xcrun stapler validate "$dmg_path"
fi

print "$dmg_path"
