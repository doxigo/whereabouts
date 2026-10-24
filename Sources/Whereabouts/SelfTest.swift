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
    s.countries = []
    check(evaluateLocation(exitLoc, s).kind == .safe, "empty allowlist is no rule yet")
    s.countries = ["XA"]
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

    // Unblock window
    let wrong = GeoStatus(kind: .violation, location: exitLoc, message: "geo", confirmed: true)
    var unconfirmed = wrong
    unconfirmed.confirmed = false
    let siteRule = SiteRule(domain: "bank.example", locations: [], killSwitch: true)
    check(reblockReason(wrong, SiteWatchStatus()) == "geo", "still not allowed blocks again")
    check(reblockReason(unconfirmed, SiteWatchStatus()) == nil, "unconfirmed waits for the next check")
    check(reblockReason(GeoStatus(kind: .unknown), SiteWatchStatus(state: .mismatch, rule: siteRule, message: "site")) == "site", "site rule that cuts blocks again")
    check(reblockReason(GeoStatus(kind: .safe), SiteWatchStatus(state: .mismatch, rule: SiteRule(domain: "x", locations: []), message: "site")) == nil, "site rule without cut doesn't")

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
    // The tab is read in-process; a denied Automation grant must still read as "permission needed".
    MainActor.assumeIsolated {
        check((try? runAppleScript("return \"ok\"")) == "ok", "AppleScript runs in-process")
        do {
            _ = try runAppleScript("error \"Not authorized to send Apple events to Browser.\" number -1743")
            check(false, "AppleScript error throws")
        } catch {
            check(isAutomationDenied(error), "Automation denial is recognized: \(error.localizedDescription)")
        }
    }

    // Leak helpers
    check(isPrivateAddress("100.64.0.53"), "CGNAT resolver is private")
    check(isPrivateAddress("192.168.1.1") && isPrivateAddress("fd00::1"), "LAN addresses are private")
    check(!isPrivateAddress("8.8.8.8") && !isPrivateAddress("2001:4860:4860::8888"), "public addresses")
    check(isLoopbackAddress("127.0.2.2") && isLoopbackAddress("::1") && !isLoopbackAddress("10.0.0.1"), "loopback resolvers are local proxies")
    check(networkKey("198.51.100.7") == networkKey("198.51.100.240") && networkKey("198.51.100.7") != networkKey("198.51.101.7"), "IPv4 lookups share a /24")
    check(networkKey("2001:db8:12:1::a") == networkKey("2001:db8:12:ff::b") && networkKey("2001:db8:12::1") != networkKey("2001:db8:13::1"), "IPv6 lookups share a /48")
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
    check(dnsEgress("\"45.13.191.194\"\n") == "45.13.191.194", "DNS egress: resolver address")
    check(dnsEgress("\"172.253.1.2\"\n\"edns0-client-subnet 45.13.191.0/24\"\n") == "45.13.191.0", "DNS egress: client subnet wins")
    check(dnsEgress(";; connection timed out; no servers could be reached\n") == nil, "DNS egress: timeout")

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
    check(kinds(home, w).isEmpty, "working Match handles the zone and region")
    check(kinds(home, w, failing: true) == [.timeZone], "failing Match time zone warns; the region needs no helper")
    var homeAuto = home
    homeAuto.automaticZone = true
    check(kinds(homeAuto, w) == [.timeZone, .automaticZone], "automatic zone defeats Match time zone")
    // Region: only the rg override moves; language and other keywords stay.
    check(regionLocale("en_US@rg=nozzzz", "SE") == "en_US@rg=sezzzz", "region override replaced")
    check(regionLocale("en_US@rg=sezzzz", "US") == "en_US", "home region matching the language drops the override")
    check(regionLocale("en_SE", "NO") == "en_SE@rg=nozzzz", "region override added")
    check(regionLocale("en_US@calendar=gregorian;rg=nozzzz", "SE") == "en_US@calendar=gregorian;rg=sezzzz", "other keywords kept")
    check(Locale(identifier: regionLocale("fa_IR", "DE")).region?.identifier == "DE", "result reads back as the new region")
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
        check(legacy.shareStatus, "status file defaults on")
    }
    var unshared = AppSettings()
    unshared.shareStatus = false
    check((try? JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(unshared)))?.shareStatus == false, "status file off survives a save")

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

    // Alibi host
    check(alibiCover(Location(countryCode: "SE", timeZone: "Etc/GMT-1", lat: 59.3, lon: 18.1))
          == AlibiCover(timezone: "Etc/GMT-1", locale: "sv-SE", lat: 59.3, lon: 18.1), "Alibi cover takes the country's language")
    check(alibiCover(Location(countryCode: "SE", timeZone: "Nowhere/Else")) == nil, "no cover without a real zone")
    check(nativeMessage(Data("{}".utf8)) == Data([2, 0, 0, 0]) + Data("{}".utf8), "native message length prefix")
    check(String(decoding: AlibiHost.helloMessage(), as: UTF8.self) == #"{"accepts":["cover"],"hello":"whereabouts"}"#, "hello says it takes Alibi's cover")
    check(String(decoding: AlibiHost.systemMessage("Etc/GMT-1"), as: UTF8.self) == #"{"system":"Etc/GMT-1"}"#, "system zone")
    check(String(decoding: AlibiHost.systemMessage(nil), as: UTF8.self) == #"{"system":null}"#, "no system zone is null, not left out")

    // Alibi's All sites cover, for the Mac's clock. Its zone and locale: a fixed-offset zone, Sweden's language.
    let place = alibiWish(fromMessage: Data(#"{"cover":{"configuration":"stockholm","timezone":"Etc/GMT-1","locale":"sv-SE"}}"#.utf8))
    check(place == AlibiWish(configuration: "stockholm", timezone: "Etc/GMT-1", locale: "sv-SE"), "Alibi's cover read")
    check(place?.zone == "Etc/GMT-1" && place?.country == "SE", "a place's zone and country")
    let off = alibiWish(fromMessage: Data(#"{"cover":{"configuration":"browserDefault","timezone":null,"locale":null}}"#.utf8))
    check(off != nil && off?.zone == nil && off?.country == nil, "Alibi off names no place")
    let byIp = alibiWish(fromMessage: Data(#"{"cover":{"configuration":"ipAddress","timezone":"Etc/GMT-1","locale":"sv-SE"}}"#.utf8))
    check(byIp != nil && byIp?.zone == nil, "Match my IP address leaves the clock to the connection")
    check(alibiWish(fromMessage: Data(#"{"cover":{"configuration":"x","timezone":"Nowhere/Else"}}"#.utf8)) == nil, "a cover with no real zone is refused")
    check(alibiWish(fromMessage: Data(#"{"cover":{"configuration":"","timezone":"Etc/GMT-1"}}"#.utf8)) == nil, "a cover with no kind is refused")
    check(alibiWish(fromMessage: Data(#"{"something":"else"}"#.utf8)) == nil && alibiWish(fromMessage: Data("[".utf8)) == nil, "other messages aren't covers")
    check(AlibiWish(configuration: "custom", timezone: "Etc/GMT-1", locale: nil).country == nil, "a place without a locale names no country")
    // Alibi in more than one browser or profile, each with a host and a file of its own: the newest place wins,
    // and Off or Match my IP address in one never outvotes a place in another.
    let stockholm = AlibiWish(configuration: "stockholm", timezone: "Etc/GMT-1", locale: "sv-SE")
    let further = AlibiWish(configuration: "custom", timezone: "Etc/GMT-9", locale: nil)
    let quiet = AlibiWish(configuration: "browserDefault", timezone: nil, locale: nil)
    let early = Date(timeIntervalSince1970: 1_761_217_200), late = early.addingTimeInterval(60)
    check(pickWish([AlibiHeard(pid: 1, heard: early, cover: stockholm), AlibiHeard(pid: 2, heard: late, cover: quiet)]) == stockholm,
          "Off in another browser leaves a place alone")
    check(pickWish([AlibiHeard(pid: 1, heard: early, cover: stockholm), AlibiHeard(pid: 2, heard: late, cover: further)]) == further
          && pickWish([AlibiHeard(pid: 2, heard: late, cover: further), AlibiHeard(pid: 1, heard: early, cover: stockholm)]) == further,
          "the newest place wins")
    check(pickWish([AlibiHeard(pid: 1, heard: late, cover: quiet)]) == nil && pickWish([]) == nil, "no place, nothing for the Mac")
    let file = try? JSONDecoder().decode(AlibiHeard.self, from: JSONEncoder().encode(AlibiHeard(pid: 7, heard: early, cover: stockholm)))
    check(file == AlibiHeard(pid: 7, heard: early, cover: stockholm), "a host's file reads back")
    check(AlibiHost.wishURL(pid: 7).lastPathComponent == "alibi-cover-7.json", "a file per host")
    // Alibi's place counts only with Match time zone and Follow Alibi's location both on; the second is off by default.
    var matching = AppSettings()
    matching.matchTimeZone = true
    check(followedPlace(place, matching) == nil, "Follow Alibi's location starts off")
    var alibiOnly = AppSettings()
    alibiOnly.followAlibi = true
    check(followedPlace(place, alibiOnly) == nil, "following Alibi needs Match time zone")
    matching.followAlibi = true
    check(followedPlace(place, matching) == place, "both on: the Mac follows Alibi's place")
    let saved = try? JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(matching))
    check(saved?.followAlibi == true && (try? JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8)))?.followAlibi == false,
          "Follow Alibi's location is saved, and off when settings.json doesn't say")
    // Where the clock goes: Alibi's place first, otherwise as before. Off asks nothing of the Mac.
    func zoneFor(_ wish: AlibiWish?, vpn: Bool = true, known: Bool = true) -> String? {
        timeZoneTarget(wish: wish, exitZone: "Etc/GMT-2", onVpn: vpn, connectionKnown: known, home: "GMT+0330")
    }
    check(zoneFor(place) == "Etc/GMT-1", "Alibi's place wins over the exit")
    check(zoneFor(place, vpn: false, known: false) == "Etc/GMT-1", "Alibi's place needs no connection")
    check(zoneFor(off) == "Etc/GMT-2" && zoneFor(byIp) == "Etc/GMT-2" && zoneFor(nil) == "Etc/GMT-2",
          "Alibi off, Match my IP address, or no word from Alibi: the exit")
    check(zoneFor(off, vpn: false) == "GMT+0330" && zoneFor(nil, vpn: false) == "GMT+0330", "no VPN: home, Alibi off or not")
    check(zoneFor(nil, known: false) == nil && zoneFor(off, known: false) == nil, "no connection and no place: no answer yet")
    func regionFor(_ wish: AlibiWish?, vpn: Bool = true) -> String? {
        regionTarget(wish: wish, exitCountry: "XB", onVpn: vpn, connectionKnown: true, home: "XA")
    }
    check(regionFor(place) == "SE", "the region follows Alibi's place")
    check(regionFor(AlibiWish(configuration: "custom", timezone: "Etc/GMT-1", locale: nil)) == "XA", "a place without a country keeps the home region")
    check(regionFor(off) == "XB" && regionFor(byIp) == "XB" && regionFor(off, vpn: false) == "XA" && regionFor(nil, vpn: false) == "XA",
          "region: the exit on a VPN, home without one, Alibi off or not")
    // The Mac on Alibi's place, the connection somewhere else: a site can compare the two.
    var following = AppSettings()
    following.matchTimeZone = true
    let onPlace = MacFacts(timeZone: "Etc/GMT-1", automaticZone: false, region: "SE")
    check(consistencyWarnings(location: exitZoned, onVpn: true, mac: onPlace, settings: following, matchFailing: false, alibiCountry: "SE")
        .map(\.kind) == [.timeZone], "Alibi's place in another country than the connection")
    check(consistencyWarnings(location: exitZoned, onVpn: true, mac: onPlace, settings: following, matchFailing: false, alibiCountry: "XB")
        .isEmpty, "Alibi's place in the connection's country")

    // status.json: git-ip-guard reads these exact names. Whole seconds; unknowns left out.
    let regional = Location(ip: "198.51.100.1", country: "Exit Country", countryCode: "XB", region: "Exit Region", isp: "Tunnel Provider AB", isVpn: true)
    let at1 = Date(timeIntervalSince1970: 1_761_217_200.7)
    let full = String(decoding: StatusFile.encode(GeoStatus(kind: .safe, location: regional, checkedAt: at1), pid: 42) ?? Data(), as: UTF8.self)
    check(full == #"{"checkedAt":1761217200,"country":"Exit Country","countryCode":"XB","ip":"198.51.100.1","isVpn":true,"isp":"Tunnel Provider AB","kind":"safe","pid":42,"region":"Exit Region","version":1}"#, "status file shape: \(full)")
    let bare = String(decoding: StatusFile.encode(GeoStatus(kind: .offline, checkedAt: at1), pid: 42) ?? Data(), as: UTF8.self)
    check(bare == #"{"checkedAt":1761217200,"kind":"offline","pid":42,"version":1}"#, "status file without a location: \(bare)")

    // Updates
    let release: [String: Any] = ["tag_name": "v1.10.0", "html_url": "https://example.com/release", "assets": [
        ["name": "notes.txt", "browser_download_url": "https://example.com/notes.txt"],
        ["name": "Whereabouts-1.10.0.dmg", "browser_download_url": "https://example.com/app.dmg"],
    ]]
    check(newerRelease(release, than: "1.9.2")?.dmg?.absoluteString == "https://example.com/app.dmg", "newer release picks the disk image")
    check(newerRelease(release, than: "1.10.0") == nil, "same version isn't an update")
    check(newerRelease(["tag_name": "v2.0.0", "html_url": "https://example.com/r"], than: "1.0")?.dmg == nil, "release without a disk image")

    print(failures == 0 ? "selftest: all passed" : "selftest: \(failures) failed")
    exit(failures == 0 ? 0 : 1)
}
