#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
cd "$PROJECT_DIR"

: "${WARP_CODESIGN_IDENTITY:?Set WARP_CODESIGN_IDENTITY to a Developer ID Application certificate name.}"
: "${WARP_NOTARY_PROFILE:?Set WARP_NOTARY_PROFILE to an xcrun notarytool keychain profile.}"

[[ "$WARP_CODESIGN_IDENTITY" == "Developer ID Application:"* ]] || {
  echo "WARP_CODESIGN_IDENTITY must name a Developer ID Application certificate." >&2
  exit 1
}
security find-identity -v -p codesigning | grep -F -- "$WARP_CODESIGN_IDENTITY" >/dev/null || {
  echo "Developer ID identity is not installed or is not valid: $WARP_CODESIGN_IDENTITY" >&2
  exit 1
}
xcrun notarytool history --keychain-profile "$WARP_NOTARY_PROFILE" >/dev/null || {
  echo "The notarytool keychain profile is missing or invalid: $WARP_NOTARY_PROFILE" >&2
  exit 1
}

WARP_CODESIGN_IDENTITY="$WARP_CODESIGN_IDENTITY" "$SCRIPT_DIR/build-app.sh"

version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' dist/WarpTab.app/Contents/Info.plist)
[[ "$version" == <->.* ]] || { echo "Invalid app version: $version" >&2; exit 1; }
archive="dist/WarpTab-${version}.zip"
rm -f "$archive"
ditto -c -k --keepParent dist/WarpTab.app "$archive"

xcrun notarytool submit "$archive" \
  --keychain-profile "$WARP_NOTARY_PROFILE" \
  --wait
xcrun stapler staple dist/WarpTab.app
xcrun stapler validate dist/WarpTab.app
codesign --verify --deep --strict --verbose=2 dist/WarpTab.app
spctl --assess --type execute --verbose=4 dist/WarpTab.app

# Recreate the download after stapling so the ticket is present in the archive.
rm -f "$archive"
ditto -c -k --keepParent dist/WarpTab.app "$archive"
shasum -a 256 "$archive"
echo "Notarized release ready: $archive"
