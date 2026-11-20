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
iconset="$staging_dir/AppIcon.iconset"
mkdir -p "$staged_app/Contents/MacOS" "$staged_app/Contents/Resources" "$iconset"
cp "$project_dir/App/Info.plist" "$staged_app/Contents/Info.plist"
cp "$binary_dir/XScreenshot" "$staged_app/Contents/MacOS/XScreenshot"

for size in 16 32 128 256 512; do
    retina_size=$((size * 2))
    sips -z "$size" "$size" "$project_dir/App/AppIcon.png" \
        --out "$iconset/icon_${size}x${size}.png" >/dev/null
    sips -z "$retina_size" "$retina_size" "$project_dir/App/AppIcon.png" \
        --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil --convert icns --output "$staged_app/Contents/Resources/AppIcon.icns" "$iconset"

codesign --force --sign "$signing_identity" "$staged_app"
codesign --verify --strict "$staged_app"
ditto "$staged_app" "$app"

printf 'Built %s\n' "$app"
