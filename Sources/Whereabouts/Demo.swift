import Foundation

/// `--demo [safe|blocked]`: made-up state for README screenshots. Nothing is looked up,
/// saved, announced or blocked, so it can run beside the real app without touching it.
/// Addresses come from the documentation ranges (RFC 5737 / RFC 3849).
/// With it, `--settings <Tab>` opens that Settings tab and `--menu` pops the status menu;
/// `-theme light|dark` (read by UserDefaults from the arguments) fixes the appearance.
enum Demo {
    static let scenario: String? = {
        guard CommandLine.arguments.contains("--demo") else { return nil }
        return value(after: "--demo") ?? "safe"
    }()
    static var enabled: Bool { scenario != nil }
    static var settingsTab: String? { enabled ? value(after: "--settings") : nil }
    static var opensMenu: Bool { enabled && CommandLine.arguments.contains("--menu") }
    private static var blocked: Bool { scenario == "blocked" }

    private static func value(after flag: String) -> String? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: flag), args.indices.contains(i + 1), !args[i + 1].hasPrefix("-") else { return nil }
        return args[i + 1]
    }

    static var settings: AppSettings {
        var s = AppSettings()
        s.ruleMode = .allowlist
        s.countries = ["PT", "NL", "DE"]
        s.domains = ["github.com", "wikipedia.org", "example.com"]
        s.browserWatch = true
        s.siteRules = [SiteRule(domain: "bank.example", locations: [SiteLocation(countryCode: "PT", country: "Portugal", city: "Lisbon")])]
        s.killSwitch = true
        s.homeTimeZone = "Europe/Lisbon"
        // The warnings compare against this Mac's real region and zone; keep those out of screenshots.
        s.warnTimeZone = false
        s.warnAutomaticZone = false
        s.warnRegion = false
        return s
    }

    static var history: [HistoryEntry] {
        let now = Date().timeIntervalSince1970 * 1000
        func entry(_ minutesAgo: Double, _ code: String, _ country: String, _ city: String, _ status: HistoryStatus) -> HistoryEntry {
            HistoryEntry(ts: now - minutesAgo * 60_000, ip: "203.0.113.42", countryCode: code, country: country,
                         city: city, isp: "Example Transit", isVpn: true, status: status)
        }
        var list = [entry(4, "PT", "Portugal", "Lisbon", .safe), entry(52, "US", "United States", "Ashburn", .violation),
                    entry(95, "NL", "Netherlands", "Amsterdam", .safe), entry(310, "DE", "Germany", "Frankfurt", .safe)]
        if blocked { list.insert(entry(1, "US", "United States", "Ashburn", .violation), at: 0) }
        return list
    }

    @MainActor static func apply(to m: Monitor) {
        let checked = Date().addingTimeInterval(-40)
        m.systemTimeZone = "Europe/Lisbon"
        if blocked {
            let loc = Location(ip: "198.51.100.7", country: "United States", countryCode: "US", city: "Ashburn",
                               isp: "Example Cloud", isVpn: true, timeZone: "America/New_York")
            let reason = "Your IP is outside your allowed countries: United States."
            m.geo = GeoStatus(kind: .violation, location: loc, checkedAt: checked, message: reason, vpnName: "WireGuard")
            m.kill = KillSwitchStatus(active: true, triggeredAt: checked, reason: reason)
        } else {
            let loc = Location(ip: "203.0.113.42", country: "Portugal", countryCode: "PT", city: "Lisbon",
                               isp: "Example Transit", isVpn: true, timeZone: "Europe/Lisbon")
            m.geo = GeoStatus(kind: .safe, location: loc, checkedAt: checked,
                              message: "Your IP is in an allowed country: Portugal.", vpnName: "WireGuard")
        }
        m.site = SiteWatchStatus(state: blocked ? .mismatch : .match, browser: "Safari", host: "bank.example", rule: settings.siteRules.first,
                                 message: blocked ? "bank.example expects Lisbon, Portugal, but you're in Ashburn, United States."
                                     : "bank.example expects Lisbon, Portugal, and that's where you are.")
        m.leak = LeakStatus(
            ipv6: Ipv6Check(state: .ok, ip: "2001:db8:4a::17", country: "Portugal", countryCode: "PT", isp: "Example Transit",
                            message: "Your IPv6 exit is in Portugal too."),
            dns: DnsCheck(state: .ok, resolvers: [DnsResolver(address: "10.64.0.1", iface: "utun4", isPrivate: true, isTunnel: true)],
                          message: "DNS goes through the VPN tunnel."),
            checkedAt: checked)
        // With the kill switch engaged nothing past the local network answers.
        m.reach = [("github.com", 38), ("wikipedia.org", 52), ("example.com", 61)].map {
            ReachResult(host: $0.0, status: blocked ? .blocked : .reachable, latencyMs: blocked ? nil : $0.1)
        }
    }
}
