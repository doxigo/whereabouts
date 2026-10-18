#!/bin/bash
# Regenerates the README screenshots in Branding/screenshots/ from the demo mode,
# so no real IP, place or provider ever lands in them.
#   ./build.sh && Branding/screenshots.sh
# The demo runs beside a real copy without touching it (see Demo.swift). screencapture
# needs Screen Recording permission for your terminal. macOS won't hand focus to an app
# a script launched, so windows render inactive while the terminal stays in front.
set -euo pipefail
cd "$(dirname "$0")"

SDK=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
[ -d "$SDK" ] && export SDKROOT="$SDK"
APP=../build/Whereabouts.app
[ -d "$APP" ] || { echo "Build first: ./build.sh" >&2; exit 1; }

TMP=$(mktemp -d)
trap 'pkill -f "Whereabouts --demo" || true; rm -rf "$TMP"' EXIT
cat > "$TMP/windows.swift" <<'EOF'
import CoreGraphics
// windows <pid> <title>: the CGWindowID of that process's on-screen window with that title.
let pid = Int32(CommandLine.arguments[1])!, title = CommandLine.arguments[2]
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as! [[String: Any]]
if let w = list.first(where: { ($0[kCGWindowOwnerPID as String] as? Int32) == pid && ($0[kCGWindowName as String] as? String) == title }) {
    print(w[kCGWindowNumber as String]!)
}
EOF
swiftc -O "$TMP/windows.swift" -o "$TMP/windows"
swiftc -O -parse-as-library menubar.swift ../Sources/Whereabouts/StampGlyph.swift -o "$TMP/menubar"

mkdir -p screenshots
shot() { # shot <file> <window title> <demo args...>
  local file=$1 title=$2; shift 2
  open -n "$APP" --args --demo "$@"
  sleep 4
  local pid id
  pid=$(pgrep -f "Whereabouts --demo" | head -1)
  id=$("$TMP/windows" "$pid" "$title")
  screencapture -l "$id" -x "screenshots/$file"
  kill "$pid"
  sleep 1
}
shot status.png Whereabouts safe -theme light
shot blocked-dark.png Whereabouts blocked -theme dark
shot settings-location.png Location safe -theme light --settings Location
"$TMP/menubar" screenshots/menubar.png light
"$TMP/menubar" screenshots/menubar-dark.png dark
echo "Wrote Branding/screenshots/"
