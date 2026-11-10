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
    /// The last site read from a browser tab. `site.host` clears once Settings is in front; this is what Settings offers.
    var lastSiteHost: String?
    var leak = LeakStatus()
    var kill = KillSwitchStatus()
    private(set) var history: [HistoryEntry]
    var timeline: [ProtectionEvent]
    private(set) var isCheckingAll = false
    /// A newer GitHub release than this build, if update checks are on.
    private(set) var latestRelease: Release?
    private(set) var installingUpdate = false
    /// When GitHub last answered an update check.
    private(set) var lastUpdateCheck: Date?
    /// Alerts and the kill switch stand down until then, for turning the VPN off on purpose.
    private(set) var pausedUntil: Date?
    var systemTimeZone = TimeZone.current.identifier
    var timeZoneError: String?
    var computerName = ComputerName.current()
    var renameError: String?
    /// Alibi's All sites cover, as its host last heard it.
    var alibiWish: AlibiWish?
    /// The place the Mac's clock follows: Alibi's, with Match time zone and Follow Alibi's location on.
    var alibiPlace: AlibiWish? { followedPlace(alibiWish, settings) }

    var leaking: Bool { leak.ipv6.state == .leak || leak.udp.state == .leak || leak.dns.state == .leak }
    var edgeLineVisible: Bool {
        pausedUntil == nil && ((settings.alerts.edgeLine && geo.kind == .violation)
            || (site.state == .mismatch && site.rule?.edgeLine == true))
    }

    // Loop bookkeeping — not UI state.
    @ObservationIgnored var geoInFlight = false
    @ObservationIgnored var geoRecheckQueued = false
    @ObservationIgnored private var geoWaiters: [CheckedContinuation<GeoStatus, Never>] = []
    @ObservationIgnored var reachInFlight = false
    @ObservationIgnored var siteInFlight = false
    @ObservationIgnored var leakInFlight = false
    @ObservationIgnored var leakRecheckQueued = false
    @ObservationIgnored var leakProbe: ((Location?) async -> LeakStatus)?
    @ObservationIgnored var killInFlight = false
    @ObservationIgnored var timeZoneInFlight = false
    /// Apps on the home-time list being quit and reopened now, by bundle ID.
    @ObservationIgnored var homeTimeReopening: Set<String> = []
    /// The copy of each app this app opened on home time, by bundle ID.
    @ObservationIgnored var homeTimeOpened: [String: pid_t] = [:]
    @ObservationIgnored var killActivation = 0
    @ObservationIgnored var triggerStates: [String: TriggerState] = [:]
    @ObservationIgnored var siteAlertKey: String?
    @ObservationIgnored var leakAlertKey: String?
    @ObservationIgnored var warningAlertKinds: Set<ConsistencyKind> = []
    @ObservationIgnored private var prevKind: GeoKind?
    @ObservationIgnored private var prevCode: String?
    @ObservationIgnored private var prevIsp: String?
    @ObservationIgnored private var prevAsn: Int?
    @ObservationIgnored private var unknownStreak = 0
    @ObservationIgnored private var protection = ProtectionState()
    /// The browser whose tab couldn't be read, and that result, so the site watch doesn't ask again right away.
    @ObservationIgnored var unreadableTab: (pid: pid_t, at: Date, status: SiteWatchStatus)?
    @ObservationIgnored private var vpnLookup: (interfaces: [String], name: String?)?
    @ObservationIgnored private var lastLeakCheck: ContinuousClock.Instant?
    @ObservationIgnored private var diagnosticsTask: Task<Void, Never>?
    @ObservationIgnored private var checkTask: Task<Void, Never>?
    @ObservationIgnored private var siteTask: Task<Void, Never>?
    @ObservationIgnored private var wakeTask: Task<Void, Never>?
    @ObservationIgnored private var pauseTask: Task<Void, Never>?
    @ObservationIgnored var reblockTask: Task<Void, Never>?
    @ObservationIgnored private var netDebounce: Task<Void, Never>?
    @ObservationIgnored private var wishWatch: DispatchSourceFileSystemObject?
    @ObservationIgnored private var launchWatch: NSKeyValueObservation?
    @ObservationIgnored private var pathMonitor: NWPathMonitor?
    @ObservationIgnored private var pathSatisfied = true
    @ObservationIgnored private var pathRoute: String?
    /// Bumped on each network change or wake, so a check that straddles one isn't published as current.
    @ObservationIgnored private(set) var pathChanges = 0
    @ObservationIgnored var lookup: () async -> (Location, Provider)? = lookupExit
    @ObservationIgnored var firewall: (String) async throws -> String = { try await KillSwitch.sudoHelper($0) }
    @ObservationIgnored var holdFirewall: ([String]) throws -> Void = { addresses in
        _ = try runSync("/usr/bin/sudo", ["-n", KillSwitch.helperPath, "hold"] + addresses, timeout: 5)
    }
    @ObservationIgnored var verificationFirewall: ([String]) async throws -> Void = { addresses in
        _ = try await run("/usr/bin/sudo", ["-n", KillSwitch.helperPath, "verify"] + addresses, timeout: 5)
    }
    @ObservationIgnored var strictSleepFirewall: ([String]) throws -> Void = { addresses in
        _ = try runSync("/usr/bin/sudo", ["-n", KillSwitch.helperPath, "verify"] + addresses, timeout: 5)
    }
    @ObservationIgnored var verificationTask: Task<Void, Never>?
    @ObservationIgnored var verificationGeneration: Int?
    @ObservationIgnored var verificationAddresses: (Bool) async -> [String] = { dnsOnly in
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: dnsOnly ? KillSwitch.dnsAddresses() : KillSwitch.holdAddresses(strict: true))
            }
        }
    }
    @ObservationIgnored var confirm: (Location, Provider, ViolationReason, AppSettings) async -> Bool = confirmLocationViolation
    @ObservationIgnored let testing: Bool
    @ObservationIgnored var preparedHoldAddresses: [String] = []
    @ObservationIgnored private var holdPreparationTask: Task<Void, Never>?

    init(settings: AppSettings? = nil, history: [HistoryEntry]? = nil, testing: Bool = false) {
        self.testing = testing
        self.settings = settings ?? (Demo.enabled ? Demo.settings : Store.loadSettings())
        self.history = history ?? (Demo.enabled ? Demo.history : Store.loadHistory())
        timeline = testing || Demo.enabled ? [] : Store.loadTimeline()
        alibiWish = testing || Demo.enabled ? nil : AlibiHost.readWish()
        // Restore the last outcome so a relaunch doesn't look like a country change.
        if let last = self.history.first {
            prevKind = GeoKind(rawValue: last.status.rawValue)
            prevCode = last.countryCode
            prevIsp = last.isp
        }
    }

    func start() {
        if Demo.enabled { Demo.apply(to: self); return }
        AlibiHost.install()
        AlibiHost.announce()
        watchAlibiWish()
        syncLoginItem()
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        Task {
            await refreshKillSwitchState()
            recordProtection("Connection", "Monitoring started.")
            await reconcileProtection()
            startChecks()
        }
        siteTask = loop(every: 5) { await $0.checkSite() }
        startNetworkWatch()
        prepareSleepHold()
        _ = loop(every: 86_400, delay: 30) { await $0.checkForUpdate() }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.holdForSleep() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.markChecking("Mac woke from sleep."); self?.recheckConnectivity() }
        }
        NotificationCenter.default.addObserver(forName: .NSSystemTimeZoneDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshSystemTimeZone() }
        }
        // Not didLaunchApplicationNotification: it skips menu-bar apps (LSUIElement), and this list doesn't.
        launchWatch = NSWorkspace.shared.observe(\.runningApplications, options: [.new]) { [weak self] _, change in
            guard change.kind == .insertion, let apps = change.newValue else { return }
            Task { @MainActor in for app in apps { await self?.keepOnHomeTime(app, justLaunched: true) } }
        }
        keepAppsOnHomeTime()
        // A new frontmost app gets its tab read now, not at the next poll.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.unreadableTab = nil
                Task { await self?.checkSite() }
            }
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
        let rulesChanged = old.ruleMode != next.ruleMode || old.countries != next.countries
            || old.ispMode != next.ispMode || old.expectedIsps != next.expectedIsps || old.confirmViolations != next.confirmViolations
            || old.connectionProfilesEnabled != next.connectionProfilesEnabled || old.activeProfile != next.activeProfile
        if old.protectionTimeline != next.protectionTimeline { recordProtection("Recording", "Protection timeline enabled.") }
        if rulesChanged { markChecking("Location rules changed.") }
        if testing { return }
        Store.save(next)
        if old.strictProtection != next.strictProtection {
            recordProtection("Settings", "Strict protection \(next.strictProtection ? "enabled" : "disabled").")
            Task {
                await reconcileStrictSetting()
                await checkGeo()
            }
        }

        // Re-run only what the change affects — every geo check is a provider call.
        // A new interval restarts the timer, which runs every check at once.
        let interval = old.intervalMs != next.intervalMs
        if old.launchAtLogin != next.launchAtLogin { syncLoginItem() }
        if interval { startChecks() }
        if !interval && rulesChanged {
            // markChecking cleared the leak results too, and they read the provider rule.
            Task { await checkGeo(); await checkLeaks() }
        }
        if old.domains != next.domains {
            // Show the edit now: a probe still in flight holds the old list for up to 8 s,
            // which made a removed host look impossible to remove.
            let hosts = next.domains.compactMap(normalizeDomain)
            reach = hosts.map { host in reach.first { $0.host == host } ?? ReachResult(host: host) }
            if !interval { Task { await checkReach() } }
        }
        if old.browserWatch != next.browserWatch || old.siteRules != next.siteRules {
            site = SiteWatchStatus()
            Task { await checkSite() }
        }
        if old.holdOnWake != next.holdOnWake || old.killSwitch != next.killSwitch || old.strictProtection != next.strictProtection { prepareSleepHold() }
        if !interval && (old.ipv6Check != next.ipv6Check || old.udpCheck != next.udpCheck || old.dnsCheck != next.dnsCheck) { Task { await checkLeaks() } }
        if next.matchTimeZone && (!old.matchTimeZone || old.homeTimeZone != next.homeTimeZone || old.homeRegion != next.homeRegion
            || old.followAlibi != next.followAlibi) {
            Task { await syncTimeZone() }
        }
        if next.matchTimeZone && (!old.matchTimeZone || old.homeTimeZone != next.homeTimeZone || old.homeTimeApps != next.homeTimeApps) {
            keepAppsOnHomeTime()
        }
        if old.checkUpdates != next.checkUpdates || old.installUpdates != next.installUpdates { Task { await checkForUpdate() } }
        // Turned on: a fresh check writes the file, rather than an answer that may predate a network change.
        if old.shareStatus != next.shareStatus {
            if next.shareStatus { Task { await checkGeo() } } else { StatusFile.remove() }
        }
    }

    /// Alibi's host keeps the All sites cover in the app's folder. Atomic writes swap the file, so
    /// watch the folder; other files there change too, and an unchanged cover is ignored.
    private func watchAlibiWish() {
        try? FileManager.default.createDirectory(at: Store.dir, withIntermediateDirectories: true)
        let folder = open(Store.dir.path, O_EVTONLY)
        guard folder >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: folder, eventMask: .write, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.alibiWishChanged() }
        }
        source.setCancelHandler { close(folder) }
        source.resume()
        wishWatch = source
    }

    private func alibiWishChanged() {
        if rereadAlibiWish() && settings.matchTimeZone && settings.followAlibi { Task { await syncTimeZone() } }
    }

    /// Reads Alibi's cover from its hosts' files again, and says whether it changed. Each check does
    /// this too: a host Chrome killed outright leaves its file behind, and the folder doesn't change.
    @discardableResult
    func rereadAlibiWish() -> Bool {
        let wish = AlibiHost.readWish()
        guard wish != alibiWish else { return false }
        alibiWish = wish
        log.info("Alibi's location for all sites: \(wish?.zone ?? "none, so the connection's")")
        return true
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

    // MARK: Pause

    func pause(for seconds: Double = 3600) {
        pausedUntil = Date().addingTimeInterval(seconds)
        pauseTask?.cancel()
        pauseTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            if !Task.isCancelled { self?.resume() }
        }
    }

    func resume() {
        pauseTask?.cancel()
        pausedUntil = nil
        // Whatever went wrong during the pause was never announced or acted on, so treat it as new.
        treatViolationAsNew()
        siteAlertKey = nil
        leakAlertKey = nil
        Task { await checkAll() }
    }

    /// The next violating check counts as new: it alerts and can engage the kill switch again.
    func treatViolationAsNew() { if prevKind == .violation { prevKind = nil } }

    // MARK: Updates

    func checkForUpdate() async {
        guard settings.checkUpdates else { latestRelease = nil; return }
        guard await fetchLatestRelease(), latestRelease != nil, settings.installUpdates, canInstallUpdates else { return }
        // Never restart under the user's hands: wait until they're in another app.
        while NSApp.isActive { try? await Task.sleep(for: .seconds(60)) }
        if settings.checkUpdates && settings.installUpdates { await installUpdate() }
    }

    /// Asks GitHub for the latest release, without installing it. False if GitHub couldn't be reached.
    @discardableResult
    func fetchLatestRelease() async -> Bool {
        guard let json = try? await fetchJSON("https://api.github.com/repos/doxigo/whereabouts/releases/latest") else { return false }
        latestRelease = newerRelease(json, than: appVersion)
        lastUpdateCheck = Date()
        return true
    }

    /// Installs `latestRelease` and quits so the new copy opens. False if it couldn't,
    /// with this copy still in place.
    @discardableResult
    func installUpdate() async -> Bool {
        guard let release = latestRelease, !installingUpdate, canInstallUpdates else { return false }
        installingUpdate = true
        defer { installingUpdate = false }
        do {
            try await installRelease(release)
        } catch {
            log.error("Update to \(release.version) failed: \(error.localizedDescription)")
            return false
        }
        log.info("Updated to \(release.version) — relaunching")
        NSApp.terminate(nil)
        return true
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

    private func startChecks() {
        checkTask?.cancel()
        checkTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let start = ContinuousClock.now
                await runChecks()
                let elapsed = start.duration(to: .now)
                let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
                do { try await Task.sleep(for: .seconds(max(1, nextCheckDelay(interval: intervalSeconds, elapsed: seconds)))) }
                catch { return }
            }
        }
    }

    private func runChecks() async {
        refreshComputerName()
        // The leak checks compare against the IPv4 exit, so refresh that first.
        _ = await checkGeo()
        prepareSleepHold()
        guard !Task.isCancelled, diagnosticsTask == nil else { return }
        let leaksDue = lastLeakCheck.map { $0.duration(to: .now) >= .seconds(60) } ?? true
        if leaksDue { lastLeakCheck = .now }
        diagnosticsTask = Task {
            defer { diagnosticsTask = nil }
            async let r: Void = checkReach()
            if leaksDue { await checkLeaks() }
            await r
        }
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
            // Wi-Fi link quality is part of the path too, so it going good → moderate → good fires
            // updates on an unchanged route. Only these fields say where traffic goes.
            let route = "\(path.status) \(path.availableInterfaces.map(\.name)) \(path.gateways) \(path.supportsIPv4) \(path.supportsIPv6) \(path.supportsDNS)"
            Task { @MainActor in
                guard let self else { return }
                self.pathSatisfied = satisfied
                guard route != self.pathRoute else { return }
                defer { self.pathRoute = route }
                guard self.pathRoute != nil else { return }
                self.markChecking()
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

    /// The last answer may belong to the old route: status.json says "checking" until the
    /// re-check lands, so no reader acts on a stale "safe" after the VPN drops.
    func markChecking(_ reason: String = "Network route changed.") {
        pathChanges += 1
        protection.invalidate()
        vpnLookup = nil
        geo = GeoStatus(checkedAt: Date())
        site = settings.browserWatch ? SiteWatchStatus(state: .noLocation, message: "Waiting for your location…") : SiteWatchStatus()
        leak = LeakStatus()
        preparedHoldAddresses = []
        publishStatus(geo)
        recordProtection("Connection", reason)
        if !testing {
            prepareSleepHold()
            if settings.strictProtection { Task { await reconcileProtection() } }
        }
    }

    func prepareSleepHold() {
        guard !testing, !Demo.enabled, settings.killSwitch, settings.holdOnWake || settings.strictProtection, !kill.active,
              holdPreparationTask == nil else { return }
        let generation = pathChanges
        let strict = settings.strictProtection
        holdPreparationTask = Task {
            let addresses = await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .utility).async { continuation.resume(returning: KillSwitch.holdAddresses(strict: strict)) }
            }
            holdPreparationTask = nil
            if generation == pathChanges && strict == settings.strictProtection { preparedHoldAddresses = addresses }
            else { prepareSleepHold() }
        }
    }

    private func publishStatus(_ status: GeoStatus) {
        if !testing && settings.shareStatus { StatusFile.publish(status) }
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

    /// A new alert on the same `topic` (the title by default) replaces the old one in Notification Center.
    func notify(_ title: String, _ body: String, sound: Bool = false, topic: String? = nil) {
        if testing || Demo.enabled || pausedUntil != nil { return }
        if sound && settings.alerts.sound { NSSound.beep() }
        guard settings.alerts.notifications else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: topic ?? title, content: content, trigger: nil))
    }

    // MARK: Geo

    /// One location check: evaluate, record history, alert, maybe engage the kill switch.
    @discardableResult
    func checkGeo() async -> GeoStatus {
        if settings.strictProtection && geo.kind != .safe { await reconcileProtection() }
        await verificationTask?.value
        if geoInFlight {
            geoRecheckQueued = true
            return await withCheckedContinuation { geoWaiters.append($0) }
        }
        geoInFlight = true
        let pathAtStart = pathChanges
        defer {
            geoInFlight = false
            if geoRecheckQueued {
                geoRecheckQueued = false
                let waiters = geoWaiters
                geoWaiters = []
                Task {
                    let result = await checkGeo()
                    waiters.forEach { $0.resume(returning: result) }
                }
            }
        }

        var status: GeoStatus
        if let (location, source) = await lookup() {
            guard pathChanges == pathAtStart, !Task.isCancelled else { return geo }
            let verdict = evaluateLocation(location, settings)
            // Naming the VPN takes a process or two, and the answer only changes with the interfaces.
            let interfaces = ipv4InterfaceNames()
            if !testing && vpnLookup?.interfaces != interfaces {
                let name = await activeVpnName()
                guard pathChanges == pathAtStart, !Task.isCancelled else { return geo }
                vpnLookup = (interfaces, name)
            }
            let vpnName = vpnLookup?.name
            // A single bad provider response must not be able to cut the network.
            var confirmed: Bool?
            if verdict.kind == .violation, let reason = verdict.reason, settings.confirmViolations {
                confirmed = await confirm(location, source, reason, settings)
            }
            guard pathChanges == pathAtStart, !Task.isCancelled else { return geo }
            let identity = [location.ip, location.cityPlace, location.asn.map { "AS\($0)" }, location.isp].compactMap { $0 }.joined(separator: " | ")
            let provider = source.rawValue
            recordProtection("Location check", "\(provider) metadata: \(identity). \(verdict.message)",
                             location: TimelineLocation(place: location.cityPlace, ip: location.ip, asn: location.asn,
                                                        isp: location.isp, source: provider, message: verdict.message))
            if let confirmed {
                recordProtection("Confirmation", "Independent provider \(confirmed ? "confirmed" : "did not confirm") this violation for \(location.ip ?? "unknown IP").")
            }
            status = GeoStatus(kind: verdict.kind, location: location, checkedAt: Date(),
                               message: confirmed == false ? verdict.message + " The second provider did not confirm this result." : verdict.message,
                               confirmed: confirmed, vpnName: vpnName)
        } else if kill.active {
            guard pathChanges == pathAtStart, !Task.isCancelled else { return geo }
            // Our own block stops every lookup, so this failure says nothing new: keep
            // the last answer (and its check time) instead of calling the block "offline".
            recordProtection("Location check", "Location services did not answer while the firewall was active.")
            if kill.verifying { verificationGeneration = nil }
            if geo.location == nil {
                geo = GeoStatus(kind: .unknown, message: kill.held ? "Can't check your location yet after sleep. The network stays blocked until a check finds it allowed."
                                : "Can't check your location while the network is blocked.")
            }
            return geo
        } else {
            // "No route out" vs "the provider is broken": addresses survive sleep and
            // VPN transitions, so only a real probe can tell them apart.
            var offline = !pathSatisfied
            if !offline { offline = !(await anyReachable()) }
            status = GeoStatus(kind: offline ? .offline : .unknown, checkedAt: Date(),
                               message: offline ? "No internet connection." : "Unable to check your location (provider unavailable).")
        }
        guard pathChanges == pathAtStart, !Task.isCancelled else { return geo }
        if status.location == nil { recordProtection("Location check", status.message) }
        if status.confirmed == false && !testing { invalidateExitMetadata() }
        protection.accept(&status)
        if status.confirmed == true, let location = status.location { status.message = evaluateLocation(location, settings).message }
        geo = status
        if !testing, let location = status.location { AlibiHost.publish(location) }
        publishStatus(status)

        let code = status.location?.countryCode
        let isp = status.location?.isp
        let becameViolation = status.kind == .violation && prevKind != .violation
        let recovered = status.kind == .safe && prevKind == .violation
        // Same country, new provider: invisible to the country rule, and exactly what a silent VPN drop looks like.
        // A new name on the same AS number is the other lookup service naming it its own way.
        let asn = status.location?.asn
        let ispChangedTo = settings.alertOnIspChange && isp != nil && prevIsp != nil && isp != prevIsp && (asn == nil || asn != prevAsn) ? isp : nil

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
            if !testing { Store.save(history) }
        }

        // Only a real "safe" is clear — offline is exactly what an engaged block looks like.
        reportTriggerState("geo", status.kind == .violation ? .violating : status.kind == .safe ? .clear : .unknown)
        fireGeoAlerts(status, becameViolation: becameViolation, recovered: recovered, ispChangedTo: ispChangedTo)
        prevKind = status.kind
        prevCode = code
        if let isp { prevIsp = isp; prevAsn = asn }
        await reconcileProtection()
        guard pathChanges == pathAtStart else { return geo }
        if !testing {
            rereadAlibiWish()
            if settings.matchTimeZone { Task { await syncTimeZone() } }
        }
        return status
    }

    func reconcileProtection() async {
        switch ProtectionState.action(settings: settings, geo: geo, site: site, kill: kill, paused: pausedUntil != nil) {
        case .none: break
        case .block(let reason): await activateKillSwitch(reason)
        case .releaseHold: await releaseHold()
        case .verify: await engageVerificationHold()
        }
    }

    private func fireGeoAlerts(_ status: GeoStatus, becameViolation: Bool, recovered: Bool, ispChangedTo: String?) {
        if becameViolation {
            notify("Location not allowed", status.message, sound: true, topic: "geo")
        } else if recovered {
            notify("Location allowed again", status.message, topic: "geo")
        } else if let isp = ispChangedTo {
            notify("Provider changed", "You're now connected through \(isp).")
        }
    }

    // MARK: Reachability

    func checkReach() async {
        // A block makes every host unreachable, which says nothing about them.
        guard !reachInFlight, !kill.active else { return }
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
            if result.status == .blocked { notify("Host unreachable", "\(result.host) is now blocked or unreachable.", topic: "reach|\(result.host)") }
            if result.status == .reachable { notify("Host reachable", "\(result.host) is reachable again.", topic: "reach|\(result.host)") }
        }
        // A host added while this ran has no result yet: probe again (the task runs after `defer`
        // clears the flag), rather than leave it "checking" until the next interval.
        if reach.contains(where: { $0.status == .checking }) { Task { await checkReach() } }
    }
}

// MARK: - Rule evaluation (pure)

enum ViolationReason { case country, isp, profile }

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
    // An empty allowlist is no rule yet, not "everywhere is wrong": picking
    // Allowlist before adding a country must not cut the network.
    let unset = !blocklist && settings.countries.isEmpty

    if blocklist ? listed : (!listed && !unset) {
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
    if settings.connectionProfilesEnabled {
        guard let profile = settings.activeProfile else {
            return Verdict(kind: .unknown, message: "Choose an active connection profile in Location settings.")
        }
        return profileVerdict(location, profile)
    }
    return Verdict(kind: .safe, message: settings.countries.isEmpty ? "Your IP is in \(place). No countries are set yet."
                   : blocklist ? "Your IP is in \(place) — not blocked."
                   : "Your IP is in an allowed country: \(place).")
}
