#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
BACKUP_DIR="$(mktemp -d)"
PREFERENCES_BACKUP="$BACKUP_DIR/preferences.plist"
HARNESS="$BACKUP_DIR/dock-preview-harness"

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
  "$PROJECT_DIR/Tests/DockPreviewHarness/main.swift" \
  -o "$HARNESS"

if [[ "${1:-}" == "--aspect-only" ]]; then
  defaults write com.warptab.app dockPreviewsEnabled -bool true
  defaults write com.warptab.app dockPreviewSize default
  open -n "$fixture_app" --args --aspect-previews
  open -n /Applications/WarpTab.app --args --background
  sleep 3
  "$HARNESS" --expect-aspect-fit
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
