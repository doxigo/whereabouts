import Foundation

@MainActor func protectionFeatureTests(_ check: (Bool, String) -> Void) async {
    check(runtimeReportFailed("PASS: baseline\rFAIL: engage\n"), "live test failures survive AppleScript carriage-return output")
    check(!runtimeReportFailed("PASS: blocked\nSKIP: no baseline"), "live test skips are separate from failures")
    let defaults = (try? JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))) ?? AppSettings()
    check(!defaults.strictProtection && !defaults.protectionTimeline && !defaults.connectionProfilesEnabled, "new protection features default off for existing settings")
    let exit = Location(ip: "192.0.2.1", countryCode: "NO", city: "Sandefjord", asn: 64500, timeZone: "Europe/Oslo")
    let follow = followsConnectionZone(location: exit, vpnName: nil)
    check(follow && timeZoneTarget(wish: nil, exitZone: exit.timeZone, onVpn: follow, connectionKnown: true, home: "Asia/Tehran") == "Europe/Oslo",
          "an unknown VPN flag never restores Tehran over an Oslo exit")
    check(!followsConnectionZone(location: nil, vpnName: nil), "an absent location is not a VPN verdict")
    check(!followsConnectionZone(location: Location(isVpn: false), vpnName: nil), "an explicitly direct connection can restore home")
    check(followsConnectionZone(location: Location(isVpn: false), vpnName: "Tunnel"), "local VPN evidence overrides a provider flag")

    let profile = ConnectionProfile(name: "Norway", locations: [SiteLocation(countryCode: "NO", country: "Norway", city: "Sandefjord")], asns: [64500])
    var settings = AppSettings()
    settings.connectionProfiles = [profile]
    settings.activeProfileID = profile.id
    settings.connectionProfilesEnabled = true
    check(evaluateLocation(exit, settings).kind == .safe, "a profile requires matching city and exact ASN")
    var other = exit
    other.asn = 64501
    check(evaluateLocation(other, settings).kind == .violation, "a different ASN fails even inside the same city")
    other.asn = nil
    check(evaluateLocation(other, settings).kind == .unknown, "a missing ASN cannot pass a profile")
    other = exit; other.city = "Oslo"
    check(evaluateLocation(other, settings).kind == .violation, "a city profile rejects another city")
    other.city = nil
    check(evaluateLocation(other, settings).kind == .unknown, "a missing required city stays unknown")
    settings.connectionProfiles[0].locations[0].city = nil
    check(evaluateLocation(other, settings).kind == .safe, "a whole-country profile does not require city metadata")
    settings.countries = ["NO"]
    check(evaluateLocation(exit, settings).kind == .violation, "a profile cannot override a blocked country")
    settings.countries = []
    settings.activeProfileID = UUID()
    check(evaluateLocation(exit, settings).kind == .unknown, "deleting the active profile does not silently allow everything")
    settings.connectionProfilesEnabled = false
    check(evaluateLocation(exit, settings).kind == .safe && settings.connectionProfiles.count == 1, "disabling profiles retains their data and stops enforcing them")
    check(parseASNs("AS64500, 64501 as64500") == [64500, 64501], "ASNs parse and deduplicate exactly")
    for invalid in ["", "AS", "-1", "0", "64500oops", "4294967296", "1.2"] {
        check(parseASNs(invalid) == nil, "invalid ASN rejected: \(invalid)")
    }
    settings.activeProfileID = profile.id
    settings.connectionProfilesEnabled = true
    settings.strictProtection = true
    settings.protectionTimeline = true
    check((try? JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))) == settings, "all new settings round-trip without losing profiles")

    settings.killSwitch = true
    settings.confirmViolations = false
    let monitor = Monitor(settings: settings, history: [], testing: true)
    var commands: [String] = []
    var addresses: [[String]] = []
    monitor.verificationFirewall = { addresses.append($0) }
    monitor.verificationAddresses = { $0 ? ["dns:1.1.1.1"] : ["dns:1.1.1.1", "192.0.2.20", "vpn:198.51.100.1"] }
    monitor.firewall = { commands.append($0); return "inactive" }
    await monitor.reconcileProtection()
    check(monitor.kill.active && monitor.kill.verifying && addresses.count == 3 && addresses.first == [], "strict startup blocks before resolving verification endpoints")
    monitor.lookup = { nil }
    await monitor.checkGeo()
    check(monitor.kill.verifying && !commands.contains("release"), "provider outages cannot release strict protection")
    monitor.lookup = { (exit, .ipWho) }
    await monitor.checkGeo()
    check(!monitor.kill.active && commands.last == "release", "an allowed profile releases the verification hold")
    check(addresses.count == 6, "a failed lookup refreshes verification addresses before retrying")
    monitor.markChecking()
    await monitor.reconcileProtection()
    check(monitor.kill.verifying && addresses.count == 9, "route changes reapply strict protection")
    await monitor.restoreConnection()
    await monitor.reconcileProtection()
    check(!monitor.kill.active && monitor.kill.suppressed && addresses.count == 9, "manual unblock overrides strict mode during its recovery window")
    monitor.rearmKillSwitch()
    await monitor.reconcileProtection()
    check(monitor.kill.verifying, "explicit re-arm restores strict mode while location is unknown")
    monitor.lookup = { (Location(countryCode: "IR", city: "Tehran", asn: 64501), .ipWho) }
    await monitor.checkGeo()
    check(monitor.kill.active && !monitor.kill.held && commands.last == "engage", "a confirmed profile mismatch upgrades strict restrictions to a full block")
    check(monitor.timeline.contains { $0.category == "Location check" } && monitor.timeline.contains { $0.category == "Firewall" }
          && monitor.timeline.contains { $0.category == "Connection" }, "the timeline records checks, firewall actions and route changes")
    let eventCount = monitor.timeline.count
    monitor.update { $0.protectionTimeline = false }
    monitor.recordProtection("Fixture", "Not recorded")
    check(monitor.timeline.count == eventCount, "disabling the timeline stops writes and retains existing events")
    monitor.update { $0.protectionTimeline = true }
    for index in 0...Store.maxTimeline { monitor.recordProtection("Fixture", "\(index)") }
    check(monitor.timeline.count == Store.maxTimeline && monitor.timeline.first?.detail == "500", "timeline storage is bounded and newest first")
    check((try? JSONDecoder().decode([ProtectionEvent].self, from: JSONEncoder().encode(monitor.timeline))) == monitor.timeline, "timeline events survive serialization")
    let oldJSON = Data(#"{"id":"00000000-0000-0000-0000-000000000001","date":1,"category":"Recording","detail":"Protection timeline enabled."}"#.utf8)
    check((try? JSONDecoder().decode(ProtectionEvent.self, from: oldJSON))?.location == nil, "existing timeline files decode without structured location fields")
    let oldDetail = "ipwho.is metadata: 192.0.2.1 | Sandefjord, Norway | AS56655 | Example Co. Ltd.. Your IP is in Norway, not blocked."
    let oldEvent = ProtectionEvent(category: "Location check", detail: oldDetail)
    check(oldEvent.locationDetails?.place == "Sandefjord, Norway" && oldEvent.locationDetails?.isp == "Example Co. Ltd."
          && oldEvent.locationDetails?.message == "Your IP is in Norway, not blocked.", "legacy timeline rows preserve provider names and verdicts while separating metadata")
    check(ProtectionEvent(category: "Location check", detail: "Location services did not answer.").locationDetails == nil, "unstructured timeline details remain intact")
    check(oldEvent.matches(query: "sandefjord", category: "Location check") && oldEvent.matches(query: "56655", category: ""), "timeline search matches places and ASN identifiers")
    check(!oldEvent.matches(query: "", category: "Firewall") && !oldEvent.matches(query: "absent", category: ""), "timeline category and text filters exclude nonmatching events")
    let structured = ProtectionEvent(category: "Location check", detail: "original", location: TimelineLocation(place: "Lisbon, Portugal", source: "ipwho.is", message: "Allowed."))
    check((try? JSONDecoder().decode(ProtectionEvent.self, from: JSONEncoder().encode(structured))) == structured, "structured timeline metadata round-trips with missing optional network fields")
    monitor.clearTimeline()
    check(monitor.timeline.isEmpty, "clearing the timeline removes recorded events")

    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let first = HistoryEntry(ts: 200_000_000, ip: "192.0.2.1", countryCode: "NO", country: "Norway", city: "Sandefjord", isp: "Example", status: .safe)
    var duplicate = first; duplicate.ts -= 1_000
    var changed = duplicate; changed.ts -= 1_000; changed.ip = "192.0.2.2"
    let grouped = activityGroups([first, duplicate, changed], calendar: calendar)
    check(grouped.count == 2 && grouped[0].entries.count == 2, "activity groups only consecutive identical connection details")
    check(grouped.flatMap(\.entries).map(\.id) == [first, duplicate, changed].map(\.id), "activity grouping preserves every entry and its order")
    for field in ["status", "provider", "day", "vpn"] {
        var different = duplicate
        switch field {
        case "status": different.status = .unknown
        case "provider": different.isp = "Another provider"
        case "day": different.ts -= 86_400_000
        default: different.isVpn = true
        }
        check(activityGroups([first, different], calendar: calendar).count == 2, "activity preserves changes in \(field)")
    }
    check(activityGroups([], calendar: calendar).isEmpty, "empty activity has no groups")

    let leaks = Monitor(settings: AppSettings(), history: [], testing: true)
    var probes = 0
    leaks.leakProbe = { baseline in
        probes += 1
        if probes == 1 { leaks.geo.location = exit }
        return LeakStatus(udp: ExitCheck(state: baseline == nil ? .unknown : .ok, message: "probe \(probes)"))
    }
    await leaks.checkLeaks()
    check(probes == 2 && leaks.leak.udp.state == .ok, "leak checks retry instead of publishing an obsolete IPv4 baseline")
    probes = 0
    leaks.leakProbe = { _ in
        probes += 1
        if probes == 1 { await leaks.checkLeaks(); await leaks.checkLeaks() }
        return LeakStatus(udp: ExitCheck(state: .ok, message: "probe \(probes)"))
    }
    await leaks.checkLeaks()
    check(probes == 2 && leaks.leak.udp.message == "probe 2", "overlapping leak checks coalesce into one fresh probe")
    probes = 0
    leaks.leakProbe = { _ in
        probes += 1
        if probes == 1 { leaks.markChecking() }
        return LeakStatus(udp: ExitCheck(state: .ok, message: "probe \(probes)"))
    }
    await leaks.checkLeaks()
    check(probes == 2 && !leaks.leakInFlight, "route changes invalidate in-flight leak probes and release the check lock")

    let failure = Monitor(settings: settings, history: [], testing: true)
    failure.verificationFirewall = { _ in throw ShellError(status: 1, output: "old helper") }
    failure.firewall = { commands.append($0); return "active" }
    await failure.reconcileProtection()
    check(failure.kill.active && !failure.kill.held && failure.kill.error != nil, "failed verification setup fails closed with a visible error")
    let sleeping = Monitor(settings: settings, history: [], testing: true)
    var strictSleep = false, permissiveSleep = false
    sleeping.strictSleepFirewall = { _ in strictSleep = true }
    sleeping.holdFirewall = { _ in permissiveSleep = true }
    sleeping.holdForSleep()
    check(strictSleep && !permissiveSleep && sleeping.kill.held, "strict sleep never uses the permissive VPN hold, even when the separate sleep toggle is off")
    var off = settings
    off.strictProtection = false
    check(ProtectionState.action(settings: off, geo: GeoStatus(), site: SiteWatchStatus(), kill: KillSwitchStatus(), paused: false) == .none,
          "strict mode disabled does not restrict an unknown connection")
    check(ProtectionState.action(settings: settings, geo: GeoStatus(), site: SiteWatchStatus(), kill: KillSwitchStatus(), paused: true) == .none,
          "paused monitoring suppresses strict mode")
    check(ProtectionState.action(settings: settings, geo: GeoStatus(kind: .safe, location: exit), site: SiteWatchStatus(),
                                 kill: KillSwitchStatus(active: true, held: true), paused: true) == .releaseHold,
          "a pause still lets an allowed check end a hold")
    check(ProtectionState.action(settings: settings, geo: GeoStatus(kind: .violation, location: exit, confirmed: true), site: SiteWatchStatus(),
                                 kill: KillSwitchStatus(active: true, held: true), paused: true) == .none,
          "a pause never turns a hold into a block")

    let toggled = Monitor(settings: settings, history: [], testing: true)
    toggled.verificationFirewall = { _ in }
    toggled.firewall = { _ in "inactive" }
    var pending: CheckedContinuation<[String], Never>?
    toggled.verificationAddresses = { _ in await withCheckedContinuation { pending = $0 } }
    let setup = Task { await toggled.reconcileProtection() }
    while pending == nil { await Task.yield() }
    toggled.update { $0.strictProtection = false }
    await toggled.reconcileStrictSetting()
    check(!toggled.kill.active, "disabling strict protection releases it without waiting for slow DNS discovery")
    pending?.resume(returning: ["192.0.2.10"])
    await setup.value
    check(!toggled.kill.active, "cancelled discovery cannot restore a disabled verification hold")

    let fm = FileManager.default
    let root = fm.temporaryDirectory.appending(path: "Whereabouts-firewall-test-\(UUID().uuidString)")
    do {
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let rules = root.appending(path: "rules")
        let stub = root.appending(path: "pfctl")
        // pf is on only once it has been asked to be, as after a boot.
        let enabled = root.appending(path: "enabled")
        let token = root.appending(path: "token")
        let script = """
        #!/bin/bash
        case "$*" in
          '-s rules') echo 'anchor "com.apple/*"' ;;
          '-s info') if [ -f \(Privileged.q(enabled.path)) ]; then echo 'Status: Enabled'; else echo 'Status: Disabled'; fi ;;
          '-E') touch \(Privileged.q(enabled.path)); echo 'Token : fixture' ;;
          *'-f -') cat > \(Privileged.q(rules.path)) ;;
          *'-s rules') cat \(Privileged.q(rules.path)) ;;
        esac
        exit 0
        """
        try script.write(to: stub, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: stub.path)
        let helper = root.appending(path: "helper.sh")
        let content = KillSwitch.helperScript.replacingOccurrences(of: "PFCTL=/sbin/pfctl", with: "PFCTL=\(Privileged.q(stub.path))")
            .replacingOccurrences(of: Privileged.q(KillSwitch.tokenFile), with: Privileged.q(token.path))
        try content.write(to: helper, atomically: true, encoding: .utf8)
        _ = try await run("/bin/bash", [helper.path, "verify", "192.0.2.20", "dns:1.1.1.1", "vpn:198.51.100.1"])
        let emitted = try String(contentsOf: rules, encoding: .utf8)
        _ = try await run("/sbin/pfctl", ["-n", "-f", rules.path])
        check(true, "macOS accepts the full strict ruleset in no-action mode")
        check(!emitted.contains("pass quick on {") && emitted.contains("to 192.0.2.20 port 443") && emitted.contains("to 1.1.1.1 port 53"),
              "strict firewall permits verification ports without a blanket tunnel bypass")
        check(emitted.contains("from any to 198.51.100.1 flags any") && emitted.contains("block drop quick all"), "strict firewall allows known VPN peers and drops other internet traffic")
        let state = try await run("/bin/bash", [helper.path, "status"])
        check(state.trimmingCharacters(in: .whitespacesAndNewlines) == "verifying", "the helper identifies a verification hold after an app restart")
        _ = try await run("/bin/bash", [helper.path, "hold", "192.0.2.20"])
        check(try String(contentsOf: rules, encoding: .utf8).contains("pass quick on {"), "ordinary sleep holds retain their existing tunnel behavior")
        check((try? String(contentsOf: token, encoding: .utf8)) == "fixture\n", "pf is asked for one reference while it stays on")
        // A reboot or power loss while blocked: pf is off again, and the token file is still there.
        try fm.removeItem(at: enabled)
        let blockedAgain = (try? await run("/bin/bash", [helper.path, "engage"])) != nil
        check(blockedAgain && fm.fileExists(atPath: enabled.path), "a token left by an earlier boot doesn't stop the next block")
        _ = try await run("/bin/bash", [helper.path, "release"])
        check(!fm.fileExists(atPath: token.path), "release drops every reference it took")
    } catch { check(false, "firewall rule fixture failed: \(error)") }
}
