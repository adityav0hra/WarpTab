#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
PREFERENCES_BACKUP=$(mktemp /tmp/warptab-preferences.XXXXXX)
HARNESS="$PROJECT_DIR/.build/warptab-integration-tests"

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
  rm -f "$PREFERENCES_BACKUP"
  open -n /Applications/WarpTab.app --args --background
}
trap cleanup EXIT

defaults write com.warptab.app switcherEnabled -bool true
defaults write com.warptab.app customShortcut '48,2048,Tab'
defaults write com.warptab.app switcherLayout list
defaults write com.warptab.app nativeTabBehavior individual
defaults write com.warptab.app searchEnabled -bool true
defaults write com.warptab.app showMinimizedWindows -bool true
defaults write com.warptab.app showHiddenApplications -bool true
defaults write com.warptab.app showFullscreenWindows -bool true
defaults write com.warptab.app showOtherSpaces -bool true
defaults write com.warptab.app showWindowlessApps -bool false
defaults write com.warptab.app displayScope allDisplays
defaults delete com.warptab.app excludedBundleIdentifiers 2>/dev/null || true

if [[ "${1:-}" == "--single-window-promotion-only" ]]; then
  regular_bundle_ids=("${(@f)$(osascript -l JavaScript -e 'ObjC.import("AppKit"); $.NSWorkspace.sharedWorkspace.runningApplications.js.filter(a => Number(a.activationPolicy) === 0).map(a => ObjC.unwrap(a.bundleIdentifier)).filter(x => x).join("\n")')}")
  defaults write com.warptab.app excludedBundleIdentifiers -array "${regular_bundle_ids[@]}"
fi

fixture_app=$($PROJECT_DIR/scripts/build-window-fixture.sh)
pkill -x WarpTabFixture 2>/dev/null || true
pkill -x WarpTab 2>/dev/null || true
wait_for_exit WarpTabFixture
wait_for_exit WarpTab
if [[ "${1:-}" == "--focus-stability-only" ]]; then
  "$fixture_app/Contents/MacOS/WarpTabFixture" --size-transition >/dev/null 2>&1 &
else
  "$fixture_app/Contents/MacOS/WarpTabFixture" >/dev/null 2>&1 &
fi
sleep 1
/Applications/WarpTab.app/Contents/MacOS/WarpTab --background >/dev/null 2>&1 &
sleep 3

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

"$HARNESS" "$@"
