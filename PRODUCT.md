# Product

<!-- impeccable:product-schema 1 -->

## Platform

macos

Native AppKit + SwiftUI menu-bar app (macOS 14+). Impeccable has no macOS platform value; Apple's macOS conventions (HIG app icon grid, template menu-bar images, system colors) govern.

## Users

People on a Mac who route their traffic through a VPN or proxy and need the location the internet sees to stay where they set it. Whereabouts runs in the background; they look at it when something changes or goes wrong. Released publicly as open source, so the first contact for most people is a GitHub README.

## Product Purpose

Whereabouts answers one question continuously: where does the internet think this Mac is right now? It looks up the public IP's location on an interval, compares it with the user's rules, and says the answer as a place (country code, flag, or city) in the menu bar. When the answer is wrong it alerts (menu-bar color, notification, sound, a red line along the screen edge) and can cut the network with a kill switch. Success is never being somewhere you didn't mean to be without knowing it.

## Positioning

It doesn't ask whether the VPN is connected; it asks where you appear to be and acts on that answer. Rules are about places: allowed or blocked countries, per-site location rules matched against the active browser tab, expected ISPs. It also checks the quieter ways a location leaks: the IPv6 exit and the DNS resolvers.

## Operating Context

- Lives in the menu bar (`LSUIElement`), no Dock icon. The app icon is seen in Finder and /Applications, Spotlight, System Settings (Login Items, Automation, Notifications), the About/Settings windows, and on every notification banner, which is the moment something has gone wrong.
- The menu-bar item is a status glyph plus a place label. Glyph states today (SF Symbols): safe, violation, leak (orange), kill switch engaged, unknown, offline, checking. Template (monochrome) by default; colored when the "menu bar color" alert is on.
- Lookups use ip-api.com (HTTP free tier, the one provider that flags VPN/proxy exits) plus fallbacks.

## Capabilities and Constraints

- Country allow/block rules, per-site location rules (browser tab watch via Apple Events), ISP allowlist and change alerts, violation confirmation, IPv6 and DNS leak checks, kill switch with pause and re-arm, history.
- Built with SwiftPM and Command Line Tools only (no Xcode): no asset catalogs, no `actool`, no Icon Composer `.icon` compile. The app icon ships as `Resources/AppIcon.icns` built with `iconutil`; `build.sh` copies only the binary, Info.plist and the icns.
- Bundle id `com.doxigo.Whereabouts`; successor to the user's earlier Glaze app GeoMeister, with settings/history import.

## Brand Commitments

- Name: **Whereabouts**.
- Clean break from the GeoMeister icon (metal compass, lever, teal). It is reference only, not an asset to carry forward.
- An all-clear glyph must never show while a leak or violation is active; the kill switch state outranks every other state. Any custom status glyph keeps this ordering.

## Evidence on Hand

- No logo, wordmark, website, screenshots, or README exist yet.
- No users, testimonials, press, or download numbers. Do not invent any.

## Product Principles

1. The answer is a place. Show where, not a connection state.
2. Wrong must be unmissable; right stays quiet.
3. Truthful status beats reassuring status.
4. Native citizen of macOS: behaves and looks like it belongs in the menu bar.
