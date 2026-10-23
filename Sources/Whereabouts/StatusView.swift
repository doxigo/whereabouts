import SwiftUI

struct StatusView: View {
    @Environment(Monitor.self) private var m
    @State private var showAllHistory = false

    var body: some View {
        Form {
            killSwitchBanners
            Section { hero }
            if m.settings.browserWatch && m.site.state != .disabled { activeSite }
            location
            if m.leak.ipv6.state != .off || m.leak.dns.state != .off { leakChecks }
            if !m.reach.isEmpty { reachability }
            recentActivity
        }
        .formStyle(.grouped)
        .toolbar {
            ToolbarItemGroup {
                Button { Task { await m.checkAll() } } label: { Label("Check Now", systemImage: "arrow.clockwise") }
                    .disabled(m.isCheckingAll)
                    .help("Check now")
                Button { (NSApp.delegate as? AppDelegate)?.openSettings() } label: { Label("Settings", systemImage: "gearshape") }
                    .help("Settings")
            }
        }
    }

    @ViewBuilder private var killSwitchBanners: some View {
        if m.kill.active {
            // The hero or the active-site section usually says why already; repeat it only when neither does.
            let reason = m.kill.reason.flatMap { $0 == m.geo.message || $0 == m.site.message ? nil : $0 }
            Section {
                Banner(color: .red, icon: "xmark.shield.fill",
                       text: [reason, "The kill switch is blocking internet traffic at the firewall — your local network still works."]
                           .compactMap { $0 }.joined(separator: " ")) {
                    Button("Unblock Network") { Task { await m.restoreConnection() } }
                }
            }
        }
        if let error = m.kill.error {
            Section { Banner(color: .red, icon: "exclamationmark.octagon.fill", text: error) }
        }
        if let until = m.pausedUntil {
            Section {
                Banner(color: .orange, icon: "pause.circle.fill",
                       text: "Paused until \(until.formatted(date: .omitted, time: .shortened)) — no alerts, and the kill switch won't block.") {
                    Button("Resume") { m.resume() }
                }
            }
        }
        if let at = m.kill.reblockAt, !m.kill.active, m.settings.killSwitch {
            Section {
                Banner(color: .orange, icon: "shield.slash",
                       text: "You unblocked the network. Reconnect your VPN: if your location still isn't allowed at \(at.formatted(date: .omitted, time: .shortened)), the kill switch blocks again.") {
                    Button("Re-arm") { m.rearmKillSwitch() }
                }
            }
        }
    }

    private var hero: some View {
        let loc = m.geo.location
        return VStack(spacing: 6) {
            Text(Countries.flag(loc?.countryCode)).font(.system(size: 52))
            Text(loc?.country ?? Countries.name(loc?.countryCode) ?? "—").font(.title2.bold())
            StatusBadge(tone: m.geoBadge.tone, text: m.geoBadge.label)
            Text(m.geo.message).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if m.geo.kind == .safe && !m.settings.hasLocationRules {
                Button("Set Up Rules…") { (NSApp.delegate as? AppDelegate)?.showSettingsTab("Location") }
            }
            // Every open issue, so "Allowed" never hides one; the details are in the sections below.
            if m.leaking {
                Label(m.leakHeadline, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange)
            }
            ForEach(m.consistency, id: \.kind) { w in
                Label(w.title, systemImage: w.kind.symbol).font(.callout).foregroundStyle(.orange).help(w.detail)
            }
            if let checked = m.geo.checkedAt {
                TimelineView(.periodic(from: .now, by: 15)) { _ in
                    Text("Checked \(checked.formatted(.relative(presentation: .named)))")
                        .font(.caption).foregroundStyle(.tertiary)
                }
            }
            if m.geo.confirmed == false {
                Text("Waiting for a second check to confirm this before acting on it.")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
    }

    private var activeSite: some View {
        Section("Active site") {
            LabeledContent {
                StatusBadge(tone: m.site.state.tone, text: m.site.state.label)
            } label: {
                Text(m.site.host ?? "No ruled site")
                if let browser = m.site.browser { Text(browser) }
            }
            Text(m.site.message).foregroundStyle(m.site.state == .mismatch ? .red : .secondary)
            if let rule = m.site.rule {
                Text("Rule: \(rule.domain) → \(rule.requirement)").font(.caption).foregroundStyle(.tertiary)
            }
        }
    }

    private var location: some View {
        let loc = m.geo.location
        let flag = loc?.isVpn.map { $0 ? "Detected" : "Not detected" } ?? "Unknown"
        return Section("Location") {
            LabeledContent("IP address", value: loc?.ip ?? "—").monospacedDigit()
            LabeledContent("Country", value: loc.map { "\(Countries.flag($0.countryCode)) \($0.country ?? "—")" } ?? "—")
            LabeledContent("City", value: loc?.city ?? "—")
            LabeledContent("ISP", value: loc?.isp ?? "—")
            // The provider only says "looks like a proxy"; the name comes from the machine. IP databases
            // know who registered the address, not the VPN brand, so a VPN on the router stays unnamed.
            LabeledContent("VPN / Proxy", value: m.geo.vpnName.map { "\(flag) · \($0)" } ?? flag)
                .help(loc?.isVpn == true && m.geo.vpnName == nil
                      ? "No VPN app or tunnel is running on this Mac, so it's likely on your router or network, where Whereabouts can't see its name." : "")
            // Live: Match time zone changes it, and NSSystemTimeZoneDidChange refreshes it.
            LabeledContent("Mac time zone", value: zoneName(m.systemTimeZone))
        }
        .textSelection(.enabled)
    }

    private var leakChecks: some View {
        Section("Leak checks") {
            if m.leak.ipv6.state != .off {
                leakRow("IPv6 exit", tone: m.leak.ipv6.state.tone, label: m.leak.ipv6.state.label,
                        message: m.leak.ipv6.message, isLeak: m.leak.ipv6.state == .leak,
                        details: m.leak.ipv6.ip.map { [[$0, m.leak.ipv6.isp].compactMap { $0 }.joined(separator: " · ")] } ?? [])
            }
            if m.leak.dns.state != .off {
                leakRow("DNS resolvers", tone: m.leak.dns.state.tone, label: m.leak.dns.state.label,
                        message: m.leak.dns.message, isLeak: m.leak.dns.state == .leak,
                        details: m.leak.dns.resolvers.map {
                            [$0.address, $0.iface, $0.country ?? (isLoopbackAddress($0.address) ? "this Mac" : $0.isPrivate ? "local network" : nil)].compactMap { $0 }.joined(separator: " · ")
                        })
            }
        }
    }

    private func leakRow(_ title: String, tone: Tone, label: String, message: String, isLeak: Bool, details: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).bold()
                Spacer()
                StatusBadge(tone: tone, text: label)
            }
            Text(message).font(.callout).foregroundStyle(isLeak ? .red : .secondary)
            ForEach(details, id: \.self) { Text($0).font(.caption).foregroundStyle(.tertiary).textSelection(.enabled) }
        }
    }

    /// Results only; the domains are managed in Settings › General.
    private var reachability: some View {
        Section("Reachability") {
            ForEach(m.reach) { result in
                HStack {
                    StatusBadge(tone: result.status.tone, text: result.host)
                    Spacer()
                    Text(result.status == .reachable ? result.latencyMs.map { "\($0) ms" } ?? "" : result.status == .blocked ? "blocked" : "…")
                        .monospacedDigit().foregroundStyle(.tertiary)
                }
            }
        }
    }

    private var recentActivity: some View {
        Section {
            if m.history.isEmpty {
                Text("Location changes will appear here.").foregroundStyle(.secondary)
            }
            ForEach(m.history.prefix(showAllHistory ? m.history.count : 10)) { entry in
                HStack(spacing: 10) {
                    Text(Countries.flag(entry.countryCode)).font(.title3)
                    VStack(alignment: .leading) {
                        let country = entry.country ?? Countries.name(entry.countryCode) ?? "Unknown"
                        Text(entry.city.map { "\($0), \(country)" } ?? country)
                        Text([entry.date.formatted(date: .numeric, time: .standard), entry.isp].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.tertiary)
                    }
                    Spacer()
                    StatusBadge(tone: entry.status.tone, text: entry.status.label)
                }
            }
            if m.history.count > 10 {
                Button(showAllHistory ? "Show Less" : "Show All \(m.history.count)") { showAllHistory.toggle() }.buttonStyle(.link)
            }
        } header: {
            HStack {
                Text("Recent activity")
                Spacer()
                if !m.history.isEmpty { Button("Clear") { m.clearHistory() }.buttonStyle(.link) }
            }
        }
    }
}

// MARK: - Labels & tones

extension Monitor {
    /// The verdict's badge. "Allowed" with no rule at all would read as protection, so it says so instead.
    var geoBadge: (tone: Tone, label: String) {
        geo.kind == .safe && !settings.hasLocationRules ? (.neutral, "No rules") : (geo.kind.tone, geo.kind.label)
    }
}

extension GeoKind {
    var tone: Tone {
        switch self {
        case .safe: .success
        case .violation: .error
        case .unknown: .warning
        case .offline: .neutral
        case .checking: .loading
        }
    }
}

extension SiteState {
    var tone: Tone {
        switch self {
        case .match: .success
        case .mismatch: .error
        case .noLocation: .loading
        case .blocked, .unsupported: .warning
        case .disabled, .idle: .neutral
        }
    }

    var label: String {
        switch self {
        case .disabled: "Off"
        case .idle: "Watching"
        case .match: "Location OK"
        case .mismatch: "Wrong location"
        case .noLocation: "Checking…"
        case .unsupported: "Can't read tab"
        case .blocked: "Permission needed"
        }
    }
}

extension Ipv6State {
    var tone: Tone {
        switch self {
        case .leak: .error
        case .ok, .none: .success
        case .checking: .loading
        case .unknown: .warning
        case .off: .neutral
        }
    }

    var label: String {
        switch self {
        case .off: "Off"
        case .checking: "Checking…"
        case .none: "No IPv6"
        case .ok: "No leak"
        case .leak: "Leak"
        case .unknown: "Unknown"
        }
    }
}

extension DnsState {
    var tone: Tone {
        switch self {
        case .leak: .error
        case .ok: .success
        case .checking: .loading
        case .unknown: .warning
        case .off, .inconclusive: .neutral
        }
    }

    var label: String {
        switch self {
        case .off: "Off"
        case .checking: "Checking…"
        case .ok: "No leak"
        case .leak: "Leak"
        case .inconclusive: "Inconclusive"
        case .unknown: "Unknown"
        }
    }
}

extension ReachKind {
    var tone: Tone {
        switch self {
        case .reachable: .success
        case .blocked: .error
        case .checking: .loading
        }
    }
}

extension HistoryStatus {
    var tone: Tone {
        switch self {
        case .safe: .success
        case .violation: .error
        case .unknown: .warning
        }
    }

    var label: String {
        switch self {
        case .safe: "Allowed"
        case .violation: "Not allowed"
        case .unknown: "Unknown"
        }
    }
}
