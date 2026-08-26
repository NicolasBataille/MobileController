# DemoApp

A minimal SwiftUI iOS app that exists for one reason: to be a **public, deterministic
benchmark target** for simulator-automation tools.

Apple Settings (`com.apple.Preferences`) is the zero-setup default target for `bench/run.sh`,
but its content shifts between iOS versions and it offers no animation you control. DemoApp
fills that gap: a tab bar to transition between, a 40-row list to snapshot, a text field for
the fill / read-back / clear path, and **one explicit 300 ms animated transition** that gives
`simprobe wait-stable` and `simprobe motion` a ground truth to be measured against.

No network calls. No persistence. No personal data. Every screen is derived from constants in
this bundle, so two runs on two machines render the same pixels for the same taps.

- Bundle identifier: `dev.mobilecontroller.demoapp`
- Deployment target: iOS 17.0
- Portrait only, iPhone only (one fixed geometry, so frames stay comparable)

## Build

The `.xcodeproj` is **generated, never committed** (the repo's root `.gitignore` carries
`*.xcodeproj`). `project.yml` is the source of truth; XcodeGen turns it into a project.

```bash
# One-time, if you don't have it:
brew install xcodegen

cd DemoApp
xcodegen generate
xcodebuild -scheme DemoApp \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/demoapp-dd \
  build
```

`generic/platform=iOS Simulator` needs no booted simulator. Signing is disabled for the
target (`CODE_SIGNING_ALLOWED=NO`), so a fresh clone builds with no developer team.

The built app lands at:

```
/tmp/demoapp-dd/Build/Products/Debug-iphonesimulator/DemoApp.app
```

## Install on a simulator

```bash
# Pick a device (or use `booted` for the currently booted one):
xcrun simctl list devices available

UDID=<udid>          # e.g. the output of the line above
xcrun simctl boot "$UDID"        # skip if already booted
xcrun simctl install "$UDID" /tmp/demoapp-dd/Build/Products/Debug-iphonesimulator/DemoApp.app
xcrun simctl launch "$UDID" dev.mobilecontroller.demoapp
```

To remove it again: `xcrun simctl uninstall "$UDID" dev.mobilecontroller.demoapp`.

## Accessibility identifiers

Every interactive element carries a stable identifier. These strings are a **public
contract** — bench flows and skill examples address the app exclusively through them, so
renaming one is a breaking change. They all live in `Sources/AccessibilityIDs.swift`.

| Element | Identifier |
|---|---|
| Home tab (tab-bar item) | `tabBar.home` |
| List tab (tab-bar item) | `tabBar.list` |
| Form tab (tab-bar item) | `tabBar.form` |
| Home screen root | `home.root` |
| Animate button (drives the 300 ms transition) | `home.animateButton` |
| The card that animates | `home.animatedCard` |
| Text mirror of the card state | `home.animationStateLabel` |
| Micro-animation toggle (default **OFF**) | `home.microAnimationToggle` |
| Pulsing dot driven by the toggle | `home.microAnimationDot` |
| List screen root | `list.root` |
| List rows, 1-based, `n` = 1…40 | `list.row.<n>` |
| Form screen root | `form.root` |
| Text field | `form.textField` |
| Clear button (disabled when the field is empty) | `form.clearButton` |
| Label echoing the field's contents | `form.echoLabel` |
| Character count of the field | `form.characterCountLabel` |

## What each screen is for

### Home — the animation ground truth

Two independent motion sources, separately controllable:

1. **`home.animateButton`** runs exactly one `withAnimation(.easeInOut(duration: 0.3))`
   transition per tap: the card expands 80 pt → 260 pt and changes colour, then settles into a
   fully static state. Both directions are identical in duration, so `--repeat N` measures the
   same thing every time. Motion must begin within a frame of the tap and be over 300 ms later
   — that is the number `simprobe motion` is checked against, and the deadline
   `simprobe wait-stable` must report settled within.
   `home.animationStateLabel` reads `collapsed` or `expanded` so the end state is verifiable
   without pixels.

2. **`home.microAnimationToggle`** (default **OFF**) starts a perpetual, subtle pulse on
   `home.microAnimationDot` that never settles. This reproduces the "idle screen with a
   micro-animation" case, where waiting for two identical frames never terminates. With the
   toggle OFF the dot is genuinely static — the screen is a true idle baseline.

### List — a dense but bounded accessibility tree

Exactly 40 rows, numbered **1 through 40** (`list.row.1` … `list.row.40`). Titles and
subtitles are derived arithmetically from the row number (`Row 07 Golf`, `Stable / value 49`)
— no dates, no random values, no locale-dependent formatting. Tapping a row marks it with a
checkmark; the selection is in-memory only and resets on relaunch.

### Form — the fill / read-back / field-clear path

`form.echoLabel` mirrors the field's exact current contents, so a tool can verify what it
actually typed without OCR. When the field is empty the label reads `(empty)` — never a blank
string, so there is always an unambiguous value to read back. `form.clearButton` empties the
field and disables itself.

This is the screen that catches the two known keyboard hazards: an AZERTY host layout mangling
typed characters, and a "clear" that silently leaves residue behind.

## Layout

```
DemoApp/
├── project.yml                     # XcodeGen spec — the .xcodeproj is generated
├── README.md
└── Sources/
    ├── AccessibilityIDs.swift      # every identifier, in one place
    ├── DemoAppApp.swift            # @main + the tab bar
    ├── HomeView.swift              # 300 ms transition + micro-animation toggle
    ├── DemoItem.swift              # deterministic row data
    ├── ItemListView.swift          # the 40-row list
    └── FormView.swift              # text field / clear / echo
```
