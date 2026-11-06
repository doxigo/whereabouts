import AppKit
import SystemConfiguration

// Consistency warnings: a site can compare what the Mac reports (time zone,
// region) with where the connection appears to be, so a mismatch gives a VPN
// away. These only point it out; nothing here changes the system.

enum ConsistencyKind: String, CaseIterable { case timeZone, automaticZone, region, computerName }

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
    /// The names every network sees, and the words of the account's own name.
    var computerName = ComputerName.Names()
    var ownerWords: [String] = []
}

/// `alibiPlace`: the place Alibi has the Mac's clock on, while Match time zone follows it.
func consistencyWarnings(location: Location?, onVpn: Bool, mac: MacFacts, settings s: AppSettings, matchFailing: Bool,
                         alibiPlace: AlibiWish? = nil) -> [ConsistencyWarning] {
    var warnings: [ConsistencyWarning] = []
    // A working Match time zone corrects the zone within the same check, so only a stuck one counts.
    let matchHandles = s.matchTimeZone && !matchFailing && !mac.automaticZone
    // Unless it's matching Alibi's place, and that's somewhere the connection isn't: the Mac does
    // what was asked, and a site can still compare the two. A place whose locale names no country
    // (a custom zone, say) goes by its zone against the exit's.
    if s.warnTimeZone, matchHandles, let place = alibiPlace, let zone = place.zone, let loc = location {
        let elsewhere: Bool
        if let country = place.country, let code = loc.countryCode { elsewhere = country.uppercased() != code.uppercased() }
        else if let exit = loc.timeZone { elsewhere = exit != zone }
        else { elsewhere = false }
        if elsewhere {
            let named = place.country.map { " in \(Countries.name($0) ?? $0)" } ?? ""
            warnings.append(ConsistencyWarning(kind: .timeZone, title: "Alibi's location differs from your connection",
                                               detail: "Your Mac is on \(zoneName(mac.timeZone)) for Alibi's location\(named), your connection is in \(loc.place).\nChoose Match my IP address in Alibi, a place in your connection's country, or turn off Follow Alibi's location in Settings › Time Zone."))
        }
    }
    // ponytail: identifiers compared as-is, so an alias pair (Europe/Kiev vs Europe/Kyiv) reads as a mismatch.
    if s.warnTimeZone, onVpn, !matchHandles, let loc = location, let exit = loc.timeZone, exit != mac.timeZone {
        let fix = mac.automaticZone ? "Turn off automatic time zone, then use Match time zone in Settings › Time Zone."
            : s.matchTimeZone ? "Match time zone couldn't change it. See Settings › Time Zone."
            : "Turn on Match time zone in Settings › Time Zone."
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
                                           detail: "Region is \(Countries.name(region) ?? region), your connection is in \(location?.place ?? code). Alibi covers your browser's language; apps can still read the region.\nTurn on Match time zone and region in Settings › Time Zone."))
    }
    // Not about the connection: the router and the devices on any network see it, VPN or not.
    let names = [mac.computerName.name, mac.computerName.host].compactMap { $0 }
    if s.warnComputerName, names.contains(where: { ComputerName.mentions($0, mac.ownerWords) }) {
        warnings.append(ConsistencyWarning(kind: .computerName, title: "Computer name includes your name",
                                           detail: "Networks you join, and the devices on them, see this Mac as “\(names[0])”.\nRename it in Settings › Protection."))
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
    var settingsTab: String? {
        switch self {
        case .automaticZone: nil
        case .computerName: "Protection"
        default: "Time Zone"
        }
    }
    var systemPane: URL? {
        self == .automaticZone ? URL(string: "x-apple.systempreferences:com.apple.Date-Time-Settings.extension") : nil
    }
}

extension Monitor {
    var consistency: [ConsistencyWarning] {
        let loc = geo.location
        let mac = MacFacts(timeZone: systemTimeZone, automaticZone: TimeZoneHelper.automaticIsOn,
                           region: Locale.autoupdatingCurrent.region?.identifier,
                           computerName: computerName, ownerWords: ComputerName.ownerWords)
        return consistencyWarnings(location: loc, onVpn: followsConnectionZone(location: loc, vpnName: geo.vpnName), mac: mac,
                                   settings: settings, matchFailing: timeZoneError != nil, alibiPlace: alibiPlace)
    }

    /// Notifies once when a warning appears; the menu lists it for as long as it lasts.
    func announceWarnings() {
        // The computer name doesn't come and go, so a notification would only repeat at every launch.
        for w in newWarnings(consistency, announced: &warningAlertKinds, connectionKnown: geo.location != nil) where w.kind != .computerName {
            log.info("Consistency warning: \(w.title)")
            notify(w.title, w.detail)
        }
    }
}

// MARK: - Computer name

/// The Mac's name: "Alice's MacBook Pro" in AirDrop and file sharing, and its Bonjour form
/// (Alices-MacBook-Pro.local) on the local network and in the DHCP request to the router.
enum ComputerName {
    struct Names: Equatable {
        var name: String?
        var host: String?
    }

    static func current() -> Names {
        Names(name: SCDynamicStoreCopyComputerName(nil, nil) as String?, host: SCDynamicStoreCopyLocalHostName(nil) as String?)
    }

    /// The words of the account's full and short name that a computer name would give away.
    static var ownerWords: [String] { words(NSFullUserName()) + words(NSUserName()) }

    private static func words(_ text: String) -> [String] {
        text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init).filter { $0.count >= 3 }
    }

    /// Whether `name` has one of `owner`'s words in it, possessive or not: "Alice's MacBook", "Alices-MacBook".
    // ponytail: whole words only, so a name inside another word ("Mac" in "MacBook") never counts.
    static func mentions(_ name: String, _ owner: [String]) -> Bool {
        words(name).contains { word in owner.contains { word == $0 || word == $0 + "s" } }
    }

    /// `name` without the owner's words: "Alice's MacBook Pro" → "MacBook Pro".
    static func suggestion(_ name: String?, _ owner: [String]) -> String {
        let kept = (name ?? "").split(whereSeparator: { $0 == " " || $0 == "-" }).filter { !mentions(String($0), owner) }
        return kept.isEmpty ? "Mac" : kept.joined(separator: " ")
    }

    /// The Bonjour name macOS would make of `name`: letters, digits and single hyphens.
    static func hostName(_ name: String) -> String {
        let parts = name.split(whereSeparator: { !($0.isASCII && ($0.isLetter || $0.isNumber)) })
        return parts.isEmpty ? "Mac" : String(parts.joined(separator: "-").prefix(63))
    }

    static func renameScript(_ name: String) -> String {
        """
        #!/bin/bash
        /usr/sbin/scutil --set ComputerName \(Privileged.q(name)) && /usr/sbin/scutil --set LocalHostName \(Privileged.q(hostName(name)))
        """
    }
}

extension Monitor {
    func refreshComputerName() {
        guard !Demo.enabled else { return }
        let names = ComputerName.current()
        if names != computerName { computerName = names }
    }

    /// Asks for the admin password once; both names change, as they do in System Settings › Sharing.
    func renameComputer(_ name: String) async {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !Demo.enabled else { return }
        do {
            try await Privileged.run(ComputerName.renameScript(name), prompt: "Whereabouts needs your admin password to rename this Mac.")
            renameError = nil
        } catch {
            if !Privileged.isUserCanceled(error) {
                log.error("Rename failed: \(error.localizedDescription)")
                renameError = "Couldn't rename this Mac. Try System Settings › General › Sharing."
            }
        }
        refreshComputerName()
    }
}
