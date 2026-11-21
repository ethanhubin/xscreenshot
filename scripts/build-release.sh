#!/bin/bash
set -euo pipefail

project_dir="$(cd -- "$(dirname -- "$0")/.." && pwd)"
release_dir="$project_dir/release"
signing_identity="${XSCREENSHOT_SIGN_IDENTITY:--}"
notary_profile="${XSCREENSHOT_NOTARY_PROFILE:-}"
if [[ -n "$notary_profile" && "$signing_identity" != "Developer ID Application:"* ]]; then
    printf 'Set XSCREENSHOT_SIGN_IDENTITY to a Developer ID Application certificate name to notarize the release.\n' >&2
    exit 1
fi

mkdir -p "$release_dir"
staging_dir="$(mktemp -d "$release_dir/.xscreenshot.XXXXXX")"
trap 'rm -rf "$staging_dir"' EXIT
payload="$staging_dir/payload"
mkdir "$payload"

XSCREENSHOT_APP_OUTPUT="$payload/XScreenshot.app" \
    "$project_dir/scripts/build-app.sh" --universal "$@"
ln -s /Applications "$payload/Applications"

image="$staging_dir/XScreenshot.dmg"
hdiutil create -format UDZO -volname XScreenshot -srcfolder "$payload" "$image"
if [[ "$signing_identity" == "Developer ID Application:"* ]]; then
    codesign --sign "$signing_identity" --timestamp "$image"
fi
if [[ -n "$notary_profile" ]]; then
    xcrun notarytool submit "$image" --keychain-profile "$notary_profile" --wait
    xcrun stapler staple "$image"
    xcrun stapler validate "$image"
fi

hdiutil verify "$image"
mv -f "$image" "$release_dir/XScreenshot.dmg"
printf 'Built %s\n' "$release_dir/XScreenshot.dmg"
