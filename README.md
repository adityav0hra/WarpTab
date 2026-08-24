# WarpTab

A lightweight, native macOS window switcher with a full settings app. Unlike the built-in app switcher, WarpTab shows every open window as a separate choice—even multiple windows from the same app.

## Features

- Separate entries for every standard app window
- Native macOS translucent panel and app icons
- Reliable `⌥ Tab` global shortcut from the app or menu-bar icon
- Hold `⌥`, tap Tab repeatedly to choose, and release `⌥` to switch
- Restores minimized windows when selected
- Full app window for enabling the switcher, choosing a shortcut, and checking permissions
- Menu-bar access, with a Dock icon while settings are open

## Build and run

```sh
chmod +x scripts/build-app.sh
./scripts/build-app.sh
open dist/WarpTab.app
```

On first launch, allow WarpTab under **System Settings → Privacy & Security → Accessibility**. The `⌥ Tab` shortcut itself does not require Input Monitoring. WarpTab automatically detects newly granted permission and shows a green **Active** status when ready.

Because this local build is ad-hoc signed rather than notarized, macOS may ask you to confirm opening it. This prototype is intended for direct local installation, not Mac App Store distribution.
