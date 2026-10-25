import Foundation

// Match the Mac's time zone to the connection: while a VPN is up the system zone
// follows the exit (so nothing on the Mac contradicts the IP), otherwise it goes
// home. Changing the zone needs root, so a one-time admin prompt installs a
// helper that accepts nothing but a valid zone name. The region follows along;
// it's a per-user preference, so it needs no helper.

enum TimeZoneHelper {
    static let helperPath = "\(Privileged.appDir)/timezone-helper.sh"
    static let sudoersPath = "/etc/sudoers.d/whereabouts-timezone"

    static let helperScript = #"""
    #!/bin/bash
    # Whereabouts time zone helper: sets the system time zone, nothing else.
    set -uo pipefail
    ZONE="${1:-}"
    if ! [[ "$ZONE" =~ ^[A-Za-z]+(/[A-Za-z0-9_+-]+){0,2}$ ]] || [ ! -f "/usr/share/zoneinfo/$ZONE" ]; then
      echo "whereabouts: invalid time zone" >&2
      exit 2
    fi
    /usr/sbin/systemsetup -settimezone "$ZONE" >/dev/null 2>&1
    # If systemsetup didn't take, set the link it manages and announce the change.
    case "$(/usr/bin/readlink /etc/localtime)" in
      */zoneinfo/"$ZONE") ;;
      *) /bin/ln -sfn "/var/db/timezone/zoneinfo/$ZONE" /etc/localtime 2>/dev/null && /usr/bin/notifyutil -p com.apple.system.timezone ;;
    esac
    case "$(/usr/bin/readlink /etc/localtime)" in
      */zoneinfo/"$ZONE") echo "$ZONE" ;;
      *) echo "whereabouts: could not set the time zone" >&2; exit 3 ;;
    esac
    """#

    static func setupScript(user: String) -> String {
        // The helper validates its one argument, so the grant can allow any.
        Privileged.installScript(helperPath: helperPath, helper: helperScript, sudoersPath: sudoersPath,
                                 grants: ["\(user) ALL=(root) NOPASSWD: \(Privileged.sudoersPath(helperPath)) *"])
    }

    static let teardownScript = """
    #!/bin/bash
    /bin/rm -f \(Privileged.q(sudoersPath)) \(Privileged.q(helperPath))
    /bin/rmdir \(Privileged.q(Privileged.appDir)) 2>/dev/null
    exit 0
    """

    static func set(_ zone: String) async throws {
        _ = try await run("/usr/bin/sudo", ["-n", helperPath, zone], timeout: 15)
    }

    /// Whether the helper takes `zone`, by its own test: a name of letters, then up to two parts of
    /// letters, digits, _, + or -, naming a file in the zone database. Foundation takes more (EST5EDT,
    /// GMT+0330), and the helper would refuse those on every check.
    static func accepts(_ zone: String) -> Bool {
        let letter = { (c: Character) in c.isASCII && c.isLetter }
        let parts = zone.split(separator: "/", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count), let first = parts.first, !first.isEmpty, first.allSatisfy(letter),
              parts.dropFirst().allSatisfy({ part in
                  !part.isEmpty && part.allSatisfy { letter($0) || ($0.isASCII && $0.isNumber) || "_+-".contains($0) }
              }) else { return false }
        var folder: ObjCBool = false
        return FileManager.default.fileExists(atPath: "/usr/share/zoneinfo/\(zone)", isDirectory: &folder) && !folder.boolValue
    }

    /// "Set time zone automatically using your current location": while it's on,
    /// macOS keeps switching the zone back. Asked of CoreTime, which System Settings
    /// uses — the old /Library/Preferences/com.apple.timezone.auto flag no longer
    /// tracks the switch, and the real store (/var/db/timed) is root-only.
    static var automaticIsOn: Bool { coreTimeAutomaticZone?() ?? false }

    // ponytail: private CoreTime symbol looked up at runtime. If Apple removes it this
    // reads "off" rather than wrongly locking the feature; the cost is a zone tug-of-war.
    private static let coreTimeAutomaticZone: (@convention(c) () -> Bool)? = {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/CoreTime.framework/CoreTime", RTLD_LAZY),
              let symbol = dlsym(handle, "TMIsAutomaticTimeZoneEnabled") else { return nil }
        return unsafeBitCast(symbol, to: (@convention(c) () -> Bool).self)
    }()
}

/// The Mac's region (System Settings › General › Language & Region). Only the
/// region changes; the language and any format overrides stay as they are.
enum RegionPref {
    private static var locale: String {
        CFPreferencesCopyAppValue("AppleLocale" as CFString, kCFPreferencesAnyApplication) as? String ?? Locale.current.identifier
    }

    static var current: String? { Locale(identifier: locale).region?.identifier }

    static func set(_ code: String) -> Bool {
        let (any, user, host) = (kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        CFPreferencesSetValue("AppleLocale" as CFString, regionLocale(locale, code) as CFString, any, user, host)
        guard CFPreferencesSynchronize(any, user, host) else { return false }
        // Running apps re-read the locale on this; without it they keep the old region until relaunched.
        DistributedNotificationCenter.default().postNotificationName(.init("AppleLanguagePreferencesChangedNotification"),
                                                                     object: nil, userInfo: nil, deliverImmediately: true)
        return true
    }
}

/// `identifier` with its region set to `code`: the rg override, dropped when the language already says it.
func regionLocale(_ identifier: String, _ code: String) -> String {
    var c = Locale.Components(identifier: identifier)
    c.region = c.languageComponents.region?.identifier == code ? nil : Locale.Region(code)
    return Locale(components: c).identifier
}

extension Monitor {
    func refreshSystemTimeZone() {
        NSTimeZone.resetSystemTimeZone()
        let zone = TimeZone.current.identifier
        if zone != systemTimeZone { systemTimeZone = zone }
    }

    /// Toggled from Settings. Turning it on asks for the admin password once.
    func setMatchTimeZone(_ on: Bool) async {
        guard on != settings.matchTimeZone else { return }
        refreshSystemTimeZone()
        guard on else {
            update { $0.matchTimeZone = false }
            AlibiHost.publishSystem(nil) // Alibi takes the zone back
            // Go home silently first, so canceling the removal prompt still leaves the right zone.
            if let home = settings.homeTimeZone, home != systemTimeZone { try? await TimeZoneHelper.set(home) }
            if let home = settings.homeRegion, home != RegionPref.current { _ = RegionPref.set(home) }
            refreshSystemTimeZone()
            timeZoneError = nil
            do {
                try await Privileged.run(TimeZoneHelper.teardownScript, prompt: "Whereabouts needs your admin password to remove its time zone helper.")
            } catch {
                if !Privileged.isUserCanceled(error) { log.error("Time zone helper removal failed: \(error.localizedDescription)") }
            }
            return
        }
        guard let user = Privileged.sudoUser() else {
            timeZoneError = "Your account name can't be used in a sudo rule, so the time zone can't be managed."
            return
        }
        do {
            try await Privileged.run(TimeZoneHelper.setupScript(user: user),
                                     prompt: "Whereabouts needs your admin password once so it can change your Mac's time zone to match your connection. It won't ask again.")
        } catch {
            if !Privileged.isUserCanceled(error) { log.error("Time zone helper setup failed: \(error.localizedDescription)") }
            timeZoneError = "Setup was canceled or failed — matching the time zone needs a one-time admin password."
            return
        }
        timeZoneError = nil
        // The zone in use right now is "home" unless one was already picked.
        let home = settings.homeTimeZone ?? systemTimeZone
        update { $0.matchTimeZone = true; $0.homeTimeZone = home }
    }

    /// Point the Mac at the zone and region the current connection, or Alibi's cover, calls for, if it isn't already.
    func syncTimeZone() async {
        guard settings.matchTimeZone else { AlibiHost.publishSystem(nil); return }
        let location = geo.kind == .safe || geo.kind == .violation ? geo.location : nil
        // On a VPN, follow the exit. Off it, IP geolocation is only approximate,
        // so the real answer is home.
        let onVpn = geo.vpnName != nil || location?.isVpn == true
        let wish = alibiPlace
        syncRegion(wish: wish, location: location, onVpn: onVpn)
        guard let home = settings.homeTimeZone, !TimeZoneHelper.automaticIsOn else { AlibiHost.publishSystem(nil); return }
        // No answer yet (offline, or between checks) and no place from Alibi: the Mac stays where it is,
        // and Alibi keeps what it was told, rather than hearing "none" now and the zone again in a minute.
        guard let target = timeZoneTarget(wish: wish, exitZone: location?.timeZone, onVpn: onVpn, connectionKnown: location != nil, home: home)
        else { return }
        // Alibi's zones were already checked the helper's way (AlibiWish.zone). An exit zone the helper
        // can't set still fails loudly, with the error and the warning, as it always has.
        guard TimeZone(identifier: target) != nil else { AlibiHost.publishSystem(nil); return }
        guard !timeZoneInFlight else { return }
        refreshSystemTimeZone()
        guard target != systemTimeZone else { AlibiHost.publishSystem(target); return }

        timeZoneInFlight = true
        defer { timeZoneInFlight = false }
        do {
            try await TimeZoneHelper.set(target)
            refreshSystemTimeZone()
            timeZoneError = nil
            AlibiHost.publishSystem(systemTimeZone == target ? target : nil)
            notify("Time zone changed", target == home
                ? "Mac time zone set back to your home zone, \(target)."
                : target == wish?.zone ? "Mac time zone set to \(target), Alibi's location."
                : "Mac time zone set to \(target) to match your connection.")
        } catch {
            AlibiHost.publishSystem(nil)
            timeZoneError = "Couldn't change the time zone — the helper may be missing. Turn the setting off and on again to reinstall it."
            log.error("Time zone change failed: \(error.localizedDescription)")
        }
        // Alibi's place may have moved while the helper ran, when a sync returns early: catch up once
        // this one is done (the task runs after `defer` clears the flag), rather than at the next check.
        if alibiPlace != wish { Task { await syncTimeZone() } }
    }

    private func syncRegion(wish: AlibiWish?, location: Location?, onVpn: Bool) {
        guard let current = RegionPref.current else { return }
        // The region in use the first time this runs is home, as with the zone.
        let home = settings.homeRegion ?? current
        if settings.homeRegion == nil { update { $0.homeRegion = home } }
        guard let target = regionTarget(wish: wish, exitCountry: location?.countryCode, onVpn: onVpn,
                                        connectionKnown: location != nil, home: home),
              target != current else { return }
        let name = Countries.name(target) ?? target
        guard RegionPref.set(target) else { log.error("Region change failed"); return }
        notify("Region changed", target == home ? "Mac region set back to your home region, \(name)."
            : target == wish?.country ? "Mac region set to \(name), Alibi's location."
            : "Mac region set to \(name) to match your connection.")
    }
}

/// Alibi's place, for the Mac to follow: only while matching is on and asked to follow Alibi too.
func followedPlace(_ wish: AlibiWish?, _ s: AppSettings) -> AlibiWish? {
    s.matchTimeZone && s.followAlibi ? wish : nil
}

/// Where the Mac's clock should be. A place Alibi has you in for all sites comes first; otherwise,
/// Alibi off or not, the VPN's exit while one is up, and home without one. nil: no answer yet.
func timeZoneTarget(wish: AlibiWish?, exitZone: String?, onVpn: Bool, connectionKnown: Bool, home: String) -> String? {
    if let zone = wish?.zone { return zone }
    guard connectionKnown else { return nil }
    return onVpn ? exitZone : home
}

/// The region to go with it: the country of Alibi's place (home if its locale names none), otherwise
/// the exit's while a VPN is up, and home without one. nil: no answer yet.
func regionTarget(wish: AlibiWish?, exitCountry: String?, onVpn: Bool, connectionKnown: Bool, home: String) -> String? {
    if wish?.zone != nil { return wish?.country ?? home }
    guard connectionKnown else { return nil }
    return onVpn ? exitCountry : home
}
