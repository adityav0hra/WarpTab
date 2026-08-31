#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
if [[ "${1:-}" == "--fullscreen-only" ]]; then
  exec "$PROJECT_DIR/scripts/test-fullscreen-previews.sh"
fi
BACKUP_DIR="$(mktemp -d)"
PREFERENCES_BACKUP="$BACKUP_DIR/preferences.plist"
HARNESS="$BACKUP_DIR/dock-preview-harness"

# Every mode relaunches both processes. Wait for termination instead of letting
# a previous WarpTab event tap overlap the next test for a few milliseconds.
pkill() {
  local kill_status=0
  command pkill "$@" || kill_status=$?
  if [[ "${1:-}" == "-x" && -n "${2:-}" ]]; then
    for _ in {1..60}; do
      command pgrep -x "$2" >/dev/null || return "$kill_status"
      sleep 0.05
    done
    echo "Process did not exit before the next Dock test: $2" >&2
    return 2
  fi
  return "$kill_status"
}

defaults export com.warptab.app "$PREFERENCES_BACKUP" >/dev/null

cleanup() {
  pkill -x WarpTabFixture 2>/dev/null || true
  pkill -x WarpTab 2>/dev/null || true
  defaults import com.warptab.app "$PREFERENCES_BACKUP" >/dev/null
  rm -rf "$BACKUP_DIR"
  open -n /Applications/WarpTab.app --args --background
}
trap cleanup EXIT

defaults write com.warptab.app nativeTabBehavior individual
pkill -x WarpTab 2>/dev/null || true
pkill -x WarpTabFixture 2>/dev/null || true

fixture_app=$($PROJECT_DIR/scripts/build-window-fixture.sh)
swiftc \
  -swift-version 5 \
  -target arm64-apple-macos13.0 \
  -framework AppKit \
  -framework ApplicationServices \
  -framework CoreGraphics \
  -framework Vision \
  "$PROJECT_DIR/Tests/DockPreviewHarness/main.swift" \
  -o "$HARNESS"

if [[ "${1:-}" == "--real-app-only" ]]; then
  [[ -n "${2:-}" ]] || { echo "Usage: $0 --real-app-only <bundle-identifier>" >&2; exit 2; }
  defaults write com.warptab.app dockPreviewsEnabled -bool true
  defaults write com.warptab.app chooseWindowOnMultiWindowDockClick -bool true
  pkill -x WarpTab 2>/dev/null || true
  open -n /Applications/WarpTab.app --args --background
  sleep 3
  "$HARNESS" --real-app-click "$2"
  exit 0
fi

if [[ "${1:-}" == "--aspect-only" ]]; then
  defaults write com.warptab.app dockPreviewsEnabled -bool true
  defaults write com.warptab.app dockPreviewSize default
  open -n "$fixture_app" --args --aspect-previews
  open -n /Applications/WarpTab.app --args --background
  sleep 3
  "$HARNESS" --expect-aspect-fit
  exit 0
fi

if [[ "${1:-}" == "--empty-only" ]]; then
  defaults write com.warptab.app dockPreviewsEnabled -bool true
  open -n "$fixture_app" --args --no-window
  open -n /Applications/WarpTab.app --args --background
  sleep 3
  "$HARNESS" --expect-empty
  exit 0
fi

if [[ "${1:-}" == "--latency-only" ]]; then
  defaults write com.warptab.app dockPreviewsEnabled -bool true
  open -n "$fixture_app"
  open -n /Applications/WarpTab.app --args --background
  sleep 3
  "$HARNESS" --expect-latency
  exit 0
fi

if [[ "${1:-}" == "--stress-only" ]]; then
  defaults write com.warptab.app dockPreviewsEnabled -bool true
  defaults write com.warptab.app dockPreviewShowMinimized -bool true
  defaults write com.warptab.app dockPreviewShowHiddenApplications -bool true
  defaults write com.warptab.app dockPreviewShowFullscreen -bool true
  defaults write com.warptab.app animationsEnabled -bool false
  open -n "$fixture_app" --args --stress 100
  open -n /Applications/WarpTab.app --args --background
  sleep 3
  "$HARNESS" --expect-latency --hold-open &
  harness_pid=$!
  sleep 2
  warp_pid=$(pgrep -x WarpTab | head -1)
  [[ -n "$warp_pid" ]] || { echo "WarpTab is not running" >&2; exit 1; }
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
  if (( footprint_kb > 196608 )); then
    echo "Dock preview physical footprint exceeded 192 MB at 100 windows: ${footprint_value}" >&2
    exit 1
  fi
  wait "$harness_pid"
  echo "100-window Dock preview physical footprint: ${footprint_value}"
  exit 0
fi

if [[ "${1:-}" == "--live-only" ]]; then
  defaults write com.warptab.app dockPreviewsEnabled -bool true
  defaults write com.warptab.app animationsEnabled -bool false
  open -n "$fixture_app" --args --live-preview
  open -n /Applications/WarpTab.app --args --background
  sleep 2
  "$HARNESS" --expect-live-refresh
  exit 0
fi

if [[ "${1:-}" == "--close-background-only" ]]; then
  defaults write com.warptab.app dockPreviewsEnabled -bool true
  defaults write com.warptab.app dockPreviewCloseEnabled -bool true
  defaults write com.warptab.app quitAppWhenLastWindowClosed -bool false
  defaults write com.warptab.app dockPreviewSize default
  open -n "$fixture_app"
  open -n /Applications/WarpTab.app --args --background
  sleep 3
  "$HARNESS" --close-background-only
  exit 0
fi

if [[ "${1:-}" == "--last-window-quit-only" || "${1:-}" == "--last-window-keep-open-only" ]]; then
  defaults write com.warptab.app dockPreviewsEnabled -bool true
  defaults write com.warptab.app dockPreviewCloseEnabled -bool true
  if [[ "${1:-}" == "--last-window-quit-only" ]]; then
    defaults write com.warptab.app quitAppWhenLastWindowClosed -bool true
    harness_mode="--last-window-quit"
  else
    defaults write com.warptab.app quitAppWhenLastWindowClosed -bool false
    harness_mode="--last-window-keep-open"
  fi
  open -n "$fixture_app" --args --single-window
  open -n /Applications/WarpTab.app --args --background
  sleep 3
  "$HARNESS" "$harness_mode"
  exit 0
fi

if [[ "${1:-}" == "--minimize-only" ]]; then
  defaults write com.warptab.app dockPreviewsEnabled -bool true
  defaults write com.warptab.app minimizeFrontmostWindowOnDockClick -bool true
  defaults write com.warptab.app chooseWindowOnMultiWindowDockClick -bool true
  open -n "$fixture_app" --args --single-window
  open -n /Applications/WarpTab.app --args --background
  sleep 3
  "$HARNESS" --expect-active-dock-minimize
  exit 0
fi

if [[ "${1:-}" == "--chooser-only" ]]; then
  defaults write com.warptab.app dockPreviewsEnabled -bool true
  defaults write com.warptab.app minimizeFrontmostWindowOnDockClick -bool true
  defaults write com.warptab.app chooseWindowOnMultiWindowDockClick -bool true
  open -n "$fixture_app"
  open -n /Applications/WarpTab.app --args --background
  sleep 3
  "$HARNESS" --expect-multi-window-chooser
  exit 0
fi

if [[ "${1:-}" == "--double-click-only" ]]; then
  defaults write com.warptab.app dockPreviewsEnabled -bool true
  defaults write com.warptab.app minimizeFrontmostWindowOnDockClick -bool true
  defaults write com.warptab.app chooseWindowOnMultiWindowDockClick -bool true
  defaults write com.warptab.app minimizeAllWindowsOnDockDoubleClick -bool true
  defaults write com.warptab.app dockDoubleClickMinimizeScope allWindows
  open -n "$fixture_app"
  open -n /Applications/WarpTab.app --args --background
  sleep 3
  "$HARNESS" --expect-double-click-minimize-all
  exit 0
fi

if [[ "${1:-}" == "--double-click-top-only" ]]; then
  defaults write com.warptab.app dockPreviewsEnabled -bool true
  defaults write com.warptab.app minimizeFrontmostWindowOnDockClick -bool true
  defaults write com.warptab.app chooseWindowOnMultiWindowDockClick -bool true
  defaults write com.warptab.app minimizeAllWindowsOnDockDoubleClick -bool true
  defaults write com.warptab.app dockDoubleClickMinimizeScope topWindow
  open -n "$fixture_app"
  open -n /Applications/WarpTab.app --args --background
  sleep 3
  "$HARNESS" --expect-double-click-minimize-top
  exit 0
fi

if [[ "${1:-}" == "--double-click-disabled-only" ]]; then
  defaults write com.warptab.app dockPreviewsEnabled -bool true
  defaults write com.warptab.app minimizeFrontmostWindowOnDockClick -bool true
  defaults write com.warptab.app chooseWindowOnMultiWindowDockClick -bool true
  defaults write com.warptab.app minimizeAllWindowsOnDockDoubleClick -bool false
  open -n "$fixture_app"
  open -n /Applications/WarpTab.app --args --background
  sleep 3
  "$HARNESS" --expect-double-click-preserved
  exit 0
fi

defaults write com.warptab.app dockPreviewsEnabled -bool false
open -n "$fixture_app"
open -n /Applications/WarpTab.app --args --background
sleep 3
"$HARNESS" --expect-hidden

pkill -x WarpTab 2>/dev/null || true
defaults write com.warptab.app dockPreviewsEnabled -bool true
defaults write com.warptab.app dockPreviewCloseEnabled -bool true
defaults write com.warptab.app quitAppWhenLastWindowClosed -bool false
defaults write com.warptab.app dockPreviewSize default
defaults write com.warptab.app minimizeFrontmostWindowOnDockClick -bool false
defaults write com.warptab.app chooseWindowOnMultiWindowDockClick -bool false
open -n /Applications/WarpTab.app --args --background
sleep 3
"$HARNESS" --test-dock-click

pkill -x WarpTab 2>/dev/null || true
pkill -x WarpTabFixture 2>/dev/null || true
defaults write com.warptab.app dockPreviewSize small
open -n "$fixture_app"
open -n /Applications/WarpTab.app --args --background
sleep 3
"$HARNESS" --expect-small

pkill -x WarpTab 2>/dev/null || true
pkill -x WarpTabFixture 2>/dev/null || true
defaults write com.warptab.app dockPreviewSize default
open -n "$fixture_app" --args --aspect-previews
open -n /Applications/WarpTab.app --args --background
sleep 3
"$HARNESS" --expect-aspect-fit

pkill -x WarpTab 2>/dev/null || true
pkill -x WarpTabFixture 2>/dev/null || true
defaults write com.warptab.app chooseWindowOnMultiWindowDockClick -bool true
open -n "$fixture_app"
open -n /Applications/WarpTab.app --args --background
sleep 3
"$HARNESS" --expect-multi-window-chooser

pkill -x WarpTab 2>/dev/null || true
pkill -x WarpTabFixture 2>/dev/null || true
defaults write com.warptab.app minimizeFrontmostWindowOnDockClick -bool true
defaults write com.warptab.app chooseWindowOnMultiWindowDockClick -bool true
open -n "$fixture_app" --args --single-window
open -n /Applications/WarpTab.app --args --background
sleep 3
"$HARNESS" --expect-active-dock-minimize

pkill -x WarpTab 2>/dev/null || true
pkill -x WarpTabFixture 2>/dev/null || true
defaults write com.warptab.app minimizeFrontmostWindowOnDockClick -bool false
defaults write com.warptab.app chooseWindowOnMultiWindowDockClick -bool false
open -n "$fixture_app" --args --live-preview
open -n /Applications/WarpTab.app --args --background
sleep 3
"$HARNESS" --expect-live-refresh

pkill -x WarpTab 2>/dev/null || true
pkill -x WarpTabFixture 2>/dev/null || true
defaults write com.warptab.app dockPreviewShowMinimized -bool true
open -n "$fixture_app"
open -n /Applications/WarpTab.app --args --background
sleep 3
"$HARNESS" --prepare-minimized --expect-special-visible

pkill -x WarpTab 2>/dev/null || true
pkill -x WarpTabFixture 2>/dev/null || true
defaults write com.warptab.app dockPreviewShowMinimized -bool false
open -n "$fixture_app"
open -n /Applications/WarpTab.app --args --background
sleep 3
"$HARNESS" --prepare-minimized --expect-filtered-hidden

pkill -x WarpTab 2>/dev/null || true
pkill -x WarpTabFixture 2>/dev/null || true
defaults write com.warptab.app dockPreviewShowHiddenApplications -bool true
open -n "$fixture_app"
open -n /Applications/WarpTab.app --args --background
sleep 3
"$HARNESS" --prepare-hidden --expect-special-visible

pkill -x WarpTab 2>/dev/null || true
pkill -x WarpTabFixture 2>/dev/null || true
defaults write com.warptab.app dockPreviewShowHiddenApplications -bool false
open -n "$fixture_app"
open -n /Applications/WarpTab.app --args --background
sleep 3
"$HARNESS" --prepare-hidden --expect-filtered-hidden

pkill -x WarpTab 2>/dev/null || true
pkill -x WarpTabFixture 2>/dev/null || true
defaults write com.warptab.app dockPreviewCloseEnabled -bool false
open -n "$fixture_app"
open -n /Applications/WarpTab.app --args --background
sleep 3
"$HARNESS" --expect-no-close

pkill -x WarpTab 2>/dev/null || true
pkill -x WarpTabFixture 2>/dev/null || true
defaults write com.warptab.app dockPreviewCloseEnabled -bool true
defaults write com.warptab.app quitAppWhenLastWindowClosed -bool false
open -n "$fixture_app" --args --single-window
open -n /Applications/WarpTab.app --args --background
sleep 3
"$HARNESS" --last-window-keep-open

pkill -x WarpTab 2>/dev/null || true
pkill -x WarpTabFixture 2>/dev/null || true
defaults write com.warptab.app quitAppWhenLastWindowClosed -bool true
open -n "$fixture_app" --args --single-window
open -n /Applications/WarpTab.app --args --background
sleep 3
"$HARNESS" --last-window-quit
