#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
HARNESS="$PROJECT_DIR/.build/warptab-app-matrix-tests"

swiftc \
  -swift-version 5 \
  -target arm64-apple-macos13.0 \
  -framework AppKit \
  -framework CoreGraphics \
  "$PROJECT_DIR/Tests/AppMatrixHarness/main.swift" \
  -o "$HARNESS"

typeset -a matrix=(
  'safari|Safari'
  'finder|Finder'
  'terminal|Terminal'
  'calendar|Calendar'
  'microsoft word|Microsoft Word'
  'outlook|Microsoft Outlook'
  'wireshark|Wireshark'
  'chatgpt|ChatGPT'
)

for entry in $matrix; do
  query=${entry%%|*}
  expected=${entry#*|}
  if osascript -e "application \"$expected\" is running" 2>/dev/null | rg -q '^true$'; then
    "$HARNESS" "$query" "$expected"
  else
    echo "$expected: skipped (not running)"
  fi
done
