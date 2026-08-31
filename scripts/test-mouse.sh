#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
TEST_OUTPUT_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_OUTPUT_DIR"' EXIT

swiftc \
  -framework AppKit \
  -framework CoreGraphics \
  "$PROJECT_DIR/Sources/WarpTab/MouseSettings.swift" \
  "$PROJECT_DIR/Sources/WarpTab/MouseEventManager.swift" \
  "$PROJECT_DIR/Tests/MouseHarness/main.swift" \
  -o "$TEST_OUTPUT_DIR/mouse-harness"

"$TEST_OUTPUT_DIR/mouse-harness"
