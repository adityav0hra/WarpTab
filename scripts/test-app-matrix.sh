#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
HARNESS="$PROJECT_DIR/.build/warptab-app-matrix-tests"
BACKUP_DIR="$(mktemp -d)"
PREFERENCES_BACKUP="$BACKUP_DIR/preferences.plist"

defaults export com.warptab.app "$PREFERENCES_BACKUP" >/dev/null

cleanup() {
  pkill -x WarpTab 2>/dev/null || true
  defaults import com.warptab.app "$PREFERENCES_BACKUP" >/dev/null
  rm -rf "$BACKUP_DIR"
  open -n /Applications/WarpTab.app --args --background
}
trap cleanup EXIT

defaults write com.warptab.app switcherEnabled -bool true
defaults write com.warptab.app customShortcut '48,2048,Tab'
defaults write com.warptab.app switcherLayout list
defaults write com.warptab.app searchEnabled -bool true
defaults write com.warptab.app showMinimizedWindows -bool true
defaults write com.warptab.app showHiddenApplications -bool true
defaults write com.warptab.app showFullscreenWindows -bool true
defaults write com.warptab.app showOtherSpaces -bool true
defaults write com.warptab.app showWindowlessApps -bool true
defaults write com.warptab.app displayScope allDisplays
defaults delete com.warptab.app excludedBundleIdentifiers 2>/dev/null || true
pkill -x WarpTab 2>/dev/null || true
open -n /Applications/WarpTab.app --args --background
sleep 3

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
