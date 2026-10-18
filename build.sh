#!/bin/zsh
# Builds Jesus.app into ./build. Pass --install to copy it to /Applications.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP=build/Jesus.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$(swift build -c release --show-bin-path)/Recast" "$APP/Contents/MacOS/Jesus"
cp Support/Info.plist "$APP/Contents/Info.plist"

if [[ ! -f Support/AppIcon.icns ]]; then
  ICONSET=build/AppIcon.iconset
  mkdir -p "$ICONSET"
  swift Support/make-icon.swift build/icon.png
  for s in 16 32 128 256 512; do
    sips -z $s $s build/icon.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s * 2)) $((s * 2)) build/icon.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o Support/AppIcon.icns
  rm -rf "$ICONSET" build/icon.png
fi
cp Support/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp click.wav "$APP/Contents/Resources/click.wav"

# macOS ties privacy permissions (folders, Full Disk Access, Automation) to the
# signature. An ad hoc signature changes every build, so permissions are forgotten;
# a certificate from Support/make-signing-cert.sh keeps them across rebuilds.
IDENTITY="Jesus Local Signing"
if security find-certificate -c "$IDENTITY" >/dev/null 2>&1; then
  codesign --force --sign "$IDENTITY" "$APP" >/dev/null
else
  codesign --force --sign - "$APP" >/dev/null
  echo "Note: signed ad hoc, so macOS will ask for permissions again after each build."
  echo "      Run Support/make-signing-cert.sh once to keep them."
fi
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
  rm -rf /Applications/Jesus.app
  cp -R "$APP" /Applications/
  echo "Installed to /Applications/Jesus.app"
fi
