import Foundation

@MainActor func regressionTests(_ check: (Bool, String) -> Void) async {
    var settings = AppSettings()
    settings.countries = ["XA"]
    settings.killSwitch = true
    settings.confirmViolations = false
    let wrong = Location(ip: "192.0.2.1", countryCode: "XA", isp: "Home ISP")
    let safe = Location(ip: "198.51.100.1", countryCode: "XB", isp: "Tunnel ISP")
    let history = [HistoryEntry(ts: 1, countryCode: "XA", status: .violation)]
    let monitor = Monitor(settings: settings, history: history, testing: true)
    var commands: [String] = []
    monitor.lookup = { (wrong, .ipWho) }
    monitor.firewall = { command in commands.append(command); return "active" }
    await monitor.checkGeo()
    check(commands == ["engage"], "a violation restored from history still blocks")

    monitor.kill.active = false
    monitor.kill.reblockAt = Date().addingTimeInterval(120)
    await monitor.checkGeo()
    check(commands.count == 1, "manual unblock suppresses enforcement")
    monitor.rearmKillSwitch()
    await monitor.reconcileProtection()
    check(commands == ["engage", "engage"], "explicit re-arm enforces an existing violation")

    monitor.kill = KillSwitchStatus()
    var fail = true
    monitor.firewall = { command in
        commands.append(command)
        if fail { throw ShellError(status: 1, output: "fixture failure") }
        return "active"
    }
    await monitor.checkGeo()
    check(!monitor.kill.active && monitor.kill.error != nil, "firewall failures stay visible")
    fail = false
    await monitor.checkGeo()
    check(monitor.kill.active && commands.suffix(2) == ["engage", "engage"], "persistent violations retry failed enforcement")

    monitor.kill = KillSwitchStatus()
    monitor.update { $0.killSwitch = false }
    let beforeEnable = commands.count
    await monitor.checkGeo()
    check(commands.count == beforeEnable, "disabled protection never blocks")
    monitor.update { $0.killSwitch = true }
    await monitor.reconcileProtection()
    check(commands.count == beforeEnable + 1 && monitor.kill.active, "enabling protection enforces an existing violation")

    monitor.kill = KillSwitchStatus()
    monitor.update { $0.browserWatch = true }
    monitor.geo = GeoStatus(kind: .safe, location: safe)
    monitor.site = SiteWatchStatus(state: .mismatch, rule: SiteRule(domain: "bank.example", locations: [SiteLocation(countryCode: "XC", country: "Fixture")], killSwitch: true), message: "site")
    monitor.siteAlertKey = "already announced"
    await monitor.reconcileProtection()
    check(monitor.kill.active && monitor.kill.reason == "site", "site enforcement does not depend on notification deduplication")
    monitor.kill = KillSwitchStatus()
    monitor.geo = GeoStatus(kind: .safe, location: Location(countryCode: "XC"))
    await monitor.reconcileProtection()
    check(!monitor.kill.active, "an old site mismatch cannot block a newly allowed location")

    let sleeping = Monitor(settings: settings, history: [], testing: true)
    sleeping.update { $0.holdOnWake = true }
    var sleepCommands: [String] = []
    sleeping.holdFirewall = { addresses in sleepCommands.append("hold:\(addresses.count)") }
    sleeping.firewall = { command in sleepCommands.append(command); return "inactive" }
    sleeping.preparedHoldAddresses = ["192.0.2.10"]
    sleeping.holdForSleep()
    check(sleeping.kill.held && sleeping.geo.kind == .checking && sleepCommands == ["hold:1"], "sleep loads only prepared rules and invalidates the old verdict")
    var pending: CheckedContinuation<(Location, Provider)?, Never>?
    sleeping.lookup = { await withCheckedContinuation { pending = $0 } }
    let oldCheck = Task { await sleeping.checkGeo() }
    while pending == nil { await Task.yield() }
    sleeping.markChecking()
    pending?.resume(returning: (safe, .ipWho))
    _ = await oldCheck.value
    check(sleeping.kill.held && sleeping.geo.kind == .checking && sleepCommands.count == 1, "a pre-wake response cannot release the hold")
    sleeping.lookup = { (safe, .ipWho) }
    await sleeping.checkGeo()
    check(!sleeping.kill.active && sleepCommands.last == "release", "a fresh allowed wake check releases the hold")

    sleeping.kill = KillSwitchStatus(active: true, held: true)
    sleeping.lookup = { nil }
    await sleeping.checkGeo()
    check(sleeping.kill.held, "provider failure retains the sleep hold")
    sleeping.lookup = { (wrong, .ipWho) }
    await sleeping.checkGeo()
    check(sleeping.kill.active && !sleeping.kill.held && sleepCommands.last == "engage", "wake violation replaces the permissive hold with a block")

    let edited = Monitor(settings: settings, history: [], testing: true)
    edited.lookup = { await withCheckedContinuation { pending = $0 } }
    edited.firewall = { command in commands.append(command); return "active" }
    pending = nil
    let editedCheck = Task { await edited.checkGeo() }
    while pending == nil { await Task.yield() }
    edited.update { $0.countries = ["XB"] }
    pending?.resume(returning: (safe, .ipWho))
    _ = await editedCheck.value
    check(edited.geo.kind == .checking && !edited.kill.active, "rule edits invalidate an in-flight lookup")

    let coalesced = Monitor(settings: settings, history: [], testing: true)
    var lookupCount = 0
    pending = nil
    coalesced.lookup = {
        lookupCount += 1
        if lookupCount == 1 { return await withCheckedContinuation { pending = $0 } }
        return (wrong, .ipWho)
    }
    coalesced.firewall = { _ in "active" }
    let first = Task { await coalesced.checkGeo() }
    while pending == nil { await Task.yield() }
    let second = Task { await coalesced.checkGeo() }
    while !coalesced.geoRecheckQueued { await Task.yield() }
    pending?.resume(returning: (safe, .ipWho))
    _ = await first.value
    let fresh = await second.value
    check(fresh.kind == .violation && coalesced.kill.active && lookupCount == 2, "overlapping checks await a new result instead of returning a stale verdict")

    var confirmation = ProtectionState()
    var disputed = GeoStatus(kind: .violation, location: wrong, confirmed: false)
    confirmation.accept(&disputed)
    check(disputed.confirmed == false, "the first disputed verdict waits")
    confirmation.accept(&disputed)
    check(disputed.confirmed == true, "a repeated matching verdict confirms")
    confirmation.invalidate()
    disputed.confirmed = false
    confirmation.accept(&disputed)
    check(disputed.confirmed == false, "route changes discard confirmation history")
    var different = GeoStatus(kind: .violation, location: safe, confirmed: false)
    confirmation.accept(&different)
    check(different.confirmed == false, "different violations do not confirm each other")

    var draft = PendingSiteLocation(country: "PT", city: "Lisbon")
    var locations: [SiteLocation] = []
    draft.add(to: &locations)
    let saved = draft.appending(to: locations)
    check(saved.count == 1 && saved.first?.city == "Lisbon", "Add then Save preserves a city-only rule")
    check(!locationSatisfies(Location(countryCode: "PT", city: "Porto"), SiteRule(domain: "bank.example", locations: saved)), "a different city is refused after Add then Save")
    draft = PendingSiteLocation(country: "PT")
    check(draft.appending(to: []).first?.city == nil, "an explicitly chosen whole country is still supported")

    let parent = SiteRule(domain: "example.com", locations: [])
    let child = SiteRule(domain: "accounts.example.com", locations: [])
    for rules in [[parent, child], [child, parent]] {
        check(matchRule("login.accounts.example.com", rules)?.domain == child.domain, "the most specific domain wins regardless of insertion order")
    }
    check(statusMark(geo: .safe, site: .mismatch, blocked: false, leaking: false) == .refused, "site violations cannot show all-clear")
    check(statusMark(geo: .safe, site: .mismatch, blocked: true, leaking: true) == .blocked, "the firewall state outranks all other statuses")
    for transport in ["IPv6", "UDP"] { check(unansweredExitCheck(transport).state == .unknown, "failed \(transport) probes stay unknown") }
    check(nextCheckDelay(interval: 60, elapsed: 24) == 36 && nextCheckDelay(interval: 60, elapsed: 80) == 0, "checks are scheduled from their start time")

    let json: [String: Any] = ["success": true, "ip": "192.0.2.1", "country_code": "PT", "connection": ["asn": 64500, "isp": "Fixture"]]
    check((try? parseIpWho(json))?.asn == 64500, "HTTPS primary parses network identity")
    check((try? parseIpWho(["success": false, "message": "quota"])) == nil, "provider failures cannot become locations")
    check((try? parseIpApi(["ip": "192.0.2.1", "country_code": "PT", "asn": "AS64500", "org": "Fixture"]))?.asn == 64500, "HTTPS fallback parses network identity")
    do { _ = try await fetchData("http://example.invalid"); check(false, "plaintext lookup refused") }
    catch { check(true, "plaintext lookup refused before connecting") }
    check(!isReleaseURL(URL(string: "https://github.com/other/app/releases/download/v2/app.dmg")!, download: true), "updates outside this repository are refused")
    check(!isReleaseURL(URL(string: "http://github.com/doxigo/whereabouts/releases/download/v2/app.dmg")!, download: true), "plaintext update URLs are refused")

    let start = ContinuousClock.now
    let script = Task { try? await runAppleScript("delay 1\nreturn \"done\"") }
    try? await Task.sleep(for: .milliseconds(100))
    check(start.duration(to: .now) < .milliseconds(700), "a slow browser helper leaves the main actor responsive")
    check(await script.value == "done", "the asynchronous browser helper completes")

    let blip = Monitor(settings: settings, history: [], testing: true)
    blip.lookup = { (safe, .ipWho) }
    await blip.checkGeo()
    blip.lookup = { nil }
    await blip.checkGeo()
    check(blip.geo.kind == .safe && blip.geo.location == safe, "one unanswered check keeps the last answer")
    await blip.checkGeo()
    check(blip.geo.kind == .unknown || blip.geo.kind == .offline, "a second unanswered check shows the outage")
    blip.lookup = { (safe, .ipWho) }
    await blip.checkGeo()
    blip.markChecking()
    blip.lookup = { nil }
    await blip.checkGeo()
    check(blip.geo.location == nil, "a failed check after a route change never shows the old answer")
}

@MainActor func networkSmokeTest() async {
    let monitor = Monitor(settings: AppSettings(), history: [], testing: true)
    let start = Date()
    let geo = await monitor.checkGeo()
    let lookupSeconds = Date().timeIntervalSince(start)
    monitor.geo.vpnName = await activeVpnName()
    await monitor.checkLeaks()
    var usage = rusage(), children = rusage()
    getrusage(RUSAGE_SELF, &usage)
    getrusage(RUSAGE_CHILDREN, &children)
    func seconds(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1e6 }
    let cpu = seconds(usage.ru_utime) + seconds(usage.ru_stime) + seconds(children.ru_utime) + seconds(children.ru_stime)
    let result: [String: Any] = [
        "location": geo.kind.rawValue,
        "ipv6": monitor.leak.ipv6.state.label,
        "udp": monitor.leak.udp.state.label,
        "dns": monitor.leak.dns.state.label,
        "lookup_seconds": lookupSeconds,
        "total_seconds": Date().timeIntervalSince(start),
        "cpu_seconds_including_helpers": cpu,
        "peak_rss_mib": Double(usage.ru_maxrss) / 1_048_576,
        "persistent_or_privileged_changes": false,
    ]
    if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) {
        print(String(decoding: data, as: UTF8.self))
    }
    exit(geo.location != nil ? 0 : 1)
}
