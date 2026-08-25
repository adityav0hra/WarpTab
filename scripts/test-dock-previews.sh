#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
BACKUP_DIR="$(mktemp -d)"
PREFERENCES_BACKUP="$BACKUP_DIR/preferences.plist"
HARNESS="$BACKUP_DIR/dock-preview-harness"

defaults export com.warptab.app "$PREFERENCES_BACKUP" >/dev/null

cleanup() {
  pkill -x WarpTabFixture 2>/dev/null || true
  osascript -e 'tell application id "com.warptab.app" to quit' >/dev/null 2>&1 || true
  defaults import com.warptab.app "$PREFERENCES_BACKUP" >/dev/null
  rm -rf "$BACKUP_DIR"
  open -n /Applications/WarpTab.app --args --background
}
trap cleanup EXIT

defaults write com.warptab.app nativeTabBehavior individual
osascript -e 'tell application id "com.warptab.app" to quit' >/dev/null 2>&1 || true
pkill -x WarpTabFixture 2>/dev/null || true

fixture_app=$($PROJECT_DIR/scripts/build-window-fixture.sh)
swiftc \
  -swift-version 5 \
  -target arm64-apple-macos13.0 \
  -framework AppKit \
  -framework ApplicationServices \
  -framework CoreGraphics \
  "$PROJECT_DIR/Tests/DockPreviewHarness/main.swift" \
  -o "$HARNESS"

defaults write com.warptab.app dockPreviewsEnabled -bool false
open -n "$fixture_app"
open -n /Applications/WarpTab.app --args --background
sleep 3
"$HARNESS" --expect-hidden

osascript -e 'tell application id "com.warptab.app" to quit' >/dev/null 2>&1 || true
defaults write com.warptab.app dockPreviewsEnabled -bool true
defaults write com.warptab.app dockPreviewCloseEnabled -bool true
defaults write com.warptab.app quitAppWhenLastWindowClosed -bool false
defaults write com.warptab.app dockPreviewSize default
open -n /Applications/WarpTab.app --args --background
sleep 3
"$HARNESS" --test-dock-click

osascript -e 'tell application id "com.warptab.app" to quit' >/dev/null 2>&1 || true
pkill -x WarpTabFixture 2>/dev/null || true
defaults write com.warptab.app dockPreviewSize small
open -n "$fixture_app"
open -n /Applications/WarpTab.app --args --background
sleep 3
"$HARNESS" --expect-small

osascript -e 'tell application id "com.warptab.app" to quit' >/dev/null 2>&1 || true
pkill -x WarpTabFixture 2>/dev/null || true
defaults write com.warptab.app dockPreviewSize default
defaults write com.warptab.app dockPreviewCloseEnabled -bool false
open -n "$fixture_app"
open -n /Applications/WarpTab.app --args --background
sleep 3
"$HARNESS" --expect-no-close

osascript -e 'tell application id "com.warptab.app" to quit' >/dev/null 2>&1 || true
pkill -x WarpTabFixture 2>/dev/null || true
defaults write com.warptab.app dockPreviewCloseEnabled -bool true
defaults write com.warptab.app quitAppWhenLastWindowClosed -bool false
open -n "$fixture_app" --args --single-window
open -n /Applications/WarpTab.app --args --background
sleep 3
"$HARNESS" --last-window-keep-open

osascript -e 'tell application id "com.warptab.app" to quit' >/dev/null 2>&1 || true
pkill -x WarpTabFixture 2>/dev/null || true
defaults write com.warptab.app quitAppWhenLastWindowClosed -bool true
open -n "$fixture_app" --args --single-window
open -n /Applications/WarpTab.app --args --background
sleep 3
"$HARNESS" --last-window-quit
