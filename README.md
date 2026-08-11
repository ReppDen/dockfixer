# DockFix

**Pulls macOS windows out from under the Dock.**

[![CI](https://github.com/ReppDen/dockfix/actions/workflows/ci.yml/badge.svg)](https://github.com/ReppDen/dockfix/actions/workflows/ci.yml)
[![Latest release](https://img.shields.io/github/v/release/ReppDen/dockfix?sort=semver)](https://github.com/ReppDen/dockfix/releases/latest)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
![Platform](https://img.shields.io/badge/platform-macOS%2014%2B-lightgrey)

---

## The problem

Unplug an external display and macOS moves your windows onto the built-in screen
— often partly underneath the Dock, where their edges and controls are
unreachable. macOS has no setting that makes the Dock an obstacle windows cannot
cross, so the usual fix is dragging and resizing every window by hand, one at a
time, after every disconnect.

DockFix does it in one press, or automatically whenever the display
configuration changes.

## What it does

```
 before                              after
┌──────────────────────────┐        ┌──────────────────────────┐
│▓▓┌──────────────────────┐│        │▓▓ ┌────────────────────┐ │
│▓▓│                      ││   ──▶  │▓▓ │                    │ │
│▓▓│   window under the   ││        │▓▓ │  moved clear of it │ │
│▓▓│   Dock, edge cut off ││        │▓▓ │  and narrowed      │ │
│▓▓└──────────────────────┘│        │▓▓ └────────────────────┘ │
└──────────────────────────┘        └──────────────────────────┘
  ▓ = Dock
```

For every window that overlaps the Dock or the menu bar:

- **Slides it into the usable area** — by the actual overlap, so a window only
  half-way under the Dock moves less than the Dock's full width.
- **Narrows it if sliding is not enough** — when moving alone would push the far
  edge off-screen, the window is shortened by exactly the distance it moved, so
  its far edge stays where it was.
- **Sizes it down if it never fitted** — a window larger than the usable area is
  fitted to it.

Windows it cannot move are written to the log with the reason. No silent
failures.

Bounds come from each screen's *visible frame*, which already excludes the Dock
and the menu bar. The Dock's position is therefore never hardcoded: Docks on the
left, right and bottom all work, an auto-hidden Dock correctly becomes a no-op,
and moving or resizing the Dock triggers a pass of its own.

## Requirements

- macOS 14 or later, Apple silicon or Intel
- Accessibility permission (see [First run](#first-run))
- To build: Command Line Tools only — `xcode-select --install`. A full Xcode
  install is **not** required.

## Install

### From a release

Download the latest `.zip` from
[Releases](https://github.com/ReppDen/dockfix/releases/latest), then:

```sh
unzip DockFix-*.zip -d /Applications
xattr -dr com.apple.quarantine /Applications/DockFix.app
open /Applications/DockFix.app
```

The `xattr` line is required. Release builds are ad-hoc signed, not notarised
with an Apple Developer ID, so without it macOS refuses to open the app and sends
you to System Settings → Privacy & Security → *Open Anyway*.

### From source

```sh
git clone https://github.com/ReppDen/dockfix.git
cd dockfix
make dev        # builds, signs with a local identity, installs to /Applications
open /Applications/DockFix.app
```

Locally built apps are never quarantined, so the `xattr` step does not apply.

`make dev` is preferred over `make install` even if you are not developing: it
signs with a self-signed certificate so the Accessibility permission survives
rebuilds. See [Keeping the Accessibility grant](#keeping-the-accessibility-grant-across-rebuilds)
for why that matters.

## First run

Moving another application's window is only possible through the Accessibility
API, so macOS requires explicit permission. DockFix asks on first launch. If you
miss the prompt, press **Grant…** in the window, or add DockFix yourself under
System Settings → Privacy & Security → Accessibility.

> **Always launch the bundle**, with `open /Applications/DockFix.app`, from
> Finder, or from Spotlight — never by running `DockFix.app/Contents/MacOS/DockFix`
> from a shell. macOS attributes Accessibility requests to the process
> *responsible* for the launch, so a binary started from a terminal asks for the
> **terminal's** access and leaves DockFix's own permission no longer matching.
> That is also why DockFix has no command-line interface.

## Usage

DockFix has a Dock icon, an app-switcher entry and a menu-bar item. It has to be
running when a display is unplugged, so switch on **Launch at login** and forget
about it — automatic correction is enabled by default.

Closing the window does not quit: DockFix stays in the menu bar, and clicking its
Dock icon brings the window back. Quitting is explicit, from the button or ⌘Q.

| Control | What it does |
| --- | --- |
| **Fix Windows Now** *(menu bar)* | Moves every window that overlaps the Dock or the menu bar. |
| **Fix automatically when displays change** | Runs a pass whenever a display is connected or disconnected, or the Dock moves. On by default. |
| **Launch at login** | Registers DockFix as a login item. macOS may ask you to allow it under System Settings → General → Login Items. |
| **Check Windows** *(window)* | Lists what a move would touch, with current and proposed geometry. Changes nothing. |
| **Move Windows** *(window)* | Applies those corrections. |
| **Quit** | Fully quits. |

Opening DockFix yourself always shows the window. When launchd starts it at login
and permission is already granted it comes up quietly instead, with just the two
icons — there is nothing to report and nothing to do.

An automatic pass does not fire the instant a display disappears. macOS sends the
change notification several times in a burst, and WindowServer goes on relocating
windows afterwards, so DockFix waits for the layout to stop changing before
acting.

## Logs

Shown live in the window, and written to:

```
~/Library/Logs/DockFix/dockfix.log
```

```
[20:18:52.575] INFO   displays changed: 2 -> 1, settled after 1 polls
[20:18:52.575] INFO   move triggered by displays changed: 2 -> 1, settled after 1 polls
[20:18:53.357] MOVED  Google Chrome   "docs"  (0,33 1512x949) -> (49,33 1463x949) shiftX=49 shrinkW=49 clamped
[20:18:53.357] MOVED  WhatsApp        "WhatsApp"  (48,33 1201x949) -> (49,33 1201x949) shiftX=1
[20:18:53.357] SKIP   Finder          read-only window covering the whole display — desktop or system layer
[20:18:53.357] FAIL   IntelliJ IDEA   "proj"  want (49,33 1463x949) got (0,33 1512x949) after 3 tries
[20:18:53.357] INFO   move done — 27 windows in 23 apps, 9 need fixing, 9 moved, 1 skipped
```

| Level | Meaning |
| --- | --- |
| `INFO` | Passes, display changes, permission changes. |
| `MOVED` | Window corrected, with before, after, and by how much. |
| `SKIP` | Window deliberately left alone, with the reason. |
| `FAIL` | Correction was attempted and did not stick, with what was asked for and what happened. |

## Troubleshooting

**The switch in System Settings is on, but DockFix says it has no access.**
A permission record left over from a previous build no longer matches the current
one. Toggling the switch off and on does **not** help — that re-authorises the
same stale record. Remove the DockFix row with the **−** button and grant it
again, or run:

```sh
tccutil reset Accessibility com.github.reppden.dockfix
```

**I granted access and nothing changed.** A process that has already been denied
caches the answer. Quit DockFix and start it again.

**A window will not move.** Check the log. Fixed-size dialogs, some Java and Qt
windows, and the Finder desktop cannot be moved through the Accessibility API at
all; these are reported as `SKIP` or `FAIL` rather than being retried forever.

**Windows on my other desktop were ignored.** Expected — see below.

## Known limitations

- **Other Spaces.** The Accessibility API only reports windows on the current
  Space, so windows parked on another desktop are neither listed nor moved.
  Working around this requires disabling System Integrity Protection, which
  DockFix will not ask you to do. Switch to that Space and press **Fix Windows
  Now**.
- **Not notarised.** Release builds are ad-hoc signed, so the first launch needs
  the `xattr` command above, and the Accessibility permission has to be granted
  again after an update. Building from source with `make dev` avoids both.
- **Stubborn applications.** Some windows refuse to move or resize through the
  Accessibility API. They are reported, never silently dropped.
- **Minimum window sizes.** Narrowing can fail when an application enforces a
  minimum width. Logged as `FAIL` with what was requested and what was applied.
- **Full-screen and minimised windows** are left alone on purpose.

## Development

```sh
make            # build build/DockFix.app
make dev        # build signed with a local identity and install to /Applications
make dev-cert   # create that local signing identity on its own
make run        # build and launch from build/
make test       # unit tests
make icon       # regenerate AppIcon.icns
make install    # copy to /Applications (ad-hoc signed)
make uninstall  # remove the installed bundle and its Accessibility permission
make reset-tcc  # clear the Accessibility permission
make zip        # release artefact
make clean
make help       # list targets
```

### Project layout

| Path | Contents |
| --- | --- |
| `Sources/DockFixCore/Geometry.swift` | The correction rule. Pure functions, no system calls — where the behaviour is decided and tested. |
| `Sources/DockFixCore/ScreenMap.swift` | Converts `NSScreen` rects into the Accessibility API's coordinate space. |
| `Sources/DockFixCore/AX.swift` | Wrappers over the C Accessibility API. |
| `Sources/DockFixCore/WindowScanner.swift` | Enumerates windows, applies corrections, verifies they stuck. |
| `Sources/DockFixCore/DisplayWatcher.swift` | Display-change detection and settling. |
| `Sources/DockFixCore/Log.swift` | File log and the in-memory buffer the window renders. |
| `Sources/DockFix/` | SwiftUI window, menu-bar item, app state. |
| `Tests/DockFixTests/` | Unit tests. |
| `Scripts/make-icon.swift` | Draws the app icon, so no binary artwork is committed. |
| `Scripts/dev-cert.sh` | Creates the local code-signing identity. |

### Notes for contributors

- **Tests are a plain executable**, run with `make test`, not `swift test`. On
  macOS `swift test` packages tests as an XCTest bundle, and XCTest ships with
  Xcode — this project is meant to build and test with the Command Line Tools
  alone. `Tests/DockFixTests/Harness.swift` is the whole framework.
- **All window geometry is in Accessibility coordinates**: origin at the top-left
  of the primary display, y growing *downwards*. `NSScreen` uses the opposite
  vertical convention. The conversion happens once, in `ScreenMap`. Mixing the two
  is the fastest way to send windows off the bottom of the screen.
- **The correction rule lives in `Geometry.swift` and is pure.** Behaviour changes
  belong there, with a case added to the table in `GeometryTests.swift` — no
  displays or permissions needed to run it.

### Keeping the Accessibility grant across rebuilds

Use `make dev` rather than `make install`.

An ad-hoc signature has no stable identity, so macOS keys the Accessibility
permission to the binary's code hash. Every rebuild produces a new hash and the
permission stops applying — while the switch in System Settings stays on, which
reads as a bug in the app rather than a stale record.

`make dev` signs with a self-signed certificate created by `Scripts/dev-cert.sh`,
giving a designated requirement based on the certificate instead:

```
designated => identifier "com.github.reppden.dockfix" and certificate leaf = H"…"
```

That is stable across rebuilds, so the permission is granted once. The
certificate lives in its own keychain (`dockfix-dev.keychain`) with a known
password so nothing prompts, and it is only used locally — releases stay ad-hoc
signed.

`tccutil reset` also only works once the app is signed this way. For an ad-hoc
build it fails with `No such bundle identifier`, because the record is keyed by
the code hash rather than the bundle identifier.

A denied process also caches the answer, so after granting access DockFix has to
be restarted before it notices.

## Contributing

Issues and pull requests are welcome.

- Run `make test` before opening a pull request; CI runs the same thing.
- Keep behaviour changes in `Geometry.swift` covered by a case in the test table.
- If a specific application misbehaves, please include the relevant `SKIP` or
  `FAIL` lines from `~/Library/Logs/DockFix/dockfix.log` — they carry the window
  geometry and the reason.

## License

MIT — see [LICENSE](LICENSE).
