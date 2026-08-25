#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
APP_DIR="$PROJECT_DIR/.build/window-fixture/WarpTabFixture.app"

mkdir -p "$APP_DIR/Contents/MacOS"
cp "$PROJECT_DIR/Tests/WindowFixture/Info.plist" "$APP_DIR/Contents/Info.plist"
swiftc \
  -swift-version 5 \
  -framework AppKit \
  "$PROJECT_DIR/Tests/WindowFixture/main.swift" \
  -o "$APP_DIR/Contents/MacOS/WarpTabFixture"
codesign --force --sign - "$APP_DIR"
echo "$APP_DIR"
