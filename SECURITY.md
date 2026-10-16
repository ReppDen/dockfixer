# Security

DockFixer holds the Accessibility permission, which lets it move and resize
other apps' windows, and it updates itself. A hole in either is worth hearing
about privately first.

**Report a vulnerability** through
[GitHub's private reporting](https://github.com/ReppDen/dockfixer/security/advisories/new),
not in a public issue. You'll get an answer within a few days.

Only the latest release is supported: installed copies update to it on their
own.

## How releases are protected

- Every release is built by the [release workflow](.github/workflows/release.yml)
  from a tagged commit, and signed with the project's own certificate. The
  workflow refuses to publish a build signed with anything else, because macOS
  ties the Accessibility permission to that certificate.
- Updates are delivered by [Sparkle](https://sparkle-project.org). Each archive
  is signed with an EdDSA key, and the app installs it only if the signature
  verifies against the public key built into it.
- The app makes two kinds of network requests: Sparkle's update check against
  this repository's releases, and PostHog for the daily usage count and for bug
  reports someone chooses to send. See [Privacy](README.md#privacy).
