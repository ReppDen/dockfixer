#!/bin/bash
#
# Writes the Sparkle feed for one release: an appcast.xml with a single item,
# the archive just built, signed with the EdDSA key.
#
#   Scripts/appcast.sh <version> <zip> <download-url> > appcast.xml
#
# One item is all the feed needs. It is attached to the release it describes,
# and the app reads it through GitHub's "latest release" redirect, so the
# newest release always carries the newest feed and an older feed is never
# looked at again. Everyone updates straight to the newest version from
# whatever they have.
#
# Environment:
#   SIGN_UPDATE          Sparkle's sign_update tool (default: on PATH)
#   SPARKLE_ED_KEY_FILE  the private key exported with `generate_keys -x`;
#                        without it, sign_update reads the key from the keychain
set -euo pipefail

VERSION="$1"
ZIP="$2"
URL="$3"
SIGN_UPDATE="${SIGN_UPDATE:-sign_update}"

ARGS=()
if [ -n "${SPARKLE_ED_KEY_FILE:-}" ]; then
    ARGS+=(--ed-key-file "$SPARKLE_ED_KEY_FILE")
fi

# Prints: sparkle:edSignature="…" length="…"
ATTRS="$("$SIGN_UPDATE" "${ARGS[@]+"${ARGS[@]}"}" "$ZIP")"
case "$ATTRS" in
    *edSignature=*length=*) ;;
    *) echo "sign_update gave no signature: $ATTRS" >&2; exit 1 ;;
esac

# Sparkle compares sparkle:version with the installed CFBundleVersion, which
# the Makefile sets to the same version string.
cat <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>DockFixer</title>
    <item>
      <title>DockFixer $VERSION</title>
      <pubDate>$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')</pubDate>
      <sparkle:version>$VERSION</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <enclosure url="$URL" type="application/octet-stream" $ATTRS/>
    </item>
  </channel>
</rss>
EOF
