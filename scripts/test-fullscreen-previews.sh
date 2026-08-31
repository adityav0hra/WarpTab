#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
TEMP_DIR="$(mktemp -d)"
HARNESS="$TEMP_DIR/fullscreen-preview-harness"

cleanup() {
  pkill -x WarpTabFixture 2>/dev/null || true
  rm -rf "$TEMP_DIR"
}
trap cleanup EXIT

fixture_app=$($PROJECT_DIR/scripts/build-window-fixture.sh)
swiftc \
  -swift-version 5 \
  -target arm64-apple-macos13.0 \
  -framework AppKit \
  -framework ApplicationServices \
  -framework CoreGraphics \
  -framework ScreenCaptureKit \
  "$PROJECT_DIR/Sources/WarpTab/WarpWindow.swift" \
  "$PROJECT_DIR/Sources/WarpTab/PreviewCache.swift" \
  "$PROJECT_DIR/Tests/FullscreenPreviewHarness/main.swift" \
  -o "$HARNESS"

pkill -x WarpTabFixture 2>/dev/null || true
open -n "$fixture_app" --args --live-preview
sleep 1
"$HARNESS"
