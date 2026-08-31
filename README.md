<div align="center">
  <img src="Resources/WarpTab.png" width="128" alt="WarpTab app icon">
  <h1>WarpTab</h1>
  <p><strong>A fast, native window switcher for macOS.</strong></p>
  <p>Switch between individual windows—not just applications.</p>
</div>

## Why WarpTab?

macOS shows one entry per application in its built-in <kbd>⌘</kbd> <kbd>Tab</kbd> switcher. If Safari, Finder, or another app has several windows open, reaching the one you want takes extra steps.

WarpTab gives every window its own entry in a compact, native macOS switcher. The default shortcut is <kbd>⌥</kbd> <kbd>Tab</kbd>, and it can be changed from the app.

## Highlights

- **Every window is visible** — multiple windows from the same app appear separately.
- **Two layouts** — choose a compact List or a Windows-style Thumbnail grid.
- **Minimized windows included** — select one to restore and focus it.
- **Window history that feels natural** — individual windows are ordered by most-recent use, including windows from the same app.
- **Same-app switching** — press <kbd>⌥</kbd> <kbd>`</kbd> to cycle only through windows of the current application.
- **Dock app shortcuts** — press <kbd>⌘</kbd> <kbd>1</kbd> through <kbd>⌘</kbd> <kbd>0</kbd> to launch or reveal every window of that Dock app; use <kbd>⌘</kbd> <kbd>⌥</kbd> with the number for its special character.
- **Dock window previews** — hover over a running app in the Dock to see continuously refreshed previews, including optional minimized, hidden-app, and full-screen windows. Choose Default or Small sizing, focus a window, or close it directly.
- **Windows-style snapping** — move, resize, maximize, restore, and minimize windows with directional shortcuts, optional cross-display movement, and Snap Assist.
- **Per-app Sound Mixer** — control application volumes, output devices, microphone state, and protective speaker volume after headphones disconnect.
- **Windows Extras** — optional Finder shortcuts, clipboard history, familiar key-repeat behavior, and Windows-style window controls.
- **Screen Tools** — locally recognize text and QR codes from a selected screen region or pick a colour in several copy formats.
- **Mouse customization** — remap extra buttons and side-wheel gestures to navigation, macOS actions, WarpTab tools, or custom keyboard shortcuts.
- **Stay Awake** — prevent display or system sleep from WarpTab or its optional menu-bar control.
- **Hidden, full-screen, and cross-Space windows** — WarpTab keeps discovered windows available and focuses the exact target.
- **Search and navigation** — type an app or window name, use arrows, reverse with <kbd>⇧</kbd> <kbd>Tab</kbd>, press <kbd>Return</kbd> to switch, or <kbd>Esc</kbd> to cancel.
- **Window controls** — while the switcher is open, use <kbd>⌘</kbd> <kbd>W</kbd>, <kbd>⌘</kbd> <kbd>M</kbd>, or <kbd>⌘</kbd> <kbd>H</kbd> on the selected window.
- **Custom global shortcut** — record the key and modifier combination you prefer.
- **Keyboard-first interaction** — hold the modifier, press the shortcut key to cycle, and release to switch.
- **Click-only pointer selection** — click a window to select it; merely hovering never changes the selection.
- **Native macOS utility** — AppKit interface, menu-bar access, launch at login, and a compact settings window.
- **Local and lightweight** — no accounts, analytics, or network services.

## How it works

With the default shortcut:

1. Hold <kbd>⌥ Option</kbd> and press <kbd>Tab</kbd>. WarpTab appears immediately with the next window selected.
2. Keep holding <kbd>⌥ Option</kbd> and press <kbd>Tab</kbd> again to move through the list.
3. Hold <kbd>Tab</kbd> to cycle continuously, or use the arrow keys to navigate.
4. Type to search by application or window title.
5. Release <kbd>⌥ Option</kbd> or press <kbd>Return</kbd> to open the selected window. Press <kbd>Esc</kbd> to cancel.

A quick <kbd>⌥</kbd> <kbd>Tab</kbd> press switches directly to the next window. You can also click any visible List row or Thumbnail card to select it before releasing the modifier.

Press <kbd>⌥ Option</kbd> <kbd>`</kbd> for the same interaction limited to the frontmost application. Add <kbd>Shift</kbd> to cycle backward.

## Requirements

- macOS 13 Ventura or later
- Accessibility permission for discovering and focusing windows
- Screen Recording permission only for live switcher, Dock, Snap Assist, or screen-capture previews
- Audio capture access when using per-application Sound Mixer controls
- Swift 6 / Xcode Command Line Tools when building from source

## Install with Homebrew

WarpTab is available from this repository as a Homebrew Cask for Apple Silicon Macs:

```sh
brew install --cask adityav0hra/warptab/warptab
open /Applications/WarpTab.app
```

Upgrade to the latest published version with:

```sh
brew upgrade --cask adityav0hra/warptab/warptab
```

WarpTab installs its background login launch configuration when opened from Applications.
All optional behavior is disabled on a clean first launch, so WarpTab does not request
Accessibility access until the user enables a feature that requires it.

## Build from source

Clone the repository and run the included app-bundle script:

```sh
git clone https://github.com/adityav0hra/WarpTab.git
cd WarpTab
./scripts/build-app.sh
open dist/WarpTab.app
```

The script creates an ad-hoc signed app at `dist/WarpTab.app`. To keep it in Applications:

```sh
ditto dist/WarpTab.app /Applications/WarpTab.app
open /Applications/WarpTab.app
```

macOS may ask you to confirm the first launch of a locally built copy.

## Permissions

When enabling window-management features, grant WarpTab access in:

**System Settings → Privacy & Security → Accessibility**

WarpTab detects the permission automatically and displays **Active** when window switching is ready. Features that render live window or screen content also need Screen Recording access.

## Settings

The WarpTab app lets you:

- Enable or disable global window switching
- Record a custom shortcut
- Switch between List and Thumbnail layouts
- Control search and native macOS tab handling
- Use the redesigned System Settings-style interface with dedicated Window Switcher, Dock, Permissions, and About pages
- Configure Windows-style snapping and Snap Assist behavior
- Configure the Sound Mixer, outputs, microphones, and global audio shortcuts
- Enable Stay Awake and choose where its controls appear
- Configure Finder, clipboard, keyboard, and window-management extras
- Enable or disable window previews when hovering over Dock apps
- Include or hide minimized, hidden, full-screen, other-Space, and windowless items
- Choose the switcher display and whether to show windows from every display
- Exclude applications by bundle identifier
- Review Accessibility status and open System Settings

Closing the settings window removes WarpTab from the Dock while it continues running from the menu bar. WarpTab also registers itself to launch when you sign in; choosing **Quit WarpTab** stops the current session.

## Project structure

```text
Sources/WarpTab/     AppKit application and window-switching logic
Resources/           App metadata and icon assets
scripts/build-app.sh Release build and app-bundle script
scripts/test-*.sh    Engine, live integration, Dock, UI, scale, preview, and app-matrix checks
Tests/               Deterministic harnesses and a native AppKit window fixture
Package.swift        Swift Package Manager configuration
```

## Contributing

Bug reports and focused pull requests are welcome. Run `./scripts/test-engine.sh` for the portable logic suite. The live scripts require Accessibility permission and an installed `/Applications/WarpTab.app`.

## License

WarpTab is source-available under a [proprietary license](LICENSE). Personal and
internal business use, including installation across devices controlled by one
organization, is permitted. Publishing, redistribution, sublicensing, resale,
providing WarpTab as a paid service, and distributing modified copies are not
permitted without prior written permission.
