# DockFix

Pulls macOS windows out from under the Dock.

Unplug an external display and macOS moves your windows onto the built-in
screen — often partly underneath the Dock, where their edges and controls are
unreachable. macOS has no setting that makes the Dock an obstacle windows
cannot cross, so the usual fix is resizing every window by hand.

DockFix does it in one press, or automatically whenever the display
configuration changes.

## What it does

For every window that overlaps the Dock or the menu bar:

- it slides the window into the usable area — by the actual overlap, so a window
  only half-way under the Dock moves less than the Dock's full width;
- if sliding would push the far edge off-screen, it also narrows the window by
  exactly the distance it moved, so the far edge stays where it was;
- if a window is larger than the usable area to begin with, it is sized down to
  fit.

Windows it cannot move are written to the log with the reason — no silent
failures.

Bounds come from each screen's visible frame, which already excludes the Dock
and the menu bar. So the Dock's position is never hardcoded: left, right and
bottom Docks all work, an auto-hidden Dock correctly becomes a no-op, and moving
the Dock triggers a pass of its own.

## Install

Download the latest `.zip` from
[Releases](../../releases), then:

```sh
unzip DockFix-*.zip -d /Applications
xattr -dr com.apple.quarantine /Applications/DockFix.app
open /Applications/DockFix.app
```

The `xattr` line is needed because the app is ad-hoc signed rather than notarised
with an Apple Developer ID. Without it macOS refuses to open the app and sends
you to System Settings → Privacy & Security → *Open Anyway*. Building from
source avoids the issue entirely — locally built apps are never quarantined.

### Build from source

Requires only the Command Line Tools (`xcode-select --install`); a full Xcode
install is not needed.

```sh
git clone https://github.com/drepp/DockFix.git
cd DockFix
make run
```

## Grant Accessibility access

Moving another application's window is only possible through the Accessibility
API, so macOS requires explicit permission. On first launch DockFix asks; if you
miss the prompt, press **Grant…** in the window, or add DockFix yourself under
System Settings → Privacy & Security → Accessibility.

## Using it

DockFix has a Dock icon, an app-switcher entry and a menu-bar item. It has to be
running when a display is unplugged, so switch on **Launch at login** and forget
about it — the automatic pass is enabled by default.

Closing the window does not quit: DockFix stays in the menu bar, and clicking its
Dock icon brings the window back. Quitting is explicit, from the button or ⌘Q.

| Control | What it does |
| --- | --- |
| **Fix Windows Now** | Moves every window that overlaps the Dock or the menu bar. |
| **Fix automatically when displays change** | Runs a pass whenever a display is connected or disconnected, or the Dock moves. On by default. |
| **Launch at login** | Registers DockFix as a login item. macOS may ask you to allow it under System Settings → General → Login Items. |
| **Check Windows** (window) | Lists what a move would touch, with current and proposed geometry. Changes nothing. |
| **Move Windows** (window) | Applies those corrections. |
| **Quit** | Fully quits. Closing the window leaves DockFix running in the menu bar. |

Opening DockFix yourself always shows the window. When launchd starts it at login
and access is already granted it comes up quietly instead, with just the two
icons — there is nothing to report and nothing to do.

Always start DockFix by launching the bundle — `open /Applications/DockFix.app`,
or from Finder or Spotlight — and never by running
`DockFix.app/Contents/MacOS/DockFix` from a shell. macOS attributes Accessibility
requests to the process responsible for the launch, so a binary started from a
terminal asks for the *terminal's* access and leaves DockFix's own grant no longer
matching. That is also why DockFix has no command-line interface.

The automatic pass does not fire the instant a display disappears. macOS sends
the change notification several times in a burst and WindowServer goes on
relocating windows afterwards, so DockFix waits for the layout to stop changing
before acting.

## Log

Live in the window, and on disk at:

```
~/Library/Logs/DockFix/dockfix.log
```

```
[14:22:07.113] INFO   displays changed: 2 -> 1, settled after 2 polls
[14:22:07.240] MOVED  Warp               "main"  (12,180 1400x900) -> (67,180 1345x900) shiftX=55 shrinkW=55
[14:22:07.251] SKIP   Finder             "Downloads"  would move to (67,180 800x600) but position is not settable
[14:22:07.262] SKIP   Music              fullscreen
[14:22:07.310] FAIL   IntelliJ IDEA      "proj"  want (67,180 1345x900) got (12,180 1400x900) after 3 tries
```

## Known limitations

- **Other Spaces.** The Accessibility API only reports windows on the current
  Space, so windows parked on another desktop are neither listed nor moved.
  Working around this requires disabling System Integrity Protection, which
  DockFix will not ask you to do. Switch to the Space and press **Move Windows**.
- **Accessibility must be re-granted after an update.** Because the app is
  ad-hoc signed, its code hash changes with every build, and macOS ties the grant
  to that hash rather than to a Developer ID. Expect to re-approve DockFix after
  upgrading. `make reset-tcc` clears a stale grant during development.
- **Stubborn applications.** Some windows refuse to move or resize through the
  Accessibility API — fixed-size dialogs, and a few Java and Qt apps. They are
  reported as `SKIP` or `FAIL`.
- **Minimum window sizes.** Narrowing can fail when an application enforces a
  minimum width. Logged as `FAIL` with what was requested and what was applied.
- **Full-screen and minimised windows** are left alone on purpose.

## Development

```sh
make            # build build/DockFix.app
make run        # build and launch
make test       # unit tests
make install    # copy to /Applications
make reset-tcc  # clear the Accessibility grant
make zip        # release artefact
make help       # list targets
```

### Keeping the Accessibility grant across rebuilds

Use `make dev` rather than `make install` while working on DockFix:

```sh
make dev     # creates a local signing identity if needed, then builds and installs
```

An ad-hoc signature has no stable identity, so macOS keys the Accessibility grant
to the binary's code hash. Every rebuild produces a new hash and the grant stops
applying — while the switch in System Settings stays on, which makes it look like
a bug in the app. The only way out is deleting the row by hand.

`make dev` signs with a self-signed certificate created by
`Scripts/dev-cert.sh`, which gives a designated requirement based on the
certificate instead:

```
designated => identifier "com.github.drepp.dockfix" and certificate leaf = H"…"
```

That is stable across rebuilds, so the grant is given once. The certificate lives
in its own keychain (`dockfix-dev.keychain`) with a known password so nothing
prompts, and it is only used locally — releases stay ad-hoc signed.

If the grant is already in the stuck state — the switch is on but DockFix still
reports no access — the record left over from an ad-hoc build has to go. Turning
the switch off and on again does **not** clear it: that re-authorises the same
stale record. Either remove the row with the **−** button, or, once the app is
signed with a certificate, run:

```sh
tccutil reset Accessibility com.github.drepp.dockfix
```

`tccutil` only works after the switch to certificate signing. For an ad-hoc build
it fails with `No such bundle identifier`, because the record is keyed by the code
hash rather than the bundle identifier.

One more quirk: a process that has been denied caches the answer, so after
granting access DockFix has to be restarted before it notices — the two-second
poll only catches a grant made while access was never requested.

Layout:

| Path | Contents |
| --- | --- |
| `Sources/DockFixCore/Geometry.swift` | The correction rule. Pure functions, no system calls — this is where the behaviour is decided and tested. |
| `Sources/DockFixCore/ScreenMap.swift` | Converts `NSScreen` rects into the Accessibility API's coordinate space. |
| `Sources/DockFixCore/AX.swift` | Wrappers over the C Accessibility API. |
| `Sources/DockFixCore/WindowScanner.swift` | Enumerates windows, applies corrections, verifies they stuck. |
| `Sources/DockFixCore/DisplayWatcher.swift` | Display-change detection and settling. |
| `Sources/DockFix/` | SwiftUI window and app state. |
| `Tests/DockFixTests/` | Unit tests. |

Two notes for contributors:

- The tests are a plain executable with a small hand-rolled harness, run by
  `make test`, not by `swift test`. On macOS `swift test` packages tests as an
  XCTest bundle, and XCTest ships with Xcode — the project is meant to build and
  test with the Command Line Tools alone.
- All window geometry inside DockFix is in Accessibility coordinates: origin at
  the top-left of the primary display, y growing downwards. `NSScreen` uses the
  opposite vertical convention, and the conversion happens once, in
  `ScreenMap`. Mixing the two is the fastest way to send windows off the bottom
  of the screen.

## License

MIT — see [LICENSE](LICENSE).
