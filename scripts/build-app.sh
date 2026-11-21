#!/bin/bash
set -euo pipefail

project_dir="$(cd -- "$(dirname -- "$0")/.." && pwd)"
app="${XSCREENSHOT_APP_OUTPUT:-$project_dir/.build/XScreenshot.app}"
signing_identity="${XSCREENSHOT_SIGN_IDENTITY:--}"
universal=false
if [[ "${1:-}" == --universal ]]; then
    universal=true
    shift
fi

build_options=(--package-path "$project_dir" --configuration release "$@")
mkdir -p "$project_dir/.build" "$(dirname -- "$app")"
staging_dir="$(mktemp -d "$project_dir/.build/xscreenshot.XXXXXX")"
trap 'rm -rf "$staging_dir"' EXIT
staged_app="$staging_dir/XScreenshot.app"
iconset="$staging_dir/AppIcon.iconset"
mkdir -p "$staged_app/Contents/MacOS" "$staged_app/Contents/Resources" "$iconset"
cp "$project_dir/App/Info.plist" "$staged_app/Contents/Info.plist"
executable="$staged_app/Contents/MacOS/XScreenshot"

if "$universal"; then
    minimum_macos="$(plutil -extract LSMinimumSystemVersion raw "$staged_app/Contents/Info.plist")"
    binaries=()
    for arch in arm64 x86_64; do
        target_options=("${build_options[@]}" --triple "$arch-apple-macosx$minimum_macos")
        swift build "${target_options[@]}"
        binary_dir="$(swift build "${target_options[@]}" --show-bin-path)"
        binary="$staging_dir/XScreenshot-$arch"
        cp "$binary_dir/XScreenshot" "$binary"
        binaries+=("$binary")
    done
    xcrun lipo -create "${binaries[@]}" -output "$executable"
else
    swift build "${build_options[@]}"
    binary_dir="$(swift build "${build_options[@]}" --show-bin-path)"
    cp "$binary_dir/XScreenshot" "$executable"
fi

for size in 16 32 128 256 512; do
    retina_size=$((size * 2))
    sips -z "$size" "$size" "$project_dir/App/AppIcon.png" \
        --out "$iconset/icon_${size}x${size}.png" >/dev/null
    sips -z "$retina_size" "$retina_size" "$project_dir/App/AppIcon.png" \
        --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil --convert icns --output "$staged_app/Contents/Resources/AppIcon.icns" "$iconset"

signing_options=(--force --sign "$signing_identity")
if [[ "$signing_identity" == "Developer ID Application:"* ]]; then
    signing_options+=(--options runtime --timestamp)
fi
codesign "${signing_options[@]}" "$staged_app"
codesign --verify --strict "$staged_app"
ditto "$staged_app" "$app"

printf 'Built %s\n' "$app"
