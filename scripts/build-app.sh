#!/bin/bash
set -euo pipefail

project_dir="$(cd -- "$(dirname -- "$0")/.." && pwd)"
app="$project_dir/.build/XScreenshot.app"
signing_identity="${XSCREENSHOT_SIGN_IDENTITY:--}"

build_options=(--package-path "$project_dir" --configuration release "$@")
swift build "${build_options[@]}"
binary_dir="$(swift build "${build_options[@]}" --show-bin-path)"

mkdir -p "$project_dir/.build"
staging_dir="$(mktemp -d "$project_dir/.build/xscreenshot.XXXXXX")"
trap 'rm -rf "$staging_dir"' EXIT
staged_app="$staging_dir/XScreenshot.app"
mkdir -p "$staged_app/Contents/MacOS"
cp "$project_dir/App/Info.plist" "$staged_app/Contents/Info.plist"
cp "$binary_dir/XScreenshot" "$staged_app/Contents/MacOS/XScreenshot"
codesign --force --sign "$signing_identity" "$staged_app"
codesign --verify --strict "$staged_app"
ditto "$staged_app" "$app"

printf 'Built %s\n' "$app"
