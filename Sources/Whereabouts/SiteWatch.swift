import AppKit

// Per-site location rules: reads the frontmost browser's active tab and alerts
// when the IP location is wrong for that site (e.g. a bank that should only see one city).

private enum BrowserKind { case chromium, webkit, firefox }

// Keyed by lowercased app name. Chromium and WebKit browsers script their tabs;
// Firefox-family browsers don't, so they get a best-effort accessibility read.
private let browsers: [String: BrowserKind] = [
    "google chrome": .chromium, "google chrome canary": .chromium, "google chrome beta": .chromium,
    "google chrome dev": .chromium, "chromium": .chromium, "brave browser": .chromium,
    "brave browser beta": .chromium, "brave browser nightly": .chromium, "microsoft edge": .chromium,
    "microsoft edge beta": .chromium, "microsoft edge dev": .chromium, "microsoft edge canary": .chromium,
    "arc": .chromium, "dia": .chromium, "vivaldi": .chromium, "opera": .chromium, "opera gx": .chromium,
    "sidekick": .chromium, "yandex": .chromium,
    "safari": .webkit, "safari technology preview": .webkit, "orion": .webkit,
    "firefox": .firefox, "firefox developer edition": .firefox, "firefox nightly": .firefox,
    "librewolf": .firefox, "zen": .firefox, "zen browser": .firefox, "waterfox": .firefox,
    "tor browser": .firefox, "mullvad browser": .firefox,
]

/// Matches the rule's domain exactly or as a parent domain.
func matchRule(_ host: String, _ rules: [SiteRule]) -> SiteRule? {
    rules.filter { host == $0.domain || host.hasSuffix("." + $0.domain) }
        .max { $0.domain.count < $1.domain.count }
}

func locationSatisfies(_ location: Location, _ rule: SiteRule) -> Bool {
    rule.locations.contains { required in
        location.countryCode?.uppercased() == required.countryCode
            && (required.city.map { $0.lowercased() == location.city?.trimmingCharacters(in: .whitespaces).lowercased() } ?? true)
    }
}

func isAutomationDenied(_ error: Error) -> Bool {
    let text = "\(error)"
    return ["-1743", "Not authorized", "not allowed", "assistive access"].contains { text.contains($0) }
}

func runAppleScript(_ source: String, timeout: Int = 2) async throws -> String {
    let source = "with timeout of \(timeout) seconds\n\(source)\nend timeout"
    return try await run("/usr/bin/osascript", ["-e", source], timeout: Double(timeout + 1))
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

extension Monitor {
    func checkSite() async {
        guard !siteInFlight else { return }
        siteInFlight = true
        defer { siteInFlight = false }
        let generation = pathChanges, rules = settings.siteRules, watching = settings.browserWatch

        var next: SiteWatchStatus
        if !settings.browserWatch {
            next = SiteWatchStatus(state: .disabled, message: "Browser monitoring is off.")
            siteAlertKey = nil
        } else if settings.siteRules.isEmpty {
            next = SiteWatchStatus(state: .idle, message: "No site rules yet — add one in Settings.")
            siteAlertKey = nil
        } else {
            next = await evaluateActiveTab()
        }
        guard generation == pathChanges, rules == settings.siteRules, watching == settings.browserWatch else { return }

        // A tab we can't read is "unknown", not a recovery.
        let trigger: TriggerState = switch next.state {
        case .mismatch: .violating
        case .noLocation, .unsupported, .blocked: .unknown
        default: .clear
        }
        reportTriggerState("site", trigger)
        if next != site {
            site = next
            if next.rule != nil { recordProtection("Site rule", next.message) }
        }
        if next.state == .mismatch {
            let key = "\(next.rule?.domain ?? "")|\(next.message)"
            if key != siteAlertKey {
                siteAlertKey = key
                notify("Wrong location for this site", next.message, sound: true)
            }
        } else if next.state == .match || next.state == .disabled { siteAlertKey = nil }
        await reconcileProtection()
    }

    private func evaluateActiveTab() async -> SiteWatchStatus {
        guard let app = NSWorkspace.shared.frontmostApplication, let name = app.localizedName,
              let kind = browsers[name.lowercased()] else {
            return SiteWatchStatus(state: .idle, message: "No supported browser is active.")
        }
        // A tab that can't be read stays that way until something changes: ask every 30 s, not every 5.
        // Switching apps clears this, so coming back from System Settings asks at once.
        if let last = unreadableTab, last.pid == app.processIdentifier, Date().timeIntervalSince(last.at) < 30 { return last.status }
        func unreadable(_ status: SiteWatchStatus) -> SiteWatchStatus {
            unreadableTab = (app.processIdentifier, Date(), status)
            return status
        }

        // Target by bundle id / pid so a renamed or localized app still resolves.
        let target = app.bundleIdentifier.map { "application id \"\($0)\"" } ?? "application \"\(name)\""
        let script = switch kind {
        case .chromium: "tell \(target) to if (count of windows) > 0 then return URL of active tab of front window"
        case .webkit: "tell \(target) to if (count of windows) > 0 then return URL of current tab of front window"
        case .firefox: """
            tell application "System Events" to tell (first process whose unix id is \(app.processIdentifier))
              try
                return value of (first text field of front window whose value starts with "http")
              on error
                try
                  return value of text field 1 of front window
                on error
                  return ""
                end try
              end try
            end tell
            """
        }

        let url: String
        do {
            url = try await runAppleScript(script)
        } catch {
            if isAutomationDenied(error) {
                return unreadable(SiteWatchStatus(state: .blocked, browser: name,
                                                  message: "Allow Whereabouts to control \(name) (System Settings → Privacy & Security → Automation)."))
            }
            if kind == .firefox {
                return unreadable(SiteWatchStatus(state: .unsupported, browser: name, message: "\(name)'s active tab URL can't be read for location checks."))
            }
            log.error("Couldn't read the active tab in \(name): \(error.localizedDescription)")
            return unreadable(SiteWatchStatus(state: .unsupported, browser: name, message: "Couldn't read the active tab in \(name)."))
        }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else {
            return SiteWatchStatus(state: .idle, message: "The active application changed during the check.")
        }

        guard url.contains("://"), let host = normalizeDomain(url) else {
            return kind == .firefox
                ? unreadable(SiteWatchStatus(state: .unsupported, browser: name, message: "\(name)'s active tab URL can't be read for location checks."))
                : SiteWatchStatus(state: .idle, browser: name, message: "No web page open in \(name).")
        }
        if host != lastSiteHost { lastSiteHost = host }

        guard let rule = matchRule(host, settings.siteRules) else {
            siteAlertKey = nil
            return SiteWatchStatus(state: .idle, browser: name, host: host, message: "\(host) has no location rule.")
        }
        guard let loc = geo.location, loc.countryCode != nil, geo.kind == .safe || geo.kind == .violation else {
            return SiteWatchStatus(state: .noLocation, browser: name, host: host, rule: rule, message: "Waiting for your location to check \(host)…")
        }

        guard !locationSatisfies(loc, rule) else {
            siteAlertKey = nil
            return SiteWatchStatus(state: .match, browser: name, host: host, rule: rule, message: "\(host): you're in \(loc.cityPlace), as required.")
        }
        let status = SiteWatchStatus(state: .mismatch, browser: name, host: host, rule: rule,
                                     message: "\(host) should be accessed from \(rule.requirement), but your IP is in \(loc.cityPlace).")
        return status
    }
}
