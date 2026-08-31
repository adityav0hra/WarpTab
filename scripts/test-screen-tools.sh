#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
OUTPUT="$PROJECT_DIR/.build/warptab-screen-tools-tests"

swiftc \
  -swift-version 5 \
  -framework AppKit \
  -framework Carbon \
  -framework CoreGraphics \
  "$PROJECT_DIR/Sources/WarpTab/ShortcutMonitor.swift" \
  "$PROJECT_DIR/Sources/WarpTab/WarpWindow.swift" \
  "$PROJECT_DIR/Sources/WarpTab/WindowFilter.swift" \
  "$PROJECT_DIR/Sources/WarpTab/WarpPreferences.swift" \
  "$PROJECT_DIR/Sources/WarpTab/ColorFormatter.swift" \
  "$PROJECT_DIR/Sources/WarpTab/ScreenToolsGeometry.swift" \
  "$PROJECT_DIR/Tests/ScreenToolsHarness/main.swift" \
  -o "$OUTPUT"

"$OUTPUT"
