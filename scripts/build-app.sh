#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
cd "$PROJECT_DIR"

mkdir -p .build/clang-cache
export CLANG_MODULE_CACHE_PATH="$PROJECT_DIR/.build/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PROJECT_DIR/.build/clang-cache"

swift build -c release

APP_DIR="dist/WarpTab.app"
CONTROL_DIR="$APP_DIR/Contents/PlugIns/WarpTabControls.appex"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources" "$CONTROL_DIR/Contents/MacOS"
cp Resources/Info.plist "$APP_DIR/Contents/Info.plist"
cp .build/release/WarpTab "$APP_DIR/Contents/MacOS/WarpTab"
cp Resources/WarpTab.icns "$APP_DIR/Contents/Resources/WarpTab.icns"
cp LICENSE "$APP_DIR/Contents/Resources/LICENSE"

xcodebuild \
  -project WarpTabControls.xcodeproj \
  -target WarpTabControls \
  -configuration Release \
  CONFIGURATION_BUILD_DIR="$PROJECT_DIR/.build/controls-release" \
  CODE_SIGN_IDENTITY=- \
  DEVELOPMENT_TEAM= \
  build
rm -rf "$CONTROL_DIR"
cp -R .build/controls-release/WarpTabControls.appex "$CONTROL_DIR"

codesign --force --sign - \
  --requirements '=designated => identifier "com.warptab.app"' \
  "$APP_DIR"

echo "Built $APP_DIR"
