#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
BACKUP_DIR="$(mktemp -d)"
PREFERENCES_BACKUP="$BACKUP_DIR/preferences.plist"

defaults export com.warptab.app "$PREFERENCES_BACKUP" >/dev/null

cleanup() {
  pkill -x WarpTab 2>/dev/null || true
  defaults import com.warptab.app "$PREFERENCES_BACKUP" >/dev/null
  rm -rf "$BACKUP_DIR"
  open -n /Applications/WarpTab.app --args --background
}
trap cleanup EXIT

pkill -x WarpTab 2>/dev/null || true
open -n /Applications/WarpTab.app
sleep 1

swiftc \
  -framework AppKit \
  -framework ApplicationServices \
  "$PROJECT_DIR/Tests/SettingsHarness/main.swift" \
  -o "$BACKUP_DIR/settings-harness"
"$BACKUP_DIR/settings-harness"
