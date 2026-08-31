#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
BACKUP_DIR="$(mktemp -d)"
PREFERENCES_BACKUP="$BACKUP_DIR/preferences.plist"
missing_preference_keys=()
for key in showScreenTextInWarpTabMenu showColorPickerInWarpTabMenu showWarpTabStatusItem; do
  defaults read com.warptab.app "$key" >/dev/null 2>&1 || missing_preference_keys+=("$key")
done

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
  for key in "${missing_preference_keys[@]}"; do
    defaults delete com.warptab.app "$key" 2>/dev/null || true
  done
  rm -rf "$BACKUP_DIR"
  open -n /Applications/WarpTab.app --args --background
}
trap cleanup EXIT

pkill -x WarpTab 2>/dev/null || true
wait_for_exit
defaults write com.warptab.app customShortcut '48,2048,Tab'
defaults write com.warptab.app showViewStyleInWarpTabMenu -bool true
defaults write com.warptab.app showScreenTextInWarpTabMenu -bool false
defaults write com.warptab.app showColorPickerInWarpTabMenu -bool false
defaults write com.warptab.app showWarpTabStatusItem -bool true
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
