#!/bin/bash
set -euo pipefail

project_dir="$(cd -- "$(dirname -- "$0")/.." && pwd)"
app="$project_dir/.build/XScreenshot.app"

build_options=(--package-path "$project_dir" --configuration release "$@")
swift build "${build_options[@]}"
binary_dir="$(swift build "${build_options[@]}" --show-bin-path)"

mkdir -p "$app/Contents/MacOS"
cp "$project_dir/App/Info.plist" "$app/Contents/Info.plist"
cp "$binary_dir/XScreenshot" "$app/Contents/MacOS/XScreenshot"
codesign --force --sign - "$app"
codesign --verify --strict "$app"

printf 'Built %s\n' "$app"
