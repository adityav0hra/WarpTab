#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
PREFERENCES_BACKUP=$(mktemp /tmp/warptab-thumbnail-preferences.XXXXXX)
HARNESS="$PROJECT_DIR/.build/warptab-thumbnail-tests"
OUTPUT="/tmp/warptab-thumbnail-modern.png"

defaults export com.warptab.app "$PREFERENCES_BACKUP" >/dev/null

cleanup() {
  pkill -x WarpTabFixture 2>/dev/null || true
  pkill -x WarpTab 2>/dev/null || true
  defaults import com.warptab.app "$PREFERENCES_BACKUP" >/dev/null
  rm -f "$PREFERENCES_BACKUP"
  open -n /Applications/WarpTab.app --args --background
}
trap cleanup EXIT

defaults write com.warptab.app switcherEnabled -bool true
defaults write com.warptab.app customShortcut '48,2048,Tab'
defaults write com.warptab.app switcherLayout thumbnails
defaults write com.warptab.app previewsEnabled -bool true
defaults write com.warptab.app nativeTabBehavior individual

fixture_app=$($PROJECT_DIR/scripts/build-window-fixture.sh)
pkill -x WarpTabFixture 2>/dev/null || true
pkill -x WarpTab 2>/dev/null || true
open -n "$fixture_app"
sleep 1
open -n /Applications/WarpTab.app --args --background
sleep 3

swiftc \
  -swift-version 5 \
  -target arm64-apple-macos13.0 \
  -framework AppKit \
  -framework CoreGraphics \
  -framework ImageIO \
  -framework UniformTypeIdentifiers \
  "$PROJECT_DIR/Tests/ThumbnailHarness/main.swift" \
  -o "$HARNESS"

"$HARNESS" "$OUTPUT"
