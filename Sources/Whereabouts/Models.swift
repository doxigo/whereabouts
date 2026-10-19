import Foundation

// The settings/history JSON keeps GeoMeister's exact shape, so its files import as-is.

enum RuleMode: String, Codable, CaseIterable { case blocklist, allowlist }
enum IspMode: String, Codable { case off, allowlist }

enum MenuBarDisplay: String, Codable, CaseIterable {
    case code, name, city, flag, full
    var label: String { rawValue.capitalized }
}

/// The menu-bar clock always shows home time; `away` shows it only while the Mac is on another zone.
enum MenuBarClock: String, Codable, CaseIterable {
    case away, time, day, date
    var label: String { self == .away ? "Only when away" : rawValue.capitalized }
}

struct AlertPrefs: Codable, Equatable {
    var menuBarColor = true
    var notifications = true
    var sound = false
    var edgeLine = false
}

// The lenient decoders live in extensions so Swift still synthesizes the plain initializers.
extension AlertPrefs {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        menuBarColor = c.get(.menuBarColor, menuBarColor)
        notifications = c.get(.notifications, notifications)
        sound = c.get(.sound, sound)
        edgeLine = c.get(.edgeLine, edgeLine)
    }
}

/// One acceptable location for a site rule: a country, optionally narrowed to a city.
struct SiteLocation: Codable, Hashable {
    var countryCode: String
    var country: String
    var city: String?

    var key: String { "\(countryCode)|\((city ?? "").lowercased())" }
    var label: String { city.map { "\($0), \(country)" } ?? country }
}

/// When the active browser tab is on `domain`, the IP must resolve to ANY of `locations`.
struct SiteRule: Codable, Equatable, Identifiable {
    var domain: String
    var locations: [SiteLocation]
    var edgeLine = false
    var killSwitch = false
    var id: String { domain }

    var requirement: String {
        let parts = locations.map(\.label)
        guard parts.count > 1 else { return parts.first ?? "an allowed location" }
        return parts.dropLast().joined(separator: ", ") + " or " + parts.last!
    }
}

extension SiteRule {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        domain = c.get(.domain, "")
        locations = c.get(.locations, [])
        edgeLine = c.get(.edgeLine, false)
        killSwitch = c.get(.killSwitch, false)
    }
}

struct AppSettings: Codable, Equatable {
    var ruleMode = RuleMode.blocklist
    var countries: [String] = []
    var intervalMs = 60_000
    var domains: [String] = []
    var siteRules: [SiteRule] = []
    var browserWatch = false
    var alerts = AlertPrefs()
    var menuBarDisplay = MenuBarDisplay.code
    var menuBarClock = MenuBarClock.date
    var launchAtLogin = false
    var killSwitch = false
    var ispMode = IspMode.off
    var expectedIsps: [String] = []
    var alertOnIspChange = false
    var confirmViolations = true
    var ipv6Check = true
    var dnsCheck = true
    /// Set the Mac's time zone to the connection's while a VPN is up.
    var matchTimeZone = false
    /// Where the Mac goes back to; captured when matching is first turned on.
    var homeTimeZone: String?
    /// Consistency warnings: the Mac telling a different story than the connection.
    var warnTimeZone = true
    var warnAutomaticZone = true
    var warnRegion = true
    /// Once a day, ask GitHub whether a newer release is out.
    var checkUpdates = true

    /// A country or provider rule. Without one, every location passes.
    var hasLocationRules: Bool { !countries.isEmpty || (ispMode == .allowlist && !expectedIsps.isEmpty) }

    mutating func normalize() {
        countries = countries.map { $0.uppercased() }
        domains = domains.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        intervalMs = max(10_000, intervalMs)
        if let zone = homeTimeZone, TimeZone(identifier: zone) == nil { homeTimeZone = nil }

        // Provider names match as loose fragments, so dedupe case-insensitively.
        var seenIsp = Set<String>()
        expectedIsps = Array(expectedIsps
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seenIsp.insert($0.lowercased()).inserted }
            .prefix(20))

        siteRules = siteRules.compactMap { rule in
            guard let domain = normalizeDomain(rule.domain) else { return nil }
            var seen = Set<String>()
            let locations = rule.locations.compactMap { l -> SiteLocation? in
                let code = l.countryCode.trimmingCharacters(in: .whitespaces).uppercased()
                guard code.count == 2, code.allSatisfy({ $0.isASCII && $0.isLetter }) else { return nil }
                let city = l.city?.trimmingCharacters(in: .whitespaces)
                let loc = SiteLocation(countryCode: code,
                                       country: l.country.isEmpty ? code : l.country,
                                       city: city?.isEmpty == false ? city : nil)
                return seen.insert(loc.key).inserted ? loc : nil
            }
            guard !locations.isEmpty else { return nil }
            return SiteRule(domain: domain, locations: locations, edgeLine: rule.edgeLine, killSwitch: rule.killSwitch)
        }
    }
}

extension AppSettings {
    // Field by field, so one bad or missing key falls back alone instead of
    // resetting everything.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ruleMode = c.get(.ruleMode, ruleMode)
        countries = c.get(.countries, countries)
        intervalMs = c.get(.intervalMs, intervalMs)
        domains = c.get(.domains, domains)
        siteRules = c.get(.siteRules, siteRules)
        browserWatch = c.get(.browserWatch, browserWatch)
        alerts = c.get(.alerts, alerts)
        menuBarDisplay = c.get(.menuBarDisplay, menuBarDisplay)
        menuBarClock = c.get(.menuBarClock, menuBarClock)
        launchAtLogin = c.get(.launchAtLogin, launchAtLogin)
        killSwitch = c.get(.killSwitch, killSwitch)
        ispMode = c.get(.ispMode, ispMode)
        expectedIsps = c.get(.expectedIsps, expectedIsps)
        alertOnIspChange = c.get(.alertOnIspChange, alertOnIspChange)
        confirmViolations = c.get(.confirmViolations, confirmViolations)
        ipv6Check = c.get(.ipv6Check, ipv6Check)
        dnsCheck = c.get(.dnsCheck, dnsCheck)
        matchTimeZone = c.get(.matchTimeZone, matchTimeZone)
        homeTimeZone = c.get(.homeTimeZone, homeTimeZone)
        warnTimeZone = c.get(.warnTimeZone, warnTimeZone)
        warnAutomaticZone = c.get(.warnAutomaticZone, warnAutomaticZone)
        warnRegion = c.get(.warnRegion, warnRegion)
        checkUpdates = c.get(.checkUpdates, checkUpdates)
    }
}

extension KeyedDecodingContainer {
    func get<T: Decodable>(_ key: Key, _ fallback: T) -> T {
        (try? decodeIfPresent(T.self, forKey: key)) ?? fallback
    }
}

/// "https://www.Example.com/en?x" → "example.com"
func normalizeDomain(_ raw: String) -> String? {
    var value = raw.trimmingCharacters(in: .whitespaces).lowercased()
    if let range = value.range(of: "://") {
        value = URL(string: value)?.host ?? String(value[range.upperBound...])
    }
    value = String(value.split(separator: "/").first ?? "")
    value = String(value.split(separator: "?").first ?? "")
    value = String(value.split(separator: ":").first ?? "")
    if value.hasPrefix("www.") { value.removeFirst(4) }
    return value.isEmpty ? nil : value
}

// MARK: - Status

struct Location: Equatable {
    var ip: String?
    var country: String?
    var countryCode: String?
    var city: String?
    var isp: String?
    /// nil = the provider can't tell.
    var isVpn: Bool?
    /// IANA zone identifier of the exit.
    var timeZone: String?

    var place: String { country ?? countryCode ?? "unknown" }
    var cityPlace: String { city.map { "\($0), \(place)" } ?? place }
}

enum GeoKind: String { case safe, violation, unknown, offline, checking }

struct GeoStatus: Equatable {
    var kind = GeoKind.checking
    var location: Location?
    var checkedAt: Date?
    var message = "Checking your location…"
    /// Second-provider agreement on a violation; nil = nothing to confirm.
    var confirmed: Bool?
    /// The VPN that's actually up, named by the machine rather than the IP provider.
    var vpnName: String?
}

enum HistoryStatus: String, Codable { case safe, violation, unknown }

struct HistoryEntry: Codable, Identifiable {
    /// Milliseconds since 1970, as GeoMeister wrote it.
    var ts: Double
    var ip: String?
    var countryCode: String?
    var country: String?
    var city: String?
    var isp: String?
    var isVpn: Bool?
    var status: HistoryStatus

    var id: Double { ts }
    var date: Date { Date(timeIntervalSince1970: ts / 1000) }
}

enum ReachKind { case reachable, blocked, checking }

struct ReachResult: Identifiable {
    var host: String
    var status = ReachKind.checking
    var latencyMs: Int?
    var id: String { host }
}

enum SiteState: Equatable { case disabled, idle, match, mismatch, noLocation, unsupported, blocked }

struct SiteWatchStatus: Equatable {
    var state = SiteState.disabled
    var browser: String?
    var host: String?
    var rule: SiteRule?
    var message = "Browser monitoring is off."
}

enum Ipv6State { case off, checking, none, ok, leak, unknown }
enum DnsState { case off, checking, ok, leak, inconclusive, unknown }

struct Ipv6Check {
    var state: Ipv6State
    var ip: String?
    var isp: String?
    var message: String
}

struct DnsResolver {
    var address: String
    var iface: String?
    var isPrivate: Bool
    var country: String?
    var countryCode: String?
    var isp: String?
}

struct DnsCheck {
    var state: DnsState
    var resolvers: [DnsResolver] = []
    var message: String
}

struct LeakStatus {
    var ipv6 = Ipv6Check(state: .checking, message: "Checking your IPv6 exit…")
    var dns = DnsCheck(state: .checking, message: "Checking your DNS resolvers…")
}

struct KillSwitchStatus {
    var active = false
    var reason: String?
    /// The setting is on but the installed helper is missing or outdated.
    var needsSetup = false
    var error: String?
    /// Manually unblocked: standing down until then (or until every monitor is clear),
    /// so the VPN can reconnect. At that time it blocks again if the location still isn't allowed.
    var reblockAt: Date?
    var suppressed: Bool { reblockAt != nil }
}

// MARK: - Countries

enum Countries {
    static let all: [(code: String, name: String)] = Locale.Region.isoRegions
        .map(\.identifier)
        .filter { $0.count == 2 && $0.allSatisfy(\.isLetter) }
        .compactMap { code in Locale.current.localizedString(forRegionCode: code).map { (code, $0) } }
        .sorted { $0.name.localizedCompare($1.name) == .orderedAscending }

    static func name(_ code: String?) -> String? {
        code.flatMap { Locale.current.localizedString(forRegionCode: $0) }
    }

    static func flag(_ code: String?) -> String {
        guard let code, code.count == 2, code.allSatisfy({ $0.isASCII && $0.isLetter }) else { return "🏳️" }
        let scalars = code.uppercased().unicodeScalars.compactMap { Unicode.Scalar(0x1F1E6 + $0.value - 65) }
        return scalars.count == 2 ? String(String.UnicodeScalarView(scalars)) : "🏳️"
    }
}
