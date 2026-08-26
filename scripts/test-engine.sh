#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
OUTPUT="$PROJECT_DIR/.build/warptab-engine-tests"

swiftc \
  -swift-version 5 \
  -framework AppKit \
  -framework ApplicationServices \
  -framework CoreGraphics \
  "$PROJECT_DIR/Sources/WarpTab/MRUManager.swift" \
  "$PROJECT_DIR/Sources/WarpTab/NativeTabSupport.swift" \
  "$PROJECT_DIR/Sources/WarpTab/WarpWindow.swift" \
  "$PROJECT_DIR/Sources/WarpTab/WindowFilter.swift" \
  "$PROJECT_DIR/Sources/WarpTab/WindowSearch.swift" \
  "$PROJECT_DIR/Sources/WarpTab/WarpPreferences.swift" \
  "$PROJECT_DIR/Sources/WarpTab/WindowSnapModel.swift" \
  "$PROJECT_DIR/Tests/EngineHarness/main.swift" \
  -o "$OUTPUT"

"$OUTPUT"
