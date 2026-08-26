#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
PREFERENCES_BACKUP=$(mktemp /tmp/warptab-same-app-preferences.XXXXXX)
HARNESS="$PROJECT_DIR/.build/warptab-same-app-tests"

wait_for_exit() {
  local process_name="$1"
  for _ in {1..30}; do
    pgrep -x "$process_name" >/dev/null || return 0
    sleep 0.1
  done
  return 1
}

defaults export com.warptab.app "$PREFERENCES_BACKUP" >/dev/null

cleanup() {
  pkill -x WarpTabFixture 2>/dev/null || true
  pkill -x WarpTab 2>/dev/null || true
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
  "$PROJECT_DIR/Sources/WarpTab/WarpWindow.swift" \
  "$PROJECT_DIR/Sources/WarpTab/WindowActivator.swift" \
  "$PROJECT_DIR/Tests/IntegrationHarness/main.swift" \
  -o "$HARNESS"

for layout in list thumbnails; do
  pkill -x WarpTabFixture 2>/dev/null || true
  wait_for_exit WarpTabFixture
  pkill -x WarpTab 2>/dev/null || true
  if ! wait_for_exit WarpTab; then
    pkill -x WarpTab 2>/dev/null || true
    wait_for_exit WarpTab
  fi
  defaults write com.warptab.app switcherLayout "$layout"
  sleep 0.3
  "$fixture_app/Contents/MacOS/WarpTabFixture" >/dev/null 2>&1 &
  open -n /Applications/WarpTab.app --args --background
  sleep 3
  osascript -e 'tell application "System Events" to tell process "WarpTab" to repeat with appWindow in windows
    try
      perform action "AXClose" of appWindow
    end try
  end repeat' >/dev/null 2>&1 || true
  echo "Testing same-application shortcut in $layout layout"
  "$HARNESS" --same-app-only
done
