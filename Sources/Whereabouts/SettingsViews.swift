import SwiftUI

// MARK: - General

struct GeneralSettings: View {
    @Environment(Monitor.self) private var m
    @AppStorage("theme") private var theme = "system"
    @State private var customInterval = false
    @State private var systemClockShrunk = SystemClock.isShrunk

    private static let presets = [(30_000, "Every 30 seconds"), (60_000, "Every minute"), (300_000, "Every 5 minutes"), (900_000, "Every 15 minutes")]

    var body: some View {
        Form {
            Section("Monitoring") {
                Picker("Menu bar shows", selection: m.binding(\.menuBarDisplay)) {
                    ForEach(MenuBarDisplay.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Picker(selection: m.binding(\.menuBarClock)) {
                    ForEach(MenuBarClock.allCases, id: \.self) { Text($0.label).tag($0) }
                } label: {
                    Text("Menu bar clock")
                    Text("Always your home time, even while the Mac is on the VPN's time zone.")
                }
                Toggle(isOn: Binding(get: { systemClockShrunk }, set: { on in
                    Task { await SystemClock.setShrunk(on); systemClockShrunk = SystemClock.isShrunk }
                })) {
                    Text("Shrink the system clock")
                    Text("No app can remove the macOS clock, so this switches it to the small analog face with no date. It changes Control Center › Clock Options and briefly redraws the menu bar. Turn it off to restore your options.")
                }
                Picker("Check interval", selection: intervalSelection) {
                    ForEach(Self.presets, id: \.0) { Text($0.1).tag($0.0) }
                    Divider()
                    Text("Custom…").tag(0)
                }
                if customInterval || !Self.presets.contains(where: { $0.0 == m.settings.intervalMs }) {
                    LabeledContent("Every") {
                        HStack {
                            TextField("Seconds", value: seconds, format: .number)
                                .textFieldStyle(.roundedBorder).frame(width: 70).multilineTextAlignment(.trailing)
                            Stepper("", value: seconds, in: 10...86_400, step: 5).labelsHidden()
                            Text("seconds")
                        }
                    }
                }
                Toggle(isOn: m.binding(\.launchAtLogin)) {
                    Text("Launch at login")
                    Text("Start monitoring automatically when you log in.")
                }
            }

            Section("Alerts") {
                Toggle(isOn: m.binding(\.alerts.menuBarColor)) { Text("Menu bar color"); Text("Tint the menu bar icon by status.") }
                Toggle(isOn: m.binding(\.alerts.notifications)) { Text("Notifications"); Text("Show a banner when something changes.") }
                Toggle(isOn: m.binding(\.alerts.sound)) { Text("Sound"); Text("Play a sound when your location is wrong or leaking.") }
                Toggle(isOn: m.binding(\.alerts.edgeLine)) { Text("Screen-edge line"); Text("Show a red line along the top of every screen while your location isn't allowed.") }
            }

            Section {
                AddField(placeholder: "e.g. github.com") { host in
                    m.update { s in if !s.domains.contains(where: { $0.caseInsensitiveCompare(host) == .orderedSame }) { s.domains.append(host) } }
                }
                ForEach(m.settings.domains, id: \.self) { host in
                    RemovableRow(onRemove: { m.update { $0.domains.removeAll { $0 == host } } }) { Text(host) }
                }
            } header: {
                Text("Reachability")
            } footer: {
                Footer("Check whether these hosts are reachable or blocked. Results show in the status window.")
            }

            Section("Appearance") {
                Picker("Theme", selection: $theme) {
                    Text("Auto").tag("system")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                }
                .pickerStyle(.segmented)
                .onChange(of: theme) { (NSApp.delegate as? AppDelegate)?.applyTheme(theme) }
            }
        }
        .formStyle(.grouped)
        // Clock Options may have changed in System Settings meanwhile.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            systemClockShrunk = SystemClock.isShrunk
        }
    }

    private var intervalSelection: Binding<Int> {
        Binding(
            get: { customInterval || !Self.presets.contains(where: { $0.0 == m.settings.intervalMs }) ? 0 : m.settings.intervalMs },
            set: { value in
                customInterval = value == 0
                if value != 0 { m.update { $0.intervalMs = value } }
            })
    }

    private var seconds: Binding<Int> {
        Binding(get: { m.settings.intervalMs / 1000 }, set: { v in m.update { $0.intervalMs = max(10, v) * 1000 } })
    }
}

// MARK: - Location

struct LocationSettings: View {
    @Environment(Monitor.self) private var m
    @State private var automaticZone = TimeZoneHelper.automaticIsOn

    var body: some View {
        let allowlist = m.settings.ruleMode == .allowlist
        Form {
            Section {
                Picker("Mode", selection: m.binding(\.ruleMode)) {
                    Text("Blocklist").tag(RuleMode.blocklist)
                    Text("Allowlist").tag(RuleMode.allowlist)
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Detection rule")
            } footer: {
                Footer(allowlist ? "You'll be alerted whenever your IP is outside these countries."
                               : "You'll be alerted whenever your IP is inside one of these countries.")
            }

            Section(allowlist ? "Allowed countries" : "Blocked countries") {
                ForEach(m.settings.countries, id: \.self) { code in
                    RemovableRow(onRemove: { m.update { $0.countries.removeAll { $0 == code } } }) {
                        Text(Countries.flag(code))
                        Text(Countries.name(code) ?? code)
                    }
                }
                CountryPicker(exclude: Set(m.settings.countries)) { code in m.update { $0.countries.append(code) } }
                if let code = m.geo.location?.countryCode, !m.settings.countries.contains(code) {
                    Button("Add current: \(Countries.flag(code)) \(Countries.name(code) ?? code)") { m.update { $0.countries.append(code) } }
                }
            }

            Section {
                Picker("Provider rule", selection: m.binding(\.ispMode)) {
                    Text("Off").tag(IspMode.off)
                    Text("Allowlist").tag(IspMode.allowlist)
                }
                .pickerStyle(.segmented)
                ForEach(m.settings.expectedIsps, id: \.self) { name in
                    RemovableRow(onRemove: { m.update { $0.expectedIsps.removeAll { $0 == name } } }) { Text(name) }
                }
                AddField(placeholder: "Provider name, e.g. Mullvad") { name in m.update { $0.expectedIsps.append(name) } }
                // Provider names are awkward to type, so offer the live one.
                if let isp = m.geo.location?.isp,
                   !m.settings.expectedIsps.contains(where: { $0.caseInsensitiveCompare(isp) == .orderedSame }) {
                    Button("Use current: \(isp)") { m.update { $0.expectedIsps.append(isp) } }
                }
                Toggle(isOn: m.binding(\.alertOnIspChange)) {
                    Text("Alert on provider change")
                    Text("Notify when the ISP changes, even inside an allowed country.")
                }
            } header: {
                Text("Expected providers")
            } footer: {
                Footer("The country can be right while the connection isn't — a dropped VPN often reconnects through a local ISP in the same country. Names match loosely, so “Mullvad” covers “Mullvad VPN AB”.")
            }

            timeZone
            warningsSection
        }
        .formStyle(.grouped)
        // Re-read after a trip to System Settings to turn automatic time zone off.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            automaticZone = TimeZoneHelper.automaticIsOn
        }
    }

    private var timeZone: some View {
        Section {
            Toggle(isOn: Binding(get: { m.settings.matchTimeZone }, set: { v in Task { await m.setMatchTimeZone(v) } })) {
                Text("Match my Mac's time zone and region to my connection")
                Text("While a VPN is up, the Mac uses the exit's time zone and region; otherwise your home ones. With Alibi on a place for all sites, the Mac uses that place's instead. The menu bar clock keeps your home time.")
            }
            // Fighting Location Services would flip the zone back and forth.
            .disabled(automaticZone && !m.settings.matchTimeZone)
            if automaticZone {
                LabeledContent {
                    Button("Open Date & Time") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Date-Time-Settings.extension")!)
                    }
                } label: {
                    Label("Automatic time zone is on", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text("Turn off “Set time zone automatically using your current location” in General › Date & Time, or macOS will keep switching it back.")
                }
            }
            LabeledContent("Home time zone") {
                SearchPicker(title: zoneName(m.settings.homeTimeZone ?? m.systemTimeZone), prompt: "Search time zones",
                             items: TimeZone.knownTimeZoneIdentifiers.map { ($0, zoneName($0), "") }) { zone in
                    m.update { $0.homeTimeZone = zone }
                }
            }
            LabeledContent("Home region") {
                let home = m.settings.homeRegion ?? RegionPref.current
                CountryPicker(title: home.map { "\(Countries.flag($0)) \(Countries.name($0) ?? $0)" } ?? "Choose…") { code in
                    m.update { $0.homeRegion = code }
                }
            }
            LabeledContent("Mac is set to", value: zoneName(m.systemTimeZone))
            if m.settings.matchTimeZone, let zone = m.alibiWish?.zone {
                LabeledContent("Alibi's location", value: zoneName(zone))
            }
            if let error = m.timeZoneError {
                Label(error, systemImage: "exclamationmark.octagon.fill").foregroundStyle(.red)
            }
        } header: {
            Text("Time zone and region")
        } footer: {
            Footer("While the Mac is on another zone, Calendar shows events in it unless you turn on Time Zone Override in Calendar settings. Reminders, alarms and scheduled jobs follow the new local time, Finder, Messages and logs show it too, and open browser tabs may need a reload. The region also sets date, number and currency formats; your language stays.")
        }
    }

    private var warningsSection: some View {
        Section {
            Toggle(isOn: m.binding(\.warnTimeZone)) {
                Text("Time zone")
                Text("Warn when the Mac's time zone differs from the connection's while a VPN is up.")
            }
            Toggle(isOn: m.binding(\.warnAutomaticZone)) {
                Text("Automatic time zone")
                Text("Warn while macOS sets the time zone from your real location.")
            }
            Toggle(isOn: m.binding(\.warnRegion)) {
                Text("Region")
                Text("Mention when the Mac's region differs from the connection's country and matching is off.")
            }
        } header: {
            Text("Consistency warnings")
        } footer: {
            Footer("Sites can compare what your Mac reports with where your connection appears to be, and a mismatch can give a VPN away. Warnings show in the menu bar menu, with a notification when one first appears.")
        }
    }
}

// MARK: - Sites

private struct RuleDraft: Identifiable {
    let id = UUID()
    var rule: SiteRule
    /// Domain being edited; nil for a new rule.
    var original: String?
}

struct SiteSettings: View {
    @Environment(Monitor.self) private var m
    @State private var draft: RuleDraft?

    var body: some View {
        Form {
            Section {
                Toggle(isOn: m.binding(\.browserWatch)) {
                    Text("Monitor active browser tab")
                    Text("Read the frontmost browser's tab to enforce these rules.")
                }
            } footer: {
                Footer("Require specific IP locations per website — the rule is satisfied if your IP is in any one of them. For example, your bank only from your home country, or a shop only from one of two cities.")
            }

            Section {
                ForEach(m.settings.siteRules) { rule in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(rule.domain).bold()
                            Spacer()
                            Button { draft = RuleDraft(rule: rule, original: rule.domain) } label: { Image(systemName: "pencil") }
                                .buttonStyle(.borderless).help("Edit this rule")
                            Button { m.update { $0.siteRules.removeAll { $0.domain == rule.domain } } } label: { Image(systemName: "trash") }
                                .buttonStyle(.borderless).help("Delete this rule")
                        }
                        Text(rule.locations.map { "\(Countries.flag($0.countryCode)) \($0.label)" }.joined(separator: "   "))
                            .foregroundStyle(.secondary)
                        HStack(spacing: 16) {
                            Toggle("Edge line", isOn: ruleBinding(rule.domain, \.edgeLine)).help("Show the red screen-edge line on mismatch")
                            Toggle("Cut network", isOn: ruleBinding(rule.domain, \.killSwitch))
                                .disabled(!m.settings.killSwitch)
                                .help("Cut the network on mismatch")
                        }
                        .toggleStyle(.checkbox)
                        .font(.callout)
                    }
                    .padding(.vertical, 2)
                }
                Button("Add Rule…") { draft = RuleDraft(rule: SiteRule(domain: "", locations: [])) }
            } header: {
                Text("Rules")
            } footer: {
                if !m.settings.killSwitch && !m.settings.siteRules.isEmpty {
                    Footer("Cut network needs the kill switch, which is off. Turn it on in Protection.")
                }
            }
        }
        .formStyle(.grouped)
        .sheet(item: $draft) { d in
            SiteRuleEditor(rule: d.rule, isNew: d.original == nil) { saved in save(saved, replacing: d.original) }
                .environment(m)
        }
    }

    private func ruleBinding(_ domain: String, _ path: WritableKeyPath<SiteRule, Bool>) -> Binding<Bool> {
        Binding(get: { m.settings.siteRules.first { $0.domain == domain }?[keyPath: path] ?? false },
                set: { v in m.update { s in if let i = s.siteRules.firstIndex(where: { $0.domain == domain }) { s.siteRules[i][keyPath: path] = v } } })
    }

    private func save(_ edited: SiteRule, replacing original: String?) {
        guard let domain = normalizeDomain(edited.domain) else { return }
        var rule = edited
        rule.domain = domain
        m.update { s in
            if let original {
                // Renaming onto a domain that already has a rule must not leave two.
                s.siteRules.removeAll { $0.domain == domain && $0.domain != original }
                if let i = s.siteRules.firstIndex(where: { $0.domain == original }) { s.siteRules[i] = rule }
            } else if let i = s.siteRules.firstIndex(where: { $0.domain == domain }) {
                // A new rule for an existing domain extends it; normalize() drops duplicate locations.
                s.siteRules[i].locations += rule.locations
            } else {
                s.siteRules.append(rule)
            }
        }
    }
}

private struct SiteRuleEditor: View {
    @State var rule: SiteRule
    let isNew: Bool
    let onSave: (SiteRule) -> Void
    @Environment(Monitor.self) private var m
    @Environment(\.dismiss) private var dismiss
    @State private var country: String?
    @State private var city = ""

    /// A picked country counts even if "Add" was never pressed, so it's never silently dropped.
    private var locations: [SiteLocation] {
        guard let country else { return rule.locations }
        let city = city.trimmingCharacters(in: .whitespaces)
        return rule.locations + [SiteLocation(countryCode: country, country: Countries.name(country) ?? country, city: city.isEmpty ? nil : city)]
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Website", text: $rule.domain, prompt: Text("example.com"))
                    if isNew, let host = m.lastSiteHost, normalizeDomain(rule.domain) != host {
                        Button("Use last tab: \(host)") { rule.domain = host }
                    }
                }
                Section("Allowed locations") {
                    ForEach(rule.locations, id: \.key) { location in
                        RemovableRow(onRemove: { rule.locations.removeAll { $0.key == location.key } }) {
                            Text(Countries.flag(location.countryCode))
                            Text(location.label)
                        }
                    }
                    HStack {
                        CountryPicker(title: country.map { "\(Countries.flag($0)) \(Countries.name($0) ?? $0)" } ?? "Choose Country…") { country = $0 }
                        TextField("City", text: $city, prompt: Text("City (optional)")).labelsHidden().textFieldStyle(.roundedBorder)
                        Button("Add") {
                            rule.locations = locations
                            city = "" // keep the country, so several cities can be added in a row
                        }
                        .disabled(country == nil)
                    }
                    if let loc = m.geo.location, let code = loc.countryCode {
                        let current = SiteLocation(countryCode: code, country: loc.country ?? code, city: loc.city)
                        if !rule.locations.contains(where: { $0.key == current.key }) {
                            Button("Add current: \(Countries.flag(code)) \(current.label)") { rule.locations.append(current) }
                        }
                    }
                }
                Section {
                    Toggle("Red screen-edge line on mismatch", isOn: $rule.edgeLine)
                    Toggle("Cut the network on mismatch", isOn: $rule.killSwitch).disabled(!m.settings.killSwitch)
                } footer: {
                    if !m.settings.killSwitch { Footer("Cutting the network needs the kill switch, which is off. Turn it on in Protection.") }
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(isNew ? "Add Rule" : "Save") {
                    rule.locations = locations
                    onSave(rule)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(normalizeDomain(rule.domain) == nil || locations.isEmpty)
            }
            .padding()
        }
        .frame(width: 480, height: 460)
    }
}

// MARK: - Protection

struct ProtectionSettings: View {
    @Environment(Monitor.self) private var m
    @State private var copied = false

    var body: some View {
        Form {
            Section {
                Toggle(isOn: m.binding(\.ipv6Check)) { Text("IPv6 exit"); Text("Compare where IPv6 traffic exits with your IPv4 location.") }
                Toggle(isOn: m.binding(\.dnsCheck)) { Text("DNS resolvers"); Text("Check whether DNS queries are resolved outside your tunnel.") }
            } header: {
                Text("Leak checks")
            } footer: {
                Footer("The two paths that bypass a VPN even when your IPv4 exit looks right.")
            }

            Section {
                Toggle(isOn: m.binding(\.shareStatus)) {
                    Text("Share location with Git IP Guard")
                    Text(!StatusFile.gitIpGuardInstalled ? "Git IP Guard isn't installed. It's a free command-line tool that stops git from reaching your remotes while your IP is in a sanctioned country."
                         : m.settings.shareStatus ? "Git IP Guard is installed and checks git against this location, with no IP lookup of its own."
                         : "Git IP Guard is installed and looks up your IP itself before git connects.")
                }
                if !StatusFile.gitIpGuardInstalled {
                    Link("Get Git IP Guard", destination: StatusFile.gitIpGuardURL)
                }
            } header: {
                Text("Git IP Guard")
            } footer: {
                Footer("Each check is saved to status.json in Whereabouts' folder, where other tools on this Mac can read it. Nothing leaves your Mac.")
            }

            Section {
                Toggle(isOn: Binding(get: { m.settings.killSwitch }, set: { v in Task { await m.setKillSwitch(v) } })) {
                    Text("Enable kill switch")
                    Text("Asks for your admin password once to set up, then triggers automatically with no prompts.")
                }
                Toggle(isOn: m.binding(\.confirmViolations)) {
                    Text("Confirm before blocking")
                    Text("Require a second provider, or the next check, to agree before traffic is cut.")
                }
                if m.kill.active {
                    LabeledContent {
                        Button("Unblock Now") { Task { await m.restoreConnection() } }
                    } label: {
                        Text("Internet is blocked")
                        Text(m.kill.reason ?? "Traffic is currently blocked by the kill switch.")
                    }
                }
                if let at = m.kill.reblockAt, !m.kill.active, m.settings.killSwitch {
                    LabeledContent {
                        Button("Re-arm Now") { m.rearmKillSwitch() }
                    } label: {
                        Text("Unblocked")
                        Text("Reconnect your VPN: if your location still isn't allowed at \(at.formatted(date: .omitted, time: .shortened)), the kill switch blocks again. It re-arms sooner once everything is clear.")
                    }
                }
                if m.kill.needsSetup {
                    LabeledContent {
                        Button("Set Up Now") { Task { if await m.installKillSwitchHelper() { await m.refreshKillSwitchState() } } }
                    } label: {
                        Text("Setup needed")
                        Text("The privileged helper isn't installed, so the kill switch can't engage yet.")
                    }
                }
                if let error = m.kill.error {
                    Label(error, systemImage: "exclamationmark.octagon.fill").foregroundStyle(.red)
                }
            } header: {
                Text("Kill switch")
            } footer: {
                Footer("Blocks internet traffic the moment your location isn't allowed, using firewall (pf) rules — the same approach a VPN's network lock uses.")
            }

            if m.settings.killSwitch {
                Section {
                    Label("Armed — a location that isn't allowed immediately blocks all internet traffic, including VPN tunnels. Wi-Fi stays connected and your local network keeps working.",
                          systemImage: "exclamationmark.shield.fill")
                        .foregroundStyle(.red)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Quitting Whereabouts lifts the block, and nothing is written to your network settings, so a reboot always restores traffic. If it's force-quit while blocked, run this in Terminal:")
                            .foregroundStyle(.secondary)
                        HStack(alignment: .top) {
                            Text(KillSwitch.manualUnblockCommand)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .padding(8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                            Button(copied ? "Copied" : "Copy") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(KillSwitch.manualUnblockCommand, forType: .string)
                                copied = true
                            }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - About

struct AboutSettings: View {
    @Environment(Monitor.self) private var m
    @State private var checking = false
    @State private var failedAt: Date?

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 64, height: 64)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Whereabouts").font(.title2.bold())
                        Text("Version \(appVersion) (\(appBuild))").foregroundStyle(.secondary).textSelection(.enabled)
                        Text("Keeps checking where the internet thinks your Mac is.").foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }

            Section("Updates") {
                LabeledContent {
                    updateActions
                } label: {
                    Text(updateStatus.title)
                    Text(updateStatus.detail)
                }
                Toggle(isOn: m.binding(\.checkUpdates)) {
                    Text("Check for updates automatically")
                    Text("Once a day, ask GitHub whether a newer release is out. A new version shows in the menu.")
                }
                Toggle(isOn: m.binding(\.installUpdates)) {
                    Text("Install updates automatically")
                    Text("Download the new version and restart with it, once you've switched to another app.")
                }
                .disabled(!m.settings.checkUpdates)
            }

            Section {
                Link("What's New in \(appVersion)", destination: repoURL.appending(path: "releases/tag/v\(appVersion)"))
                Link("Source Code on GitHub", destination: repoURL)
                Link("Report an Issue", destination: repoURL.appending(path: "issues/new"))
                Link("Alibi, the Companion Browser Extension", destination: URL(string: "https://github.com/doxigo/alibi")!)
                Link("Git IP Guard, Location Checks for Git", destination: StatusFile.gitIpGuardURL)
            } header: {
                Text("Links")
            } footer: {
                let copyright = Bundle.main.object(forInfoDictionaryKey: "NSHumanReadableCopyright") as? String ?? ""
                Footer("\(copyright). Free software under the GNU General Public License v3.")
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder private var updateActions: some View {
        if checking || m.installingUpdate {
            ProgressView().controlSize(.small)
        } else if let release = m.latestRelease {
            HStack {
                Button("Release Notes") { NSWorkspace.shared.open(release.page) }
                // If it can't install in place, the release page has the disk image.
                Button("Install and Restart") {
                    Task { if !(await m.installUpdate()) { NSWorkspace.shared.open(release.page) } }
                }
            }
        } else {
            Button("Check Now") {
                Task {
                    checking = true
                    failedAt = await m.fetchLatestRelease() ? nil : Date()
                    checking = false
                }
            }
        }
    }

    private var updateStatus: (title: String, detail: String) {
        if m.installingUpdate { return ("Installing update…", "Whereabouts restarts with the new version when it's done.") }
        if checking { return ("Checking for updates…", "Asking GitHub for the latest release.") }
        if let release = m.latestRelease { return ("Version \(release.version) is available", "You have \(appVersion).") }
        // A later automatic check that got through supersedes a failed manual one.
        if let failedAt, failedAt > m.lastUpdateCheck ?? .distantPast { return ("Couldn't reach GitHub", "Check your connection and try again.") }
        if let at = m.lastUpdateCheck { return ("Whereabouts is up to date", "Last checked \(at.formatted(date: .abbreviated, time: .shortened)).") }
        return ("Not checked yet", m.settings.checkUpdates ? "Whereabouts checks once a day." : "Automatic checks are off.")
    }
}
