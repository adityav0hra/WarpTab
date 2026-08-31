#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
PREFERENCES_BACKUP=$(mktemp /tmp/warptab-stress-preferences.XXXXXX)
HARNESS="$PROJECT_DIR/.build/warptab-stress-tests"

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
defaults write com.warptab.app dockPreviewsEnabled -bool false
defaults write com.warptab.app customShortcut '48,2048,Tab'
defaults write com.warptab.app switcherLayout list
defaults write com.warptab.app searchEnabled -bool true
defaults write com.warptab.app showWindowlessApps -bool false
defaults write com.warptab.app displayScope allDisplays
defaults delete com.warptab.app excludedBundleIdentifiers 2>/dev/null || true

fixture_app=$($PROJECT_DIR/scripts/build-window-fixture.sh)
swiftc \
  -swift-version 5 \
  -target arm64-apple-macos13.0 \
  -framework AppKit \
  -framework CoreGraphics \
  -framework Vision \
  "$PROJECT_DIR/Tests/StressHarness/main.swift" \
  -o "$HARNESS"

for count in 5 20 50 100; do
  pkill -x WarpTabFixture 2>/dev/null || true
  pkill -x WarpTab 2>/dev/null || true
  open -n "$fixture_app" --args --stress "$count"
  sleep 1
  open -n /Applications/WarpTab.app --args --background
  sleep 3
  "$HARNESS" "$count"
  warp_pid=$(pgrep -x WarpTab | head -1)
  rss_kb=$(ps -o rss= -p "$warp_pid" | tr -d ' ')
  footprint_value=$(vmmap -summary "$warp_pid" 2>/dev/null | awk '/^Physical footprint:/ { print $3; exit }')
  footprint_kb=$(awk -v value="$footprint_value" 'BEGIN {
    suffix = substr(value, length(value), 1)
    amount = value + 0
    if (suffix == "G") amount *= 1024 * 1024
    else if (suffix == "M") amount *= 1024
    else if (suffix == "K") amount *= 1
    else amount /= 1024
    printf "%d", amount
  }')
  if (( footprint_kb > 393216 )); then
    echo "WarpTab physical footprint exceeded 384 MB at $count windows: ${footprint_value}" >&2
    exit 1
  fi
  echo "$count windows: WarpTab RSS ${rss_kb} KB, physical footprint ${footprint_value}"
done
