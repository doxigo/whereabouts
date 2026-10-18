#!/bin/bash
# Regenerates the brand SVGs and Resources/AppIcon.icns from brand.py.
#   Branding/build.sh
# 16-64px icon slots use icon-small.svg (no lettering or guilloché); larger slots use icon.svg.
set -euo pipefail
cd "$(dirname "$0")"

SDK=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
[ -d "$SDK" ] && export SDKROOT="$SDK"

python3 brand.py
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
swiftc -O render.swift -o "$TMP/render"

SET="$TMP/AppIcon.iconset"
mkdir -p "$SET"
slot() { # slot <name> <px>
  local src=icon.svg
  [ "$2" -le 64 ] && src=icon-small.svg
  "$TMP/render" "$src" "$SET/icon_$1.png" "$2"
}
slot 16x16 16;     slot 16x16@2x 32
slot 32x32 32;     slot 32x32@2x 64
slot 128x128 128;  slot 128x128@2x 256
slot 256x256 256;  slot 256x256@2x 512
slot 512x512 512;  slot 512x512@2x 1024
iconutil -c icns "$SET" -o ../Resources/AppIcon.icns

"$TMP/render" icon.svg icon.png 1024
"$TMP/render" wordmark.svg wordmark.png 2400
"$TMP/render" banner.svg "$TMP/banner.png" 2800
# The README banner ships as WebP: a 2x PNG of the guilloché weave is ~2.5 MB, WebP ~330 KB.
if command -v cwebp >/dev/null; then
  cwebp -quiet -q 88 "$TMP/banner.png" -o banner.webp
else
  echo "cwebp not found (brew install webp): Branding/banner.webp not updated"
fi
echo "Wrote Resources/AppIcon.icns, Branding/icon.png, Branding/wordmark.png, Branding/banner.webp"
