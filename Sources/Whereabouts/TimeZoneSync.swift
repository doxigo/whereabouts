import Foundation

// Match the Mac's time zone to the connection: while a VPN is up the system zone
// follows the exit (so nothing on the Mac contradicts the IP), otherwise it goes
// home. Changing the zone needs root, so a one-time admin prompt installs a
// helper that accepts nothing but a valid zone name.

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
            // Go home silently first, so canceling the removal prompt still leaves the right zone.
            if let home = settings.homeTimeZone, home != systemTimeZone { try? await TimeZoneHelper.set(home) }
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

    /// Point the Mac at the zone the current connection calls for, if it isn't already.
    func syncTimeZone() async {
        guard settings.matchTimeZone, let home = settings.homeTimeZone, !timeZoneInFlight,
              geo.kind == .safe || geo.kind == .violation, let location = geo.location,
              !TimeZoneHelper.automaticIsOn else { return }
        // On a VPN, follow the exit. Off it, IP geolocation is only approximate,
        // so the real answer is home.
        let onVpn = geo.vpnName != nil || location.isVpn == true
        guard let target = onVpn ? location.timeZone : home, TimeZone(identifier: target) != nil else { return }
        refreshSystemTimeZone()
        guard target != systemTimeZone else { return }

        timeZoneInFlight = true
        defer { timeZoneInFlight = false }
        do {
            try await TimeZoneHelper.set(target)
            refreshSystemTimeZone()
            timeZoneError = nil
            notify("Time zone changed", target == home
                ? "Mac time zone set back to your home zone, \(target)."
                : "Mac time zone set to \(target) to match your connection.")
        } catch {
            timeZoneError = "Couldn't change the time zone — the helper may be missing. Turn the setting off and on again to reinstall it."
            log.error("Time zone change failed: \(error.localizedDescription)")
        }
    }
}
