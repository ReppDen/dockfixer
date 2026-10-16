#!/bin/bash
#
# Creates a self-signed code-signing certificate for local builds.
#
# Why this exists: an ad-hoc signature has no stable identity, so macOS keys the
# Accessibility grant to the binary's code hash. Every rebuild produces a new
# hash, the grant silently stops applying, and the switch in System Settings
# stays on while the app is no longer trusted — with no way to fix it other than
# removing the row by hand. Signing with a certificate gives the app a stable
# designated requirement, and the grant survives rebuilds.
#
# The certificate lives in its own keychain with a known password so this runs
# without prompting. It is only used for local builds; releases are signed in
# CI with the project's release certificate, kept in the repository's secrets.
set -euo pipefail

CN="${DEV_CERT_NAME:-DockFixer Dev}"
KEYCHAIN="dockfixer-dev.keychain"
KEYCHAIN_PASS="dockfixer"
P12_PASS="dockfixer"

# The system LibreSSL, deliberately not whatever openssl is first on PATH:
# OpenSSL 3 writes PKCS#12 files with algorithms the macOS Security framework
# rejects with "MAC verification failed".
OPENSSL=/usr/bin/openssl

# Note the missing -v: a self-signed certificate is reported as
# CSSMERR_TP_NOT_TRUSTED and never appears in the "valid identities only" list,
# even though codesign is perfectly happy to sign with it. Checking the validated
# list would re-import the certificate on every run and leave duplicates behind,
# which makes `codesign -s` ambiguous.
if security find-identity -p codesigning | grep -qF "\"$CN\""; then
    # Already present. Make sure the keychain is unlocked so codesign can use it.
    security unlock-keychain -p "$KEYCHAIN_PASS" "$KEYCHAIN" 2>/dev/null || true
    echo "code-signing identity '$CN' already available"
    exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# A config file rather than -addext: works with both LibreSSL and OpenSSL.
cat > "$TMP/openssl.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions    = v3
prompt             = no

[dn]
CN = $CN

[v3]
basicConstraints   = critical,CA:FALSE
keyUsage           = critical,digitalSignature
extendedKeyUsage   = critical,codeSigning
EOF

"$OPENSSL" req -x509 -newkey rsa:2048 -sha256 -nodes -days 3650 \
    -config "$TMP/openssl.cnf" \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" 2>/dev/null

"$OPENSSL" pkcs12 -export \
    -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -out "$TMP/identity.p12" -passout "pass:$P12_PASS"

if ! security list-keychains -d user | grep -q "$KEYCHAIN"; then
    if [ ! -f "$HOME/Library/Keychains/$KEYCHAIN-db" ]; then
        security create-keychain -p "$KEYCHAIN_PASS" "$KEYCHAIN"
    fi
    # No auto-lock, so later builds do not start prompting.
    security set-keychain-settings "$KEYCHAIN"
    # Append to the search list, keeping what is already there.
    EXISTING="$(security list-keychains -d user | sed -e 's/^[[:space:]]*//' -e 's/"//g')"
    # shellcheck disable=SC2086
    security list-keychains -d user -s $EXISTING "$KEYCHAIN"
fi

security unlock-keychain -p "$KEYCHAIN_PASS" "$KEYCHAIN"
# Non-extractable, and usable by codesign only: not -A, which would let any
# process read the key without asking. Whoever holds this key can sign code
# that macOS takes for the dev build, Accessibility grant included.
security import "$TMP/identity.p12" -k "$KEYCHAIN" -P "$P12_PASS" -x -T /usr/bin/codesign
# Lets codesign use the key without an interactive prompt.
security set-key-partition-list -S apple-tool:,apple:,codesign: \
    -s -k "$KEYCHAIN_PASS" "$KEYCHAIN" >/dev/null

echo "created code-signing identity '$CN' in $KEYCHAIN"
security find-identity -p codesigning | grep -F "\"$CN\"" || true
