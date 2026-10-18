import AppKit
import Network
import SwiftUI
import Observation
import ServiceManagement
import UserNotifications

/// All app state plus the monitoring loops. Views and the menu bar observe it directly.
@MainActor @Observable
final class Monitor {
    private(set) var settings: AppSettings
    var geo = GeoStatus()
    var reach: [ReachResult] = []
    var site = SiteWatchStatus()
    var leak = LeakStatus()
    var kill = KillSwitchStatus()
    private(set) var history: [HistoryEntry]
    private(set) var isCheckingAll = false
    var systemTimeZone = TimeZone.current.identifier
    var timeZoneError: String?

    var leaking: Bool { leak.ipv6.state == .leak || leak.dns.state == .leak }
    var edgeLineVisible: Bool {
        (settings.alerts.edgeLine && geo.kind == .violation)
            || (site.state == .mismatch && site.rule?.edgeLine == true)
    }

    // Loop bookkeeping — not UI state.
    @ObservationIgnored var geoInFlight = false
    @ObservationIgnored var geoRecheckQueued = false
    @ObservationIgnored var reachInFlight = false
    @ObservationIgnored var siteInFlight = false
    @ObservationIgnored var leakInFlight = false
    @ObservationIgnored var killInFlight = false
    @ObservationIgnored var timeZoneInFlight = false
    @ObservationIgnored var killActivation = 0
    @ObservationIgnored var triggerStates: [String: TriggerState] = [:]
    @ObservationIgnored var siteAlertKey: String?
    @ObservationIgnored var leakAlertKey: String?
    @ObservationIgnored var warningAlertKinds: Set<ConsistencyKind> = []
    @ObservationIgnored private var prevKind: GeoKind?
    @ObservationIgnored private var prevCode: String?
    @ObservationIgnored private var prevIsp: String?
    @ObservationIgnored private var unknownStreak = 0
    /// A violation the cross-check disputed: the kill switch waits one more check.
    @ObservationIgnored private var killDeferred = false
    @ObservationIgnored private var geoTask: Task<Void, Never>?
    @ObservationIgnored private var reachTask: Task<Void, Never>?
    @ObservationIgnored private var siteTask: Task<Void, Never>?
    @ObservationIgnored private var leakTask: Task<Void, Never>?
    @ObservationIgnored private var wakeTask: Task<Void, Never>?
    @ObservationIgnored private var netDebounce: Task<Void, Never>?
    @ObservationIgnored private var pathMonitor: NWPathMonitor?
    @ObservationIgnored private var pathSatisfied = true
    @ObservationIgnored private var pathSeen = false

    init() {
        settings = Demo.enabled ? Demo.settings : Store.loadSettings()
        history = Demo.enabled ? Demo.history : Store.loadHistory()
        // Restore the last outcome so a relaunch doesn't look like a country change.
        if let last = history.first {
            prevKind = GeoKind(rawValue: last.status.rawValue)
            prevCode = last.countryCode
            prevIsp = last.isp
        }
    }

    func start() {
        if Demo.enabled { Demo.apply(to: self); return }
        syncLoginItem()
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        Task { await refreshKillSwitchState() }
        startGeoLoop()
        startReachLoop()
        siteTask = loop(every: 5) { await $0.checkSite() }
        startLeakLoop()
        startNetworkWatch()
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.recheckConnectivity() }
        }
        NotificationCenter.default.addObserver(forName: .NSSystemTimeZoneDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshSystemTimeZone() }
        }
    }

    // MARK: Settings

    func binding<T>(_ path: WritableKeyPath<AppSettings, T>) -> Binding<T> {
        Binding(get: { self.settings[keyPath: path] }, set: { value in self.update { $0[keyPath: path] = value } })
    }

    func update(_ change: (inout AppSettings) -> Void) {
        let old = settings
        var next = settings
        change(&next)
        next.normalize()
        guard next != old else { return }
        settings = next
        if Demo.enabled { return }
        Store.save(next)

        // Restart only what the change affects — every geo restart is a provider call.
        let interval = old.intervalMs != next.intervalMs
        if old.launchAtLogin != next.launchAtLogin { syncLoginItem() }
        if interval || old.ruleMode != next.ruleMode || old.countries != next.countries
            || old.ispMode != next.ispMode || old.expectedIsps != next.expectedIsps {
            startGeoLoop()
        }
        if old.domains != next.domains {
            // Show the edit now: a probe still in flight holds the old list for up to 8 s,
            // which made a removed host look impossible to remove.
            let hosts = next.domains.compactMap(normalizeDomain)
            reach = hosts.map { host in reach.first { $0.host == host } ?? ReachResult(host: host) }
        }
        if interval || old.domains != next.domains { startReachLoop() }
        if old.browserWatch != next.browserWatch || old.siteRules != next.siteRules {
            Task { await checkSite() }
        }
        if interval || old.ipv6Check != next.ipv6Check || old.dnsCheck != next.dnsCheck { startLeakLoop() }
        if next.matchTimeZone && (!old.matchTimeZone || old.homeTimeZone != next.homeTimeZone) {
            Task { await syncTimeZone() }
        }
    }

    private func syncLoginItem() {
        do {
            if settings.launchAtLogin { try SMAppService.mainApp.register() }
            else if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
        } catch {
            log.error("Login item sync failed: \(error.localizedDescription)")
        }
    }

    func clearHistory() {
        history = []
        Store.save(history)
    }

    // MARK: Loops

    private func loop(every seconds: Double, delay: Double = 0, _ body: @escaping (Monitor) async -> Void) -> Task<Void, Never> {
        Task { [weak self] in
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            while !Task.isCancelled {
                guard let self else { return }
                await body(self)
                try? await Task.sleep(for: .seconds(seconds))
            }
        }
    }

    private var intervalSeconds: Double { Double(settings.intervalMs) / 1000 }

    private func startGeoLoop() {
        geoTask?.cancel()
        geoTask = loop(every: intervalSeconds) { _ = await $0.checkGeo() }
    }

    private func startReachLoop() {
        reachTask?.cancel()
        reachTask = loop(every: intervalSeconds) { await $0.checkReach() }
    }

    func checkAll() async {
        isCheckingAll = true
        defer { isCheckingAll = false }
        // The leak checks compare against the IPv4 exit, so refresh that first.
        _ = await checkGeo()
        async let r: Void = checkReach()
        async let s: Void = checkSite()
        async let l: Void = checkLeaks()
        _ = await (r, s, l)
    }

    /// VPN connect/disconnect or Wi-Fi switch. NWPathMonitor reports the change;
    /// a short debounce absorbs the burst of updates one switch produces.
    private func startNetworkWatch() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            Task { @MainActor in
                guard let self else { return }
                self.pathSatisfied = satisfied
                guard self.pathSeen else { self.pathSeen = true; return }
                self.netDebounce?.cancel()
                self.netDebounce = Task {
                    try? await Task.sleep(for: .seconds(1))
                    guard !Task.isCancelled else { return }
                    log.info("Network change — re-checking")
                    self.recheckConnectivity()
                }
            }
        }
        monitor.start(queue: DispatchQueue(label: "path-monitor"))
        pathMonitor = monitor
    }

    /// After wake or a network change the link takes a moment, so retry with backoff
    /// until a real answer arrives, then re-probe reachability and leaks — doing that
    /// mid-reconnect would raise false "host blocked" alerts.
    func recheckConnectivity() {
        wakeTask?.cancel()
        wakeTask = Task {
            for delay in [0.0, 2, 5, 10, 20] {
                if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
                if Task.isCancelled { return }
                let status = await checkGeo()
                if status.kind != .unknown && status.kind != .offline {
                    async let r: Void = checkReach()
                    async let l: Void = checkLeaks()
                    _ = await (r, l)
                    return
                }
            }
        }
    }

    // MARK: Alerts

    func notify(_ title: String, _ body: String, sound: Bool = false) {
        if Demo.enabled { return }
        if sound && settings.alerts.sound { NSSound.beep() }
        guard settings.alerts.notifications else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    // MARK: Geo

    /// One location check: evaluate, record history, alert, maybe engage the kill switch.
    @discardableResult
    func checkGeo() async -> GeoStatus {
        if geoInFlight { geoRecheckQueued = true; return geo }
        geoInFlight = true
        defer {
            geoInFlight = false
            if geoRecheckQueued { geoRecheckQueued = false; Task { await checkGeo() } }
        }

        var status: GeoStatus
        if let (location, source) = await lookupLocation() {
            let verdict = evaluateLocation(location, settings)
            let vpnName = await activeVpnName()
            // A single bad provider response must not be able to cut the network.
            var confirmed: Bool?
            if verdict.kind == .violation, let reason = verdict.reason, settings.confirmViolations {
                confirmed = await confirmViolation(location, source: source, reason: reason)
            }
            status = GeoStatus(kind: verdict.kind, location: location, checkedAt: Date(),
                               message: confirmed == false ? verdict.message + " Not confirmed — the second provider disagrees." : verdict.message,
                               confirmed: confirmed, vpnName: vpnName)
        } else {
            // "No route out" vs "the provider is broken": addresses survive sleep and
            // VPN transitions, so only a real probe can tell them apart.
            var offline = !pathSatisfied
            if !offline { offline = !(await anyReachable()) }
            status = GeoStatus(kind: offline ? .offline : .unknown, checkedAt: Date(),
                               message: offline ? "No internet connection." : "Unable to check your location (provider unavailable).")
        }
        geo = status

        let code = status.location?.countryCode
        let isp = status.location?.isp
        let becameViolation = status.kind == .violation && prevKind != .violation
        let recovered = status.kind == .safe && prevKind == .violation
        // Same country, new provider: invisible to the country rule, and exactly what a silent VPN drop looks like.
        let ispChangedTo = settings.alertOnIspChange && isp != nil && prevIsp != nil && isp != prevIsp ? isp : nil

        // One failed lookup is nearly always a blip; log it only once it persists.
        unknownStreak = status.kind == .unknown ? unknownStreak + 1 : 0
        let changed = status.kind != prevKind || code != prevCode
        let loggable = switch status.kind {
        case .safe, .violation: changed
        case .unknown: unknownStreak == 2
        case .offline, .checking: false
        }
        if loggable {
            let entry = HistoryEntry(ts: Date().timeIntervalSince1970 * 1000, ip: status.location?.ip, countryCode: code,
                                     country: status.location?.country, city: status.location?.city, isp: isp,
                                     isVpn: status.location?.isVpn, status: HistoryStatus(rawValue: status.kind.rawValue) ?? .unknown)
            history.insert(entry, at: 0)
            if history.count > Store.maxHistory { history.removeLast(history.count - Store.maxHistory) }
            Store.save(history)
        }

        // Only a real "safe" is clear — offline is exactly what an engaged block looks like.
        reportTriggerState("geo", status.kind == .violation ? .violating : status.kind == .safe ? .clear : .unknown)
        fireGeoAlerts(status, becameViolation: becameViolation, recovered: recovered, ispChangedTo: ispChangedTo)
        if settings.matchTimeZone { Task { await syncTimeZone() } }
        prevKind = status.kind
        prevCode = code
        if let isp { prevIsp = isp }
        return status
    }

    private func lookupLocation() async -> (Location, Provider)? {
        if let l = try? await fetchIpApi() { return (l, .ipApi) }
        if let l = try? await fetchIpWho() { return (l, .ipWho) }
        // Both can fail on the same blip; one more shot beats flashing "unknown".
        if let l = try? await fetchIpApi() { return (l, .ipApi) }
        return nil
    }

    /// Country agreement settles a country violation; a provider violation also needs
    /// the other provider to report a non-matching ISP.
    private func confirmViolation(_ primary: Location, source: Provider, reason: ViolationReason) async -> Bool {
        guard let second = try? await fetch(source == .ipApi ? .ipWho : .ipApi),
              second.countryCode == primary.countryCode else { return false }
        if reason == .isp {
            guard let isp = second.isp else { return false }
            return !ispMatches(isp, settings.expectedIsps)
        }
        return true
    }

    private func fireGeoAlerts(_ status: GeoStatus, becameViolation: Bool, recovered: Bool, ispChangedTo: String?) {
        if status.kind != .violation { killDeferred = false }

        if becameViolation {
            notify("Location alert", status.message, sound: true)
        } else if recovered {
            notify("Back to safe", status.message)
        } else if let isp = ispChangedTo {
            notify("Provider changed", "You're now connected through \(isp).")
        }

        guard settings.killSwitch, status.kind == .violation else { return }
        if killDeferred {
            // Two checks in a row agree — as good as a second provider.
            killDeferred = false
            Task { await activateKillSwitch(status.message) }
        } else if becameViolation {
            if status.confirmed == false {
                killDeferred = true
                log.warning("Violation unconfirmed by the cross-check — holding the kill switch")
            } else {
                Task { await activateKillSwitch(status.message) }
            }
        }
    }

    // MARK: Reachability

    func checkReach() async {
        guard !reachInFlight else { return }
        reachInFlight = true
        defer { reachInFlight = false }

        let hosts = settings.domains.compactMap(normalizeDomain)
        let previous = Dictionary(reach.map { ($0.host, $0) }, uniquingKeysWith: { a, _ in a })
        reach = hosts.map { previous[$0] ?? ReachResult(host: $0) }

        let results = await withTaskGroup(of: ReachResult.self) { group in
            for host in hosts {
                group.addTask {
                    for port: UInt16 in [443, 80] {
                        if let ms = await tcpProbe(host, port, timeout: 4) { return ReachResult(host: host, status: .reachable, latencyMs: ms) }
                    }
                    return ReachResult(host: host, status: .blocked)
                }
            }
            return await group.reduce(into: [String: ReachResult]()) { $0[$1.host] = $1 }
        }
        // Domains may have changed while probing; keep the current list's order.
        reach = settings.domains.compactMap(normalizeDomain).map { results[$0] ?? ReachResult(host: $0) }

        for result in reach {
            guard let prev = previous[result.host]?.status, prev != .checking, prev != result.status else { continue }
            if result.status == .blocked { notify("Host unreachable", "\(result.host) is now blocked or unreachable.") }
            if result.status == .reachable { notify("Host reachable", "\(result.host) is reachable again.") }
        }
    }

    // MARK: Leak loop

    private func startLeakLoop() {
        leakTask?.cancel()
        guard settings.ipv6Check || settings.dnsCheck else {
            leak = LeakStatus(ipv6: Ipv6Check(state: .off, message: "IPv6 leak check is off."),
                              dns: DnsCheck(state: .off, message: "DNS leak check is off."), checkedAt: leak.checkedAt)
            leakAlertKey = nil
            return
        }
        // A short head start lets the first IPv4 result land as the baseline.
        leakTask = loop(every: max(intervalSeconds, 60), delay: 4) { await $0.checkLeaks() }
    }
}

// MARK: - Rule evaluation (pure)

enum ViolationReason { case country, isp }

struct Verdict {
    var kind: GeoKind
    var message: String
    var reason: ViolationReason?
}

func evaluateLocation(_ location: Location, _ settings: AppSettings) -> Verdict {
    guard let code = location.countryCode else {
        return Verdict(kind: .unknown, message: "Could not determine your country.")
    }
    let listed = settings.countries.contains(code)
    let place = location.place
    let blocklist = settings.ruleMode == .blocklist

    if blocklist ? listed : !listed {
        return Verdict(kind: .violation,
                       message: blocklist ? "Your IP is in a blocked country: \(place)." : "Your IP is outside your allowed countries: \(place).",
                       reason: .country)
    }
    // A dropped VPN often reconnects through a local ISP in the same country. An
    // unidentified provider is never a violation — a missing field must not cut the network.
    if settings.ispMode == .allowlist, !settings.expectedIsps.isEmpty, let isp = location.isp,
       !ispMatches(isp, settings.expectedIsps) {
        return Verdict(kind: .violation, message: "Unexpected provider: \(isp) in \(place) isn't one you expect.", reason: .isp)
    }
    return Verdict(kind: .safe, message: blocklist ? "Your IP is in \(place) — not blocked." : "Your IP is in an allowed country: \(place).")
}
