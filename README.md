<p align="center"><img src="docs/icon.png" width="128" height="128" alt="DockFixer icon"></p>

# DockFixer

**Pulls macOS windows out from under the Dock.**

[![CI](https://github.com/ReppDen/dockfixer/actions/workflows/ci.yml/badge.svg)](https://github.com/ReppDen/dockfixer/actions/workflows/ci.yml)
[![Latest release](https://img.shields.io/github/v/release/ReppDen/dockfixer?sort=semver)](https://github.com/ReppDen/dockfixer/releases/latest)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
![Platform](https://img.shields.io/badge/platform-macOS%2014%2B-lightgrey)

---

## The problem

Unplug an external display and macOS moves your windows onto the built-in screen
— often partly underneath the Dock, where their edges and controls are
unreachable. macOS has no setting that makes the Dock an obstacle windows cannot
cross, so the usual fix is dragging and resizing every window by hand, one at a
time, after every disconnect.

DockFixer does it in one press, or automatically whenever the display
configuration changes.

The same happens without any display change, too: an application that opens a
window against a screen edge — Notes' Quick Note does — or restores a
remembered frame puts it straight under the Dock. DockFixer watches for new
windows and pulls each one clear as it opens, leaving every other window alone.

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

### The other half: the strip the Dock leaves behind

Plug a display back in and the Dock jumps to it. The screen it left is now
wider, but the windows on it are not — they leave a dead strip of wallpaper
exactly the Dock's width.

```
 before                              after
┌──────────────────────────┐        ┌──────────────────────────┐
│▓▓┌──────────────────────┐│        │┌────────────────────────┐│
│▓▓│                      ││   ──▶  ││                        ││
│▓▓│  was maximised, now  ││        ││  stretched into the    ││
│▓▓│  a strip is wasted   ││        ││  reclaimed strip       ││
│▓▓└──────────────────────┘│        │└────────────────────────┘│
└──────────────────────────┘        └──────────────────────────┘
  ▓ = where the Dock used to be
```

On a display whose usable area grew, a window that was *touching the edge the
Dock has vacated* was being held there by the Dock, and follows it:

- **Touching both edges** — it was maximised. Stretched to the new extent, so
  the strip disappears and its far edge does not move.
- **Touching only the freed edge** — it was resting against the Dock. Slid
  across to rest against the new edge, keeping its size.
- **Touching neither** — it is where you put it, and it stays there.

Whether a window "filled" the screen is judged along the Dock's axis only — a
half-height window spanning the full width still counts.

Because the rule is about what a window is touching rather than about which
display change happened, it settles: once moved, the window touches the new edge
and is a whole Dock's width from the old one, so running the pass again does
nothing.

The same rule covers a Dock that grows, shrinks or moves to another edge of the
same display: windows it now covers are pushed out, and windows resting against
the edge it left follow that edge.

After a display change this has its own checkbox — **Fill the space the Dock
leaves behind** — kept separate because it moves windows that nothing is
currently overlapping, which is a bigger liberty than pulling a window out from
under the Dock. Switch it off and a display change only pushes windows out.

It also needs to know where the Dock *was*, which only the watcher records.
**Fix Windows Now** has no such record, so it only ever pushes windows out from
under the Dock.

Windows it cannot move are written to the log with the reason. No silent
failures.

Bounds come from each screen's *visible frame*, which already excludes the Dock
and the menu bar. The Dock's position is therefore never hardcoded: Docks on the
left, right and bottom all work, an auto-hidden Dock correctly becomes a no-op,
and moving or resizing the Dock triggers a pass of its own.

### Two switches, and one for the external display

| Switch | What it does |
| --- | --- |
| **Move windows that are under the Dock** | A window under the Dock is moved out of it: one that opens there, one shown again after ⌘H or on a Space you switch to, and every window a Dock that grew or a display you plugged in or out left underneath. Off, nothing watches and nothing moves. |
| **Stick windows to the Dock when it changes size or moves** | A window next to the Dock stays next to it as the Dock shrinks or moves to another edge, and a window within 16 points of the Dock (about 32 pixels) is put against it — a gap that small is a Dock's leftover, not where anyone parks a window. **Skip very small changes (about 8 pixels)** is part of this one: a Dock on the side of the screen breathes by a point or two as apps open and quit, and with this on such changes move nothing. |
| **When the Dock moves to another display, fill the empty space with windows** | The Dock leaves a display for another one; windows on the display it left stretch into the strip it used. |

Windows move the moment the Dock or a display changes: no waiting for the
layout to settle. A Dock that goes on changing afterwards is simply another
change, acted on in turn.

macOS reports a Dock change and a display change with the same notification.
DockFixer tells them apart by comparing the layout before and after: the same
displays at the same places with only a visible frame changed is the Dock.
Windows you move yourself are never touched by any of them.

## Requirements

- macOS 14 or later, Apple silicon or Intel
- Accessibility permission (see [First run](#first-run))
- To build: Command Line Tools only — `xcode-select --install`. A full Xcode
  install is **not** required.

## Install

### From a release

Download the latest `.zip` from
[Releases](https://github.com/ReppDen/dockfixer/releases/latest), then:

```sh
unzip DockFixer-*.zip -d /Applications
xattr -dr com.apple.quarantine /Applications/DockFixer.app
open /Applications/DockFixer.app
```

The `xattr` line is required. Release builds are ad-hoc signed, not notarised
with an Apple Developer ID, so without it macOS refuses to open the app and sends
you to System Settings → Privacy & Security → *Open Anyway*.

### From source

```sh
git clone https://github.com/ReppDen/dockfixer.git
cd dockfixer
make dev        # builds, signs with a local identity, installs to /Applications
open /Applications/DockFixer.app
```

Locally built apps are never quarantined, so the `xattr` step does not apply.

`make dev` is preferred over `make install` even if you are not developing: it
signs with a self-signed certificate so the Accessibility permission survives
rebuilds. See [Keeping the Accessibility grant](#keeping-the-accessibility-grant-across-rebuilds)
for why that matters.

## First run

Moving another application's window is only possible through the Accessibility
API, so macOS requires explicit permission. DockFixer asks on first launch, and until
the permission is granted its window shows what to do instead of its settings,
with an **Open System Settings** button. Turn on the switch next to DockFixer
under System Settings → Privacy & Security → Accessibility, and the window moves
on to the settings by itself.

> **Always launch the bundle**, with `open /Applications/DockFixer.app`, from
> Finder, or from Spotlight — never by running `DockFixer.app/Contents/MacOS/DockFixer`
> from a shell. macOS attributes Accessibility requests to the process
> *responsible* for the launch, so a binary started from a terminal asks for the
> **terminal's** access and leaves DockFixer's own permission no longer matching.
> That is also why DockFixer has no command-line interface.

## Usage

DockFixer has to be running when a display is unplugged, so switch on **Launch at
login** and forget about it — automatic correction is enabled by default.

With its window open it is a normal application: Dock icon, app-switcher entry,
menu bar. Closing the window does not quit — the watcher has to keep running —
so it steps out of the way instead: the Dock icon and the ⌘⇥ entry disappear and
only the menu-bar item is left. **Open DockFixer…** in that menu brings the window,
and the Dock icon, back, and so does ⌘, or opening the app again. Quitting is
explicit, from the **Quit** button, the menu bar or ⌘Q.

With **Hide menu bar icon** on and the window closed, DockFixer runs with no
visible trace. Open it again from Spotlight, Finder or Launchpad to get the
window back — or to quit it.

Started at login it goes straight to the menu bar without showing the window,
since there is nothing to say. It may flash past on the way — macOS gives no way
to ask why a process was started, so DockFixer shows the window and withdraws it a
moment later if nobody came for it. Opening it yourself always keeps it.

Everything is on one page. **Screens** lists every display with its size and
which edge the Dock is on — the quickest way to tell whether DockFixer is seeing
the same layout you are.

| Control | What it does |
| --- | --- |
| **Dock Settings…** | Opens System Settings → Desktop & Dock, where the Dock is moved and resized. |
| **Move windows**, **External display** | See [Two switches, and one for the external display](#two-switches-and-one-for-the-external-display). All on by default. The same switches are in the menu bar. |
| **Fix Windows Now** | Runs a pass immediately and says what it did underneath. Also in the menu bar. |
| **Launch at login** | Registers DockFixer as a login item. macOS may ask you to allow it under System Settings → General → Login Items. |
| **Hide menu bar icon** | Leaves the menu-bar item out. Off by default. |
| **Send anonymous usage statistics** | One line a day about how many windows were moved. On by default; see [What DockFixer sends](#what-dockfixer-sends) for the whole of it. |
| **GitHub · Report a Bug · Ask a Question** | The repository, a new issue with the version, macOS and Dock position filled in, and Discussions. |
| **Show Log** | Opens the log in a window of its own, with Copy, Clear and Reveal in Finder. |
| **Quit** | Fully quits. |

Opening DockFixer yourself always shows the window. When launchd starts it at login
and permission is already granted it comes up quietly instead, with just the two
icons — there is nothing to report and nothing to do.

An automatic pass does not fire the instant a display disappears. macOS sends the
change notification several times in a burst, and WindowServer goes on relocating
windows afterwards, so DockFixer waits for the layout to stop changing before
acting.

## What DockFixer sends

Once a day, if **Send anonymous usage statistics** is on, DockFixer sends one
event to [PostHog](https://posthog.com) (EU servers). This is all of it:

```json
{
  "event": "day",
  "distinct_id": "a random ID made on this Mac, nothing else is derived from it",
  "uuid": "made from that ID and the day, so a day is never counted twice",
  "timestamp": "2026-10-13T00:00:00Z",
  "properties": {
    "version": "0.1.0",
    "day": "2026-10-13",
    "pushedOut": 11,
    "stuck": 40,
    "acrossDisplays": 3,
    "$geoip_disable": true
  }
}
```

The three numbers are how many windows the three switches moved that day: out
from under the Dock, along with the Dock on the same display, and into the
space the Dock left on another display. Not sent: window titles, application
names, the macOS version, the Mac model, or where you are — the project is set
to discard the IP address, and `$geoip_disable` keeps it from looking the
address up. The counts are kept in a small file of their own
(`~/Library/Application Support/DockFixer/usage.jsonl`), summed per UTC day,
and a day is sent when it is over — on the next launch, wake, or hourly check,
whichever comes first. Each send is a line in the log (`usage sent — …`).

Turning the switch off deletes the file and the ID. A build without a project
key — a fork, a plain `swift build` — sends nothing at all; the key goes in
through `make app USAGE_KEY=…`. The whole thing is one file,
`Sources/DockFixerCore/Usage.swift`. The numbers it adds up to are public:
[the DockFixer dashboard](https://eu.posthog.com/shared/O63pcUH2gzDFECtm1r3HAublIhL13w).

## Logs

Shown live in the window, and written to:

```
~/Library/Logs/DockFixer/dockfixer.log
```

```
=== DockFixer 0.1.0 (arm64) session started 2026-10-13 20:18:40 — macOS 15.1 (24B83), MacBookPro18,3 ===
[20:18:52.575] INFO   displays changed: 2 -> 1, settled after 1 polls, 0.1s after the first notification
[20:18:52.575] INFO   now: Built-in Retina Display 1512x982 dock left 49pt
[20:18:53.357] MOVED  Google Chrome   "docs"  (0,33 1512x949) -> (49,33 1463x949) shiftX=49 shrinkW=49 clamped [+0ms, 11ms]
[20:18:53.357] MOVED  WhatsApp        "WhatsApp"  (48,33 1201x949) -> (49,33 1201x949) shiftX=1 [+0ms, 2ms]
[20:18:53.357] FAIL   IntelliJ IDEA   "proj"  want (49,33 1463x949) got (0,33 1512x949) after 3 tries — every write was accepted [+0ms, 40ms, written again]
[20:18:53.357] INFO   pass (display change) — 27 windows in 23 apps — 2 moved, 1 could not be moved, 22 already in place, 2 minimized
```

The session header names the build and the machine, every pass names what
started it, and a `MOVED` or `FAIL` line ends with when in the pass the write
went out, how long the application took to accept it, and whether it had to be
written again — so a report needs nothing but the log.

The log records what a pass *did*, not everything it saw. A minimised window, a
window already in the right place, the desktop layer — none of that is an event
and none of it is anything to act on, so it is counted in the closing line and
not printed window by window. What does get a line of its own is a window that
moved, a window that would not move, and a window that is in the way but cannot
be arranged at all — the last of those once per session, since it is a standing
property rather than something that happened.

| Level | Meaning |
| --- | --- |
| `DEBUG` | Every window a pass looked at, the display layout before and after a change, and why a pass decided as it did. Off in a release build. |
| `INFO` | Passes, Dock and display changes, settings, sleep and wake, permission changes, applications that cannot be watched for new windows, usage statistics sent. |
| `MOVED` | Window corrected, with before, after, by how much, and the timing. |
| `SKIP` | Window in the way that cannot be moved or resized at all, or an application that would not list its windows. Once per session. |
| `FAIL` | Correction was attempted and did not stick, with what was asked for, what happened, and the error the application returned, if any. |

`DEBUG` is the exception to the rule above, deliberately: when a pass did nothing
and the question is why, the counted-not-printed windows are exactly what has to
be read. A release build logs at `INFO`; `make dev` builds at `DEBUG`, and the
level is fixed in the bundle rather than in a preference, so which build is
talkative is never in doubt. A binary run straight from the terminal, which has
no bundle to read, takes `DOCKFIXER_LOG_LEVEL=debug` from the environment instead.

## Troubleshooting

**The switch in System Settings is on, but DockFixer says it has no access.**
A permission record left over from a previous build no longer matches the current
one. Toggling the switch off and on does **not** help — that re-authorises the
same stale record. Remove the DockFixer row with the **−** button and grant it
again, or run:

```sh
tccutil reset Accessibility com.github.reppden.dockfixer
```

**I granted access and nothing changed.** A process that has already been denied
caches the answer. Quit DockFixer and start it again.

**A window will not move.** Check the log. Fixed-size dialogs, some Java and Qt
windows, and the Finder desktop cannot be moved through the Accessibility API at
all; these are reported as `SKIP` or `FAIL` rather than being retried forever.

**Windows on my other desktop were ignored.** Expected — see below.

## Known limitations

- **Other Spaces.** The Accessibility API only reports windows on the current
  Space, so a pass does not see windows parked on another desktop. Working
  around this requires disabling System Integrity Protection, which DockFixer
  will not ask you to do. Instead, switching to a Space counts as its windows
  appearing: the ones under the Dock are moved then, if **When a window appears
  under the Dock** is on.
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
make            # build build/DockFixer.app
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
| `Sources/DockFixerCore/Geometry.swift` | The correction rule. Pure functions, no system calls — where the behaviour is decided and tested. |
| `Sources/DockFixerCore/ScreenMap.swift` | Converts `NSScreen` rects into the Accessibility API's coordinate space. |
| `Sources/DockFixerCore/AX.swift` | Wrappers over the C Accessibility API. |
| `Sources/DockFixerCore/WindowScanner.swift` | Enumerates windows, applies corrections, verifies they stuck. |
| `Sources/DockFixerCore/Reclaim.swift` | Following the Dock: the space it gave back and which windows it was holding. Pure. |
| `Sources/DockFixerCore/DisplayWatcher.swift` | Dock- and display-change detection and settling. |
| `Sources/DockFixerCore/WindowWatcher.swift` | Notices new windows, so one opened under the Dock is moved at once. |
| `Sources/DockFixerCore/Log.swift` | File log and the in-memory buffer the window renders. |
| `Sources/DockFixer/` | SwiftUI window, menu-bar item, app state. |
| `Tests/DockFixerTests/` | Unit tests. |
| `Scripts/make-icon.swift` | Draws the app icon — its source. `docs/icon.png` is a rendered copy for this README (`make readme-icon`). |
| `Scripts/dev-cert.sh` | Creates the local code-signing identity. |
| `Resources/github-mark.pdf` | The GitHub mark on the GitHub button, from Octicons. |

### Notes for contributors

- **Tests are a plain executable**, run with `make test`, not `swift test`. On
  macOS `swift test` packages tests as an XCTest bundle, and XCTest ships with
  Xcode — this project is meant to build and test with the Command Line Tools
  alone. `Tests/DockFixerTests/Harness.swift` is the whole framework.
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
designated => identifier "com.github.reppden.dockfixer" and certificate leaf = H"…"
```

That is stable across rebuilds, so the permission is granted once. The
certificate lives in its own keychain (`dockfixer-dev.keychain`) with a known
password so nothing prompts, and it is only used locally — releases stay ad-hoc
signed.

`tccutil reset` also only works once the app is signed this way. For an ad-hoc
build it fails with `No such bundle identifier`, because the record is keyed by
the code hash rather than the bundle identifier.

A denied process also caches the answer, so after granting access DockFixer has to
be restarted before it notices.

## Contributing

Issues and pull requests are welcome.

- Run `make test` before opening a pull request; CI runs the same thing.
- Keep behaviour changes in `Geometry.swift` covered by a case in the test table.
- If a specific application misbehaves, please include the relevant `SKIP` or
  `FAIL` lines from `~/Library/Logs/DockFixer/dockfixer.log` — they carry the window
  geometry and the reason.

## License

MIT — see [LICENSE](LICENSE). Third-party material and its licence:
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
