#!/bin/bash
# Builds Whereabouts.app with SwiftPM (Command Line Tools are enough, no Xcode).
#   ./build.sh            → build/Whereabouts.app
#   ./build.sh install    → also copies it to /Applications and launches it
set -euo pipefail
cd "$(dirname "$0")"

# A stable signing identity keeps macOS permission grants (Automation,
# notifications) across rebuilds; ad-hoc signatures change on every build.
SIGN_ID="${SIGN_ID:-CopperCast Dev}"
security find-identity -v -p codesigning | grep -qF "\"$SIGN_ID\"" || SIGN_ID="-"

# The macOS 27 SDK makes @State a macro whose plugin only ships with full Xcode;
# the 26.5 SDK in Command Line Tools still has the property wrapper.
SDK=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
[ -d "$SDK" ] && export SDKROOT="$SDK"

swift build -c release --arch arm64
APP=build/Whereabouts.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Whereabouts "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
codesign --force --sign "$SIGN_ID" "$APP"
echo "Built $APP (signed: $SIGN_ID)"

if [ "${1:-}" = "install" ]; then
  pkill -x Whereabouts 2>/dev/null && sleep 1 || true
  rm -rf /Applications/Whereabouts.app
  cp -R "$APP" /Applications/
  open /Applications/Whereabouts.app
  echo "Installed to /Applications"
fi
