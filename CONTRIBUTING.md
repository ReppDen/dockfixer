# Contributing to DockFixer

Bug reports, fixes and pull requests are welcome. DockFixer has one maintainer,
who reviews and merges every pull request; for anything bigger than a small fix,
open an issue or a discussion first so we can agree on the approach.

## Building

Only the Command Line Tools are needed (`xcode-select --install`), not Xcode.

```sh
make dev        # build signed with a local certificate, debug logging, install to /Applications
make test       # unit tests; CI runs the same
make            # build build/DockFixer.app (ad-hoc signed)
make run        # build and launch from build/
make uninstall  # remove the installed app and its Accessibility permission
make help       # every target
```

Installing **does not restart a running copy**: quit DockFixer and open it
again to run the new build.

Always launch the bundle (`open /Applications/DockFixer.app`, Finder,
Spotlight), never `DockFixer.app/Contents/MacOS/DockFixer` from a shell: macOS
then asks for the terminal's Accessibility access instead of DockFixer's.

### Why `make dev` and not `make install`

An ad-hoc signature has no stable identity, so macOS ties the Accessibility
permission to the binary's code hash. Every rebuild gets a new hash and the
permission silently stops applying while the switch in System Settings stays
on. `make dev` signs with a self-signed certificate made by
`Scripts/dev-cert.sh` (kept in its own keychain, `dockfixer-dev.keychain`), so
the permission is granted once and survives rebuilds.

If the switch is on and DockFixer still says it has no access, remove the
DockFixer row with **−** in System Settings, or run
`tccutil reset Accessibility com.github.reppden.dockfixer`, then restart the
app: a process that was denied caches the answer.

A `make dev` build logs every window of every pass at `DEBUG` and never updates
itself.

## Project layout

| Path | Contents |
| --- | --- |
| `Sources/DockFixerCore/Geometry.swift` | Where a window should go: pushing it out from under the Dock. Pure, fully tested. |
| `Sources/DockFixerCore/Reclaim.swift` | Following the Dock when it shrinks, moves or leaves a display. Pure. |
| `Sources/DockFixerCore/ScreenMap.swift` | Screen coordinates, and telling a Dock change from a display change. Pure. |
| `Sources/DockFixerCore/AX.swift`, `WindowScanner.swift` | Accessibility API: listing windows, moving them, checking it stuck. |
| `Sources/DockFixerCore/DisplayWatcher.swift`, `WindowWatcher.swift` | What triggers a pass: Dock and display changes, new windows. |
| `Sources/DockFixerCore/Log.swift`, `Usage.swift` | The log file, and the daily usage event. |
| `Sources/DockFixerCore/BugReport.swift` | What an in-app bug report sends, and the last 24 hours of the log. |
| `Sources/DockFixer/` | SwiftUI window, menu-bar item, settings, Sparkle. |
| `Tests/DockFixerTests/` | Unit tests. |
| `Scripts/make-icon.swift`, `Scripts/make-hero.swift` | Draw the app icon and the README picture (`make readme-icon`, `make readme-hero`). |
| `Scripts/appcast.sh`, `Scripts/cask.sh` | The Sparkle feed and the Homebrew cask for a release, run by `.github/workflows/release.yml`. |
| `Scripts/verify-update.swift` | Checks a release archive against the update key inside the app, before it is published. |

## Things to know

- **Tests are a plain executable**, run with `make test`, not `swift test`:
  XCTest ships with Xcode, and the project builds with the Command Line Tools
  alone. `Tests/DockFixerTests/Harness.swift` is the whole framework.
- **All window geometry is in Accessibility coordinates**: origin at the top
  left of the primary display, y growing downwards. `NSScreen` uses the
  opposite; the conversion happens once, in `ScreenMap`.
- **Behaviour changes go into the pure files** (`Geometry.swift`,
  `Reclaim.swift`) with a test case. They need no display and no permission.
- **The Dock is never asked where it is.** Everything comes from each screen's
  `visibleFrame`.
- If an app misbehaves, the `MOVED`, `SKIP` and `FAIL` lines in
  `~/Library/Logs/DockFixer/dockfixer.log` carry the window's frame before and
  after and the error the app returned.

## Pull requests

- Run `make test` before opening one.
- Keep a pull request to one change, and say in the description why it is
  needed, not only what it does.
- Commit messages: `fix:`, `feat:`, `docs:` or `chore:` and a short lower-case
  subject.

## Releases

Releases are made by the maintainer, by pushing a tag:

```sh
git tag v0.2.0 && git push origin v0.2.0
```

The [release workflow](.github/workflows/release.yml) takes the version from
the tag, tests, builds a universal app signed with the release certificate,
checks that it launches and that its update signature verifies, publishes the
GitHub release with the zip and the Sparkle feed, and updates the Homebrew
cask. Installed copies pick the release up within a day. Only `vX.Y.Z` tags
start it, and every version must be higher than the last: Sparkle compares
them as numbers.
