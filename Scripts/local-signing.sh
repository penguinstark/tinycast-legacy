#!/bin/bash
# Create the local `Tinycast Self-Signed` identity once, in a keychain of its own so `codesign` can
# use it without a GUI prompt. Writes no secrets: the keychain password is the repo's own name.
set -euo pipefail

KC="${TINYCAST_SIGNING_KEYCHAIN:-$HOME/Library/Keychains/tinycast-signing.keychain-db}"
PASS="tinycast"

if security find-identity -p codesigning "$KC" 2>/dev/null | grep -q "Tinycast Self-Signed"; then
    echo "✓ Tinycast Self-Signed already in $KC"
    security unlock-keychain -p "$PASS" "$KC"
    exit 0
fi

command -v openssl >/dev/null || {
    echo "✗ openssl not found" >&2
    exit 2
}

KEY="$(mktemp)" CERT="$(mktemp)" P12="$(mktemp)"
trap 'rm -f "$KEY" "$CERT" "$P12"' EXIT

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$KEY" -out "$CERT" \
    -subj "/CN=Tinycast Self-Signed" \
    -addext "basicConstraints=critical,CA:false" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" 2>/dev/null

# Homebrew's OpenSSL 3+ writes ciphers `security import` rejects; LibreSSL needs no flag.
EXPORT=(-export)
if openssl version | grep -Eq '^OpenSSL [3-9]'; then EXPORT+=(-legacy); fi
openssl pkcs12 "${EXPORT[@]}" -inkey "$KEY" -in "$CERT" \
    -name "Tinycast Self-Signed" -out "$P12" -passout "pass:$PASS"

security create-keychain -p "$PASS" "$KC"
security set-keychain-settings -lut 21600 "$KC"
security unlock-keychain -p "$PASS" "$KC"
security import "$P12" -k "$KC" -P "$PASS" -A -T /usr/bin/codesign >/dev/null
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$PASS" "$KC" >/dev/null

# codesign finds the identity by name only when the keychain is in the user's search list.
security list-keychains -d user -s $(security list-keychains -d user | tr -d '"') "$KC"

security find-identity -p codesigning "$KC" | grep "Tinycast Self-Signed"
echo "✓ signed builds now keep their Accessibility grant across rebuilds"
