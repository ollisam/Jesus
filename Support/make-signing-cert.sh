#!/bin/zsh
# Creates a self-signed "Jesus Local Signing" code-signing certificate in your
# login keychain. build.sh signs with it, so macOS remembers Jesus's permissions
# across rebuilds. Remove it any time from Keychain Access.
set -euo pipefail

IDENTITY="Jesus Local Signing"
if security find-certificate -c "$IDENTITY" >/dev/null 2>&1; then
  echo "\"$IDENTITY\" already exists."
  exit 0
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj "/CN=$IDENTITY" \
  -addext "keyUsage=critical,digitalSignature" -addext "extendedKeyUsage=critical,codeSigning" \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" 2>/dev/null
/usr/bin/openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -out "$TMP/id.p12" -passout pass:recast
security import "$TMP/id.p12" -k ~/Library/Keychains/login.keychain-db -P recast -T /usr/bin/codesign >/dev/null

echo "Created \"$IDENTITY\". Now run ./build.sh --install."
