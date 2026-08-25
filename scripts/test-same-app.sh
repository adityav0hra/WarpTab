#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
PREFERENCES_BACKUP=$(mktemp /tmp/warptab-same-app-preferences.XXXXXX.plist)
HARNESS="$PROJECT_DIR/.build/warptab-same-app-tests"

defaults export com.warptab.app "$PREFERENCES_BACKUP" >/dev/null

cleanup() {
  pkill -x WarpTabFixture 2>/dev/null || true
  osascript -e 'tell application id "com.warptab.app" to quit' >/dev/null 2>&1 || true
  defaults import com.warptab.app "$PREFERENCES_BACKUP" >/dev/null
  unlink "$PREFERENCES_BACKUP" 2>/dev/null || true
  open -n /Applications/WarpTab.app --args --background
}
trap cleanup EXIT

defaults write com.warptab.app switcherEnabled -bool true
defaults write com.warptab.app customShortcut '48,2048,Tab'
defaults write com.warptab.app nativeTabBehavior individual
defaults write com.warptab.app showWindowlessApps -bool false

fixture_app=$($PROJECT_DIR/scripts/build-window-fixture.sh)
swiftc \
  -swift-version 5 \
  -target arm64-apple-macos13.0 \
  -framework AppKit \
  -framework ApplicationServices \
  -framework CoreGraphics \
  -framework Vision \
  "$PROJECT_DIR/Tests/IntegrationHarness/main.swift" \
  -o "$HARNESS"

for layout in list thumbnails; do
  pkill -x WarpTabFixture 2>/dev/null || true
  osascript -e 'tell application id "com.warptab.app" to quit' >/dev/null 2>&1 || true
  defaults write com.warptab.app switcherLayout "$layout"
  sleep 0.3
  "$fixture_app/Contents/MacOS/WarpTabFixture" >/dev/null 2>&1 &
  open -n /Applications/WarpTab.app --args --background
  sleep 3
  echo "Testing same-application shortcut in $layout layout"
  "$HARNESS" --same-app-only
done
