import AppKit

// Consistency warnings: a site can compare what the Mac reports (time zone,
// region) with where the connection appears to be, so a mismatch gives a VPN
// away. These only point it out; nothing here changes the system.

enum ConsistencyKind: String, CaseIterable { case timeZone, automaticZone, region }

struct ConsistencyWarning: Equatable {
    var kind: ConsistencyKind
    var title: String
    var detail: String
}

/// What the Mac says about itself, next to the connection.
struct MacFacts {
    var timeZone: String
    /// "Set time zone automatically using your current location".
    var automaticZone: Bool
    var region: String?
}

/// `alibiCountry`: the country of the place Alibi has the Mac's clock on, while Match time zone follows it.
func consistencyWarnings(location: Location?, onVpn: Bool, mac: MacFacts, settings s: AppSettings, matchFailing: Bool,
                         alibiCountry: String? = nil) -> [ConsistencyWarning] {
    var warnings: [ConsistencyWarning] = []
    // A working Match time zone corrects the zone within the same check, so only a stuck one counts.
    let matchHandles = s.matchTimeZone && !matchFailing && !mac.automaticZone
    // Unless it's matching Alibi's place, and that's somewhere the connection isn't: the Mac does
    // what was asked, and a site can still compare the two.
    if s.warnTimeZone, matchHandles, let place = alibiCountry, let loc = location, let code = loc.countryCode,
       place.uppercased() != code.uppercased() {
        warnings.append(ConsistencyWarning(kind: .timeZone, title: "Alibi's location differs from your connection",
                                           detail: "Your Mac is on \(zoneName(mac.timeZone)) for Alibi's location in \(Countries.name(place) ?? place), your connection is in \(loc.place).\nChoose Match my IP address in Alibi, or a place in your connection's country."))
    }
    // ponytail: identifiers compared as-is, so an alias pair (Europe/Kiev vs Europe/Kyiv) reads as a mismatch.
    if s.warnTimeZone, onVpn, !matchHandles, let loc = location, let exit = loc.timeZone, exit != mac.timeZone {
        let fix = mac.automaticZone ? "Turn off automatic time zone, then use Match time zone in Settings › Location."
            : s.matchTimeZone ? "Match time zone couldn't change it. See Settings › Location."
            : "Turn on Match time zone in Settings › Location."
        warnings.append(ConsistencyWarning(kind: .timeZone, title: "Time zone doesn't match your connection",
                                           detail: "Your Mac is on \(zoneName(mac.timeZone)), your connection is in \(zoneName(exit)).\n\(fix)"))
    }
    // Harmless without a VPN; with one, macOS keeps putting the real zone back.
    if s.warnAutomaticZone, mac.automaticZone, onVpn || s.matchTimeZone {
        warnings.append(ConsistencyWarning(kind: .automaticZone, title: "Automatic time zone is on",
                                           detail: "macOS sets the zone from your real location, undoing any match, and Match time zone stays unavailable.\nTurn it off in System Settings › General › Date & Time."))
    }
    // Matching sets the region in the same check, and needs nothing that can get stuck.
    if s.warnRegion, onVpn, !s.matchTimeZone, let code = location?.countryCode, let region = mac.region, region.uppercased() != code.uppercased() {
        warnings.append(ConsistencyWarning(kind: .region, title: "Mac region differs from your connection",
                                           detail: "Region is \(Countries.name(region) ?? region), your connection is in \(location?.place ?? code). Alibi covers your browser's language; apps can still read the region.\nTurn on Match time zone and region in Settings › Location."))
    }
    return warnings
}

func zoneName(_ zone: String) -> String { zone.replacingOccurrences(of: "_", with: " ") }

/// The warnings worth a notification: ones that weren't showing last time.
/// A failed lookup says nothing about the connection, so it forgets nothing —
/// otherwise every blip would re-notify.
func newWarnings(_ current: [ConsistencyWarning], announced: inout Set<ConsistencyKind>, connectionKnown: Bool) -> [ConsistencyWarning] {
    if connectionKnown { announced.formIntersection(current.map(\.kind)) }
    return current.filter { announced.insert($0.kind).inserted }
}

extension ConsistencyKind {
    var symbol: String { self == .region ? "info.circle" : "exclamationmark.triangle" }
    /// Where the fix lives: a Whereabouts Settings tab or a System Settings pane.
    var settingsTab: String? { self == .automaticZone ? nil : "Location" }
    var systemPane: URL? {
        self == .automaticZone ? URL(string: "x-apple.systempreferences:com.apple.Date-Time-Settings.extension") : nil
    }
}

extension Monitor {
    var consistency: [ConsistencyWarning] {
        let loc = geo.location
        let mac = MacFacts(timeZone: systemTimeZone, automaticZone: TimeZoneHelper.automaticIsOn,
                           region: Locale.autoupdatingCurrent.region?.identifier)
        return consistencyWarnings(location: loc, onVpn: geo.vpnName != nil || loc?.isVpn == true, mac: mac,
                                   settings: settings, matchFailing: timeZoneError != nil, alibiCountry: alibiPlace?.country)
    }

    /// Notifies once when a warning appears; the menu lists it for as long as it lasts.
    func announceWarnings() {
        for w in newWarnings(consistency, announced: &warningAlertKinds, connectionKnown: geo.location != nil) {
            log.info("Consistency warning: \(w.title)")
            notify(w.title, w.detail)
        }
    }
}
