import Foundation

/// `Whereabouts --selftest`: asserts on the pure rule logic. No XCTest needed (it isn't in Command Line Tools).
func selfTest() {
    var failures = 0
    func check(_ ok: Bool, _ what: String, line: Int = #line) {
        if !ok { failures += 1; print("FAIL line \(line): \(what)") }
    }

    // Domains
    check(normalizeDomain("https://www.Example.com/en?x=1") == "example.com", "normalizeDomain URL")
    check(normalizeDomain("github.com:443") == "github.com", "normalizeDomain port")
    check(normalizeDomain("   ") == nil, "normalizeDomain empty")

    // Country / ISP rule. Fixtures are made up: user-assigned ISO codes (XA, XB),
    // documentation IPs and fixed-offset zones, so no real place is hardcoded.
    var s = AppSettings()
    s.countries = ["XA"]
    let homeLoc = Location(ip: "192.0.2.1", country: "Home Country", countryCode: "XA", city: "Home City", isp: "Home ISP", isVpn: false)
    let exitLoc = Location(ip: "198.51.100.1", country: "Exit Country", countryCode: "XB", city: "Exit City", isp: "Tunnel Provider AB", isVpn: true)
    check(evaluateLocation(homeLoc, s).kind == .violation, "blocklist hit")
    check(evaluateLocation(exitLoc, s).kind == .safe, "blocklist miss")
    s.ruleMode = .allowlist
    check(evaluateLocation(homeLoc, s).kind == .safe, "allowlist hit")
    check(evaluateLocation(exitLoc, s).reason == .country, "allowlist miss")
    s.ruleMode = .blocklist
    s.ispMode = .allowlist
    s.expectedIsps = ["tunnel"]
    check(evaluateLocation(exitLoc, s).kind == .safe, "expected ISP fragment matches")
    var dropped = exitLoc
    dropped.isp = "Local Telecom"
    check(evaluateLocation(dropped, s).reason == .isp, "unexpected ISP is a violation")
    dropped.isp = nil
    check(evaluateLocation(dropped, s).kind == .safe, "unknown ISP is never a violation")
    check(evaluateLocation(Location(), s).kind == .unknown, "no country is unknown")

    // Settings normalization
    var n = AppSettings()
    n.intervalMs = 1
    n.expectedIsps = ["Tunnel", " tunnel ", ""]
    n.siteRules = [SiteRule(domain: "https://www.Shop.example/", locations: [
        SiteLocation(countryCode: "xb", country: "Exit Country", city: " Exit City "),
        SiteLocation(countryCode: "XB", country: "Exit Country", city: "exit city"),
        SiteLocation(countryCode: "XYZ", country: "?", city: nil),
    ])]
    n.normalize()
    check(n.intervalMs == 10_000, "interval floor")
    check(n.expectedIsps == ["Tunnel"], "ISP dedupe")
    check(n.siteRules.first?.domain == "shop.example" && n.siteRules.first?.locations.count == 1, "site rule normalize")

    // Old GeoMeister JSON (city null, missing newer keys) decodes leniently
    let legacy = #"{"ruleMode":"allowlist","countries":["xb"],"siteRules":[{"domain":"shop.example","locations":[{"countryCode":"XA","country":"Home Country","city":null}]}],"alerts":{"sound":true}}"#
    if var decoded = try? JSONDecoder().decode(AppSettings.self, from: Data(legacy.utf8)) {
        decoded.normalize()
        check(decoded.ruleMode == .allowlist && decoded.countries == ["XB"], "legacy rule mode/countries")
        check(decoded.alerts.sound && decoded.alerts.notifications, "legacy alerts merge with defaults")
        check(decoded.siteRules.first?.edgeLine == false && decoded.dnsCheck, "legacy missing keys default")
    } else {
        check(false, "legacy settings decode")
    }

    // Site rules
    let rule = SiteRule(domain: "bank.example", locations: [SiteLocation(countryCode: "XA", country: "Home Country", city: "Home City")])
    check(matchRule("accounts.bank.example", [rule]) != nil, "subdomain matches")
    check(matchRule("notbank.example", [rule]) == nil, "suffix without dot doesn't match")
    check(locationSatisfies(Location(countryCode: "XA", city: "home city"), rule), "city match is case-insensitive")
    check(!locationSatisfies(Location(countryCode: "XA", city: "Other City"), rule), "wrong city")

    // Leak helpers
    check(isPrivateAddress("100.64.0.53"), "CGNAT resolver is private")
    check(isPrivateAddress("192.168.1.1") && isPrivateAddress("fd00::1"), "LAN addresses are private")
    check(!isPrivateAddress("8.8.8.8") && !isPrivateAddress("2001:4860:4860::8888"), "public addresses")
    let scutil = """
    DNS configuration

    resolver #1
      search domain[0] : lan
      nameserver[0] : 100.64.0.53
      if_index : 23 (utun4)
      flags    : Request A records

    resolver #2
      domain   : local
      options  : mdns

    DNS configuration (for scoped queries)

    resolver #1
      nameserver[0] : 192.168.1.1
      if_index : 15 (en0)
    """
    let blocks = parseResolvers(scutil)
    check(blocks == [ResolverBlock(nameservers: ["100.64.0.53"], iface: "utun4")], "scutil parse: \(blocks)")
    check(isTunnelInterface("utun4") && !isTunnelInterface("en0"), "tunnel interfaces")

    // Kill switch helper
    check(KillSwitch.setupScript(user: "alice").contains("alice ALL=(root) NOPASSWD: /Library/Application\\ Support/Whereabouts/killswitch-helper.sh engage"), "sudoers grant")
    check(KillSwitch.helperScript.contains("# WHEREABOUTS_HELPER_VERSION=1\n") && KillSwitch.helperScript.contains("\nWA_RULES\n"), "helper script")
    for (name, script) in [("setup", KillSwitch.setupScript(user: "alice")), ("teardown", KillSwitch.teardownScript), ("helper", KillSwitch.helperScript)] {
        let path = NSTemporaryDirectory() + "wa-selftest-\(name).sh"
        try? script.write(toFile: path, atomically: true, encoding: .utf8)
        check((try? runSync("/bin/bash", ["-n", path], timeout: 5)) != nil, "\(name) script parses")
        try? FileManager.default.removeItem(atPath: path)
    }
    // Time zone helper: validation runs before anything privileged, so it can be exercised unprivileged.
    check(TimeZoneHelper.setupScript(user: "alice").contains("alice ALL=(root) NOPASSWD: /Library/Application\\ Support/Whereabouts/timezone-helper.sh *"), "tz sudoers grant")
    check(KillSwitch.teardownScript.contains("rmdir") && !KillSwitch.teardownScript.contains("rm -rf"), "kill switch teardown leaves the tz helper alone")
    let tzPath = NSTemporaryDirectory() + "wa-selftest-tz.sh"
    try? TimeZoneHelper.helperScript.write(toFile: tzPath, atomically: true, encoding: .utf8)
    func tzStatus(_ zone: String) -> Int32 {
        do { _ = try runSync("/bin/bash", [tzPath, zone], timeout: 10); return 0 }
        catch let error as ShellError { return error.status }
        catch { return -1 }
    }
    for (name, script) in [("tz setup", TimeZoneHelper.setupScript(user: "alice")), ("tz teardown", TimeZoneHelper.teardownScript)] {
        let path = NSTemporaryDirectory() + "wa-selftest-\(name.replacingOccurrences(of: " ", with: "-")).sh"
        try? script.write(toFile: path, atomically: true, encoding: .utf8)
        check((try? runSync("/bin/bash", ["-n", path], timeout: 5)) != nil, "\(name) script parses")
        try? FileManager.default.removeItem(atPath: path)
    }
    for bad in ["", "../../etc/passwd", "Europe", "Etc/UTC; rm -rf /", "Europe/../../etc/hosts"] {
        check(tzStatus(bad) == 2, "tz helper rejects \(bad.debugDescription)")
    }
    // As a normal user a valid zone passes validation, then can't be applied (exit 3).
    if getuid() != 0 {
        // Real two- and three-part names, taken from the system rather than hardcoded.
        let known = TimeZone.knownTimeZoneIdentifiers
        let named = [2, 3].compactMap { parts in known.first { $0.split(separator: "/").count == parts } }
        for good in named + ["UTC", "Etc/GMT+3"] {
            check(tzStatus(good) != 2, "tz helper accepts \(good)")
        }
    }
    try? FileManager.default.removeItem(atPath: tzPath)
    // Must agree with System Settings › General › Date & Time; the legacy plist didn't.
    print("selftest info: automatic time zone reads \(TimeZoneHelper.automaticIsOn ? "on" : "off")")

    // Consistency warnings: each appears on a mismatch and clears when the Mac agrees.
    var exitZoned = exitLoc
    exitZoned.timeZone = "Etc/GMT-1"
    let home = MacFacts(timeZone: "GMT+0330", automaticZone: false, region: "XA")
    let agreeing = MacFacts(timeZone: "Etc/GMT-1", automaticZone: false, region: "XB")
    func kinds(_ mac: MacFacts, _ s: AppSettings = AppSettings(), loc: Location? = exitZoned, vpn: Bool = true, failing: Bool = false) -> [ConsistencyKind] {
        consistencyWarnings(location: loc, onVpn: vpn, mac: mac, settings: s, matchFailing: failing).map(\.kind)
    }
    check(kinds(home) == [.timeZone, .region], "zone and region mismatch on a VPN")
    check(kinds(agreeing).isEmpty, "matching Mac clears zone and region")
    check(kinds(home, vpn: false).isEmpty, "no VPN, nothing to give away")
    check(kinds(home, loc: nil).isEmpty, "no location, no zone/region verdict")
    var auto = agreeing
    auto.automaticZone = true
    check(kinds(auto) == [.automaticZone], "automatic zone on a VPN")
    check(kinds(auto, vpn: false).isEmpty, "automatic zone is harmless off a VPN")
    var w = AppSettings()
    w.matchTimeZone = true
    check(kinds(auto, w, vpn: false) == [.automaticZone], "automatic zone blocks Match time zone")
    check(kinds(home, w) == [.region], "working Match time zone handles the zone")
    check(kinds(home, w, failing: true) == [.timeZone, .region], "failing Match time zone warns")
    var homeAuto = home
    homeAuto.automaticZone = true
    check(kinds(homeAuto, w) == [.timeZone, .automaticZone, .region], "automatic zone defeats Match time zone")
    w = AppSettings()
    w.warnTimeZone = false; w.warnAutomaticZone = false; w.warnRegion = false
    check(kinds(homeAuto, w).isEmpty, "each warning can be turned off")
    check(consistencyWarnings(location: exitZoned, onVpn: true, mac: home, settings: AppSettings(), matchFailing: false)[0].detail
        .contains("GMT+0330, your connection is in Etc/GMT-1"), "zone warning names both zones")
    // Notify once per appearance; a failed lookup forgets nothing.
    var announced = Set<ConsistencyKind>()
    let both = consistencyWarnings(location: exitZoned, onVpn: true, mac: home, settings: AppSettings(), matchFailing: false)
    check(newWarnings(both, announced: &announced, connectionKnown: true).count == 2, "first appearance notifies")
    check(newWarnings(both, announced: &announced, connectionKnown: true).isEmpty, "repeat check stays quiet")
    check(newWarnings([], announced: &announced, connectionKnown: false).isEmpty && announced.count == 2, "blip keeps state")
    check(newWarnings(both, announced: &announced, connectionKnown: true).isEmpty, "no re-notify after a blip")
    _ = newWarnings([], announced: &announced, connectionKnown: true)
    check(announced.isEmpty && newWarnings(both, announced: &announced, connectionKnown: true).count == 2, "cleared then back notifies again")
    if let legacy = try? JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8)) {
        check(legacy.warnTimeZone && legacy.warnAutomaticZone && legacy.warnRegion, "warnings default on")
    }

    // Menu-bar clock: home time in every mode, whatever zone the Mac is on.
    let homeTZ = TimeZone(identifier: "GMT+0330")!, macTZ = TimeZone(identifier: "GMT+0200")!
    let at = Date(timeIntervalSince1970: 1_792_348_920) // 2026-10-18 18:42 UTC: 22:12 at home (+3:30), 20:42 on the Mac (+2)
    var zs = AppSettings()
    zs.homeTimeZone = "GMT+0330"
    check(homeClockZone(zs, mac: macTZ) == macTZ, "stale home zone ignored while matching is off")
    zs.matchTimeZone = true
    check(homeClockZone(zs, mac: macTZ) == homeTZ, "matching shows the home zone")
    zs.homeTimeZone = nil
    check(homeClockZone(zs, mac: macTZ) == macTZ, "no home zone falls back to the Mac's")
    let gb = Locale(identifier: "en_GB")
    func clock(_ style: MenuBarClock, _ home: TimeZone, _ mac: TimeZone, _ locale: Locale = gb) -> String? {
        clockText(style, home: home, mac: mac, at: at, locale: locale)
    }
    check(clock(.time, homeTZ, macTZ) == "22:12", "time in the home zone: \(clock(.time, homeTZ, macTZ) ?? "nil")")
    check(clock(.time, macTZ, macTZ) == "20:42", "time shows even when zones agree")
    check(clock(.away, homeTZ, macTZ) == "22:12 home", "away mode while the Mac is moved")
    check(clock(.away, macTZ, TimeZone(identifier: "Etc/GMT-2")!) == nil, "away mode hides when the offset matches")
    let day = clock(.day, homeTZ, macTZ) ?? "", date = clock(.date, homeTZ, macTZ) ?? ""
    check(day.contains("Sun") && day.contains("22:12") && !day.contains("Oct"), "day style: \(day)")
    check(date.contains("Sun") && date.contains("18") && date.contains("Oct") && date.contains("22:12") && !date.contains(" at "), "date style: \(date)")
    let us = clock(.time, homeTZ, macTZ, Locale(identifier: "en_US")) ?? ""
    check(us.hasPrefix("10:12") && us.hasSuffix("PM"), "12-hour locale: \(us)")

    check(Countries.flag("XA") == "\u{1F1FD}\u{1F1E6}" && Countries.flag(nil) == "🏳️" && Countries.flag("1A") == "🏳️", "flags")

    print(failures == 0 ? "selftest: all passed" : "selftest: \(failures) failed")
    exit(failures == 0 ? 0 : 1)
}
