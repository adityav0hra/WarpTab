#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
cd "$PROJECT_DIR"

WARP_DEVELOPER_DIR="${DEVELOPER_DIR:-$(xcode-select -p)}"
if [[ "$WARP_DEVELOPER_DIR" == "/Library/Developer/CommandLineTools" && \
      -d /Applications/Xcode.app/Contents/Developer ]]; then
  WARP_DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
export DEVELOPER_DIR="$WARP_DEVELOPER_DIR"

mkdir -p .build/clang-cache
export CLANG_MODULE_CACHE_PATH="$PROJECT_DIR/.build/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PROJECT_DIR/.build/clang-cache"

swift build -c release

APP_DIR="dist/WarpTab.app"
CONTROL_DIR="$APP_DIR/Contents/PlugIns/WarpTabControls.appex"
WARP_CODESIGN_IDENTITY="${WARP_CODESIGN_IDENTITY:--}"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources" "$CONTROL_DIR/Contents/MacOS"
cp Resources/Info.plist "$APP_DIR/Contents/Info.plist"
cp .build/release/WarpTab "$APP_DIR/Contents/MacOS/WarpTab"
cp Resources/WarpTab.icns "$APP_DIR/Contents/Resources/WarpTab.icns"
cp LICENSE "$APP_DIR/Contents/Resources/LICENSE"

xcodebuild \
  -quiet \
  -project WarpTabControls.xcodeproj \
  -target WarpTabControls \
  -configuration Release \
  CONFIGURATION_BUILD_DIR="$PROJECT_DIR/.build/controls-release" \
  OBJROOT="$PROJECT_DIR/.build/xcode-objects" \
  SYMROOT="$PROJECT_DIR/.build/xcode-products" \
  ARCHS=arm64 \
  ONLY_ACTIVE_ARCH=NO \
  CODE_SIGNING_ALLOWED=NO \
  build
rm -rf "$CONTROL_DIR"
cp -R .build/controls-release/WarpTabControls.appex "$CONTROL_DIR"

typeset -a signing_options
signing_options=(--force --sign "$WARP_CODESIGN_IDENTITY")
if [[ "$WARP_CODESIGN_IDENTITY" != "-" ]]; then
  signing_options+=(--options runtime --timestamp)
fi

codesign "${signing_options[@]}" \
  --entitlements Resources/WarpTabControls.entitlements \
  "$CONTROL_DIR"
codesign "${signing_options[@]}" "$APP_DIR"
codesign --verify --deep --strict --verbose=2 "$APP_DIR"

if [[ "$WARP_CODESIGN_IDENTITY" == "-" ]]; then
  echo "Built ad-hoc signed $APP_DIR"
else
  echo "Built Developer ID signed $APP_DIR"
fi
