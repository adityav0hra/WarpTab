#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
BACKUP_DIR="$(mktemp -d)"
PREFERENCES_BACKUP="$BACKUP_DIR/preferences.plist"

wait_for_exit() {
  for _ in {1..30}; do
    pgrep -x WarpTab >/dev/null || return 0
    sleep 0.1
  done
  return 1
}

defaults export com.warptab.app "$PREFERENCES_BACKUP" >/dev/null

cleanup() {
  pkill -x WarpTab 2>/dev/null || true
  defaults import com.warptab.app "$PREFERENCES_BACKUP" >/dev/null
  rm -rf "$BACKUP_DIR"
  open -n /Applications/WarpTab.app --args --background
}
trap cleanup EXIT

pkill -x WarpTab 2>/dev/null || true
wait_for_exit
defaults write com.warptab.app customShortcut '48,2048,Tab'
defaults write com.warptab.app showViewStyleInWarpTabMenu -bool true
defaults write com.warptab.app dockPreviewsEnabled -bool true
defaults write com.warptab.app minimizeAllWindowsOnDockDoubleClick -bool true
open -n /Applications/WarpTab.app
sleep 1

swiftc \
  -framework AppKit \
  -framework ApplicationServices \
  "$PROJECT_DIR/Tests/SettingsHarness/main.swift" \
  -o "$BACKUP_DIR/settings-harness"
"$BACKUP_DIR/settings-harness" "$@"
