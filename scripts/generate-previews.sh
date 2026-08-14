#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
app_path="$("$project_dir/scripts/build-app.sh" | tail -n 1)"
output_dir="$project_dir/docs/images"

mkdir -p "$output_dir"
"$app_path/Contents/MacOS/ResetMeter" \
    --snapshot-demo "$output_dir/reset-meter.png"

print "$output_dir/reset-meter.png"
print "$output_dir/reset-meter-menu.png"
