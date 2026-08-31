#!/bin/zsh
set -euo pipefail

BACKUP_DIR="$(mktemp -d)"
PREFERENCES_BACKUP="$BACKUP_DIR/preferences.plist"
SAMPLE_OUTPUT="$BACKUP_DIR/sample.txt"

defaults export com.warptab.app "$PREFERENCES_BACKUP" >/dev/null

cleanup() {
  pkill -x WarpTab 2>/dev/null || true
  defaults import com.warptab.app "$PREFERENCES_BACKUP" >/dev/null
  rm -rf "$BACKUP_DIR"
  open -n /Applications/WarpTab.app --args --background
}
trap cleanup EXIT

pkill -x WarpTab 2>/dev/null || true
defaults delete com.warptab.app 2>/dev/null || true
open -n /Applications/WarpTab.app --args --background
sleep 3

warp_pid="$(pgrep -x WarpTab | head -1)"
[[ -n "$warp_pid" ]] || { echo "WarpTab did not launch" >&2; exit 1; }

sample "$warp_pid" 2 1 -file "$SAMPLE_OUTPUT" >/dev/null 2>&1
rss_kb="$(ps -o rss= -p "$warp_pid" | tr -d ' ')"
thread_count="$(ps -M "$warp_pid" | tail -n +2 | wc -l | tr -d ' ')"

if (( rss_kb > 120000 )); then
  echo "Fresh disabled idle RSS exceeded 120 MB: ${rss_kb} KB" >&2
  exit 1
fi

for symbol in \
  'DockPreviewController.trackPointer' \
  'ClipboardHistoryStore.poll' \
  'SoundManager.refresh' \
  'WindowStore.beginRefresh' \
  'MouseEventManager.process'; do
  if grep -F "$symbol" "$SAMPLE_OUTPUT" >/dev/null; then
    echo "Disabled feature was active while idle: $symbol" >&2
    exit 1
  fi
done

echo "Fresh disabled idle: ${rss_kb} KB RSS, ${thread_count} threads, no optional feature work sampled"
