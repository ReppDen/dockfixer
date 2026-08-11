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

The claim that a rebuild preserves the grant is therefore **still unverified**.
The reasoning behind it holds — the designated requirement is certificate-based
and demonstrably identical across rebuilds — but it has not been observed
end-to-end.

## Current state

- `/Applications/DockFix.app` — cert-signed, stable designated requirement.
- All DockFix processes killed, including the stray terminal-launched instance.
- Grant is currently broken by cause 3 and needs to be reset and given once more.
- Working tree has an unbuildable change (the CLI scan flags).

## Next steps

1. Remove the `--check` / `--fix` / `--login-item` command-line entry points and
   `WindowScanner.runSynchronously`. They are what caused cause 3, and the
   actor-isolation error came from the same code.
2. `make test && make dev` — and read the **full** output, not `tail -2`.
3. `tccutil reset Accessibility com.github.drepp.dockfix`.
4. `open /Applications/DockFix.app`, grant access once when prompted.
5. Rebuild once more, relaunch with `open`, and confirm from the log that the
   grant survived — closing out the unverified claim above.
6. Tick **Launch at login** in the window; it was unregistered before the bundle
   was deleted and has not been re-enabled.

## Rules of thumb

- Launch with `open`, never the binary.
- Local builds: `make dev`, never `make install`.
- Grant stuck with the switch on? `tccutil reset Accessibility
  com.github.drepp.dockfix`, then restart the app. Toggling the switch
  re-authorises the same stale record and cannot fix it.
- After granting, restart the app if it was already denied once.
