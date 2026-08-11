# Accessibility permission — what happened and what is left

Working notes on the Accessibility (TCC) grant for DockFix. Kept because the same
symptom appeared five times with three different causes, and the fixes are not
obvious from the symptom.

## The symptom, every time

The switch next to DockFix.app in System Settings → Privacy & Security →
Accessibility is **on**, and the app still logs:

```
FAIL  DockFix   cannot scan windows without Accessibility access
```

Turning the switch off and on again does not help.

## Cause 1 — ad-hoc signature, grant keyed to the code hash

**Confirmed.** Fixed.

An ad-hoc signature (`codesign --sign -`) has no stable identity, so TCC stores
the grant against the binary's code hash:

```
designated => cdhash H"…"
```

Every rebuild produces a new hash. The stored record keeps pointing at the old
one, so the running app is not trusted — while the switch stays on, because the
row is still there and macOS renders its icon from the bundle path, which does
exist.

`tccutil reset Accessibility com.github.drepp.dockfix` **fails** in this state:

```
tccutil: No such bundle identifier "com.github.drepp.dockfix"
```

because the record is not keyed by the bundle identifier at all. The only way out
is removing the row with the **−** button.

### Fix

`Scripts/dev-cert.sh` creates a self-signed code-signing certificate, and
`make dev` signs with it. The designated requirement becomes:

```
designated => identifier "com.github.drepp.dockfix" and certificate leaf = H"e798a478…"
```

That is stable across rebuilds. Verified with `codesign -d -r-` before and after
a rebuild, and `codesign --verify` reports *satisfies its Designated Requirement*.
`tccutil reset` works once signed this way.

Two details the script has to get right, both found the hard way:

- The PKCS#12 bundle must be written by the system LibreSSL (`/usr/bin/openssl`).
  Homebrew's OpenSSL 3 uses algorithms the Security framework rejects with
  `MAC verification failed during PKCS12 import`.
- The "certificate already present" check must use `security find-identity -p
  codesigning` **without** `-v`. A self-signed certificate is reported as
  `CSSMERR_TP_NOT_TRUSTED` and never appears in the validated list, so checking
  the validated list re-imports it on every run. Duplicate identities make
  `codesign -s "DockFix Dev"` ambiguous.

`codesign` itself does not care that the certificate is untrusted — signing
succeeds regardless. The certificate does **not** need to be added to the trust
store.

## Cause 2 — a denied process caches the answer

**Confirmed.** Not a bug, just behaviour to know.

`AXIsProcessTrusted()` keeps returning false in a process that has already been
denied, even after the switch is turned on. The app has to be restarted. The
two-second poll in `AppState` only catches a grant made before access was ever
requested.

## Cause 3 — launching the binary directly from a terminal

**Confirmed. This is what broke the working grant at 20:21, and it was my
mistake.**

Running

```sh
/Applications/DockFix.app/Contents/MacOS/DockFix --check
```

does not behave like launching the app. TCC attributes the request to the
**responsible process**, which for a binary started from a shell is the terminal
emulator. The prompt that appeared said:

> "**Warp.app**" would like to control this computer using accessibility features.

So the request was recorded against Warp, not DockFix, and DockFix's own record
was left in a state where it no longer matched.

It got worse because the build had failed (see below), so the installed binary did
not understand `--check`. Instead of running a scan and exiting, it launched a
**second full instance of the app**, which sat there requesting Accessibility as
Warp until it was killed.

### Fix

Never start the binary directly. Always:

```sh
open /Applications/DockFix.app
```

The `--check` / `--fix` / `--login-item` command-line entry points are the hazard
and are being removed. Anything that has to be verified goes through the buttons
in the window or the menu-bar item.

## A wrong conclusion I drew along the way

At 20:20 I claimed the grant had survived a rebuild, because the log showed no
"not granted" line after `make dev`. That was wrong: `make dev` had **failed** with

```
error: call to main actor-isolated instance method 'runSynchronously(dryRun:)'
       in a synchronous nonisolated context
```

so nothing was reinstalled and the previously granted bundle was still in place.
`ActorIsolatedCall` is an error in this toolchain, not a warning, and the failure
was hidden because the output was piped through `tail -2`.

The claim that a rebuild preserves the grant was therefore unverified at the time.

**It has since been verified.** At 20:33, after a clean `make test && make dev`
that actually reinstalled the bundle, the app relaunched with no "not granted"
line and completed a full pass over 27 windows in 23 applications — which is
impossible without the grant. Certificate-based signing does what it was meant
to do.

## Current state — resolved

- `/Applications/DockFix.app` — cert-signed, stable designated requirement.
- Grant given once and surviving rebuilds.
- Launch at login enabled.
- Command-line entry points removed, so cause 3 cannot recur.
- Builds clean, 2188 checks passing.

## Rules of thumb

- Launch with `open`, never the binary.
- Local builds: `make dev`, never `make install`.
- Grant stuck with the switch on? `tccutil reset Accessibility
  com.github.drepp.dockfix`, then restart the app. Toggling the switch
  re-authorises the same stale record and cannot fix it.
- After granting, restart the app if it was already denied once.
