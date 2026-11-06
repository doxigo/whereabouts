import AppKit
import SwiftUI
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate, UNUserNotificationCenterDelegate {
    let monitor = Monitor()
    private var statusItem: NSStatusItem!
    private var statusWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var edgeLines: [NSWindow] = []
    private var clockTick: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
        applyTheme(UserDefaults.standard.string(forKey: "theme") ?? "system")
        NSApp.mainMenu = mainMenu()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.imagePosition = .imageLeading
        // Tabular digits, so the item doesn't change width as the minutes go by.
        statusItem.button?.font = .monospacedDigitSystemFont(ofSize: NSFont.menuBarFont(ofSize: 0).pointSize, weight: .regular)
        statusItem.button?.toolTip = "Whereabouts"
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        observe { [weak self] in self?.renderStatusItem() }
        observe { [weak self] in guard let self else { return }; setEdgeLine(monitor.edgeLineVisible) }
        // Re-evaluates on every connection check, system zone change and settings change.
        observe { [weak self] in self?.monitor.announceWarnings() }

        monitor.start()
        // Timers stall during sleep and ignore clock changes, so redraw (and re-arm) on both.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.renderStatusItem() }
        }
        NotificationCenter.default.addObserver(forName: .NSSystemClockDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.renderStatusItem() }
        }
        // A display plugged in or rearranged while the edge line shows.
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { guard let self else { return }; self.setEdgeLine(self.monitor.edgeLineVisible) }
        }
        showStatus()
        if let tab = Demo.settingsTab { showSettingsTab(tab) }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Quitting must never strand the user with their internet blocked.
        monitor.releaseKillSwitchOnQuit()
        // Readers also check the pid, which covers a crash.
        StatusFile.remove()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { showStatus() }
        return true
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completion: @escaping (UNNotificationPresentationOptions) -> Void) {
        completion([.banner, .list])
    }

    /// Clicking an alert opens the Status window, which shows every open issue.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completion: @escaping () -> Void) {
        Task { @MainActor in self.showStatus() }
        completion()
    }

    /// Re-runs `body` whenever any observed Monitor property it read changes.
    private func observe(_ body: @escaping @MainActor () -> Void) {
        withObservationTracking(body) { [weak self] in
            Task { @MainActor in self?.observe(body) }
        }
    }

    // MARK: Menu bar

    private func statusMark() -> (StampGlyph.Mark, NSColor) {
        let m = monitor
        let mark = Whereabouts.statusMark(geo: m.geo.kind, site: m.site.state, blocked: m.kill.active, leaking: m.leaking)
        switch mark {
        case .blocked, .refused: return (mark, .systemRed)
        case .leak: return (mark, .systemOrange)
        case .admitted: return (mark, .systemGreen)
        default: return (mark, .systemGray)
        }
    }

    private func renderStatusItem() {
        guard let button = statusItem.button else { return }
        let m = monitor
        let (mark, color) = statusMark()
        button.image = StampGlyph.image(mark, color: m.settings.alerts.menuBarColor ? color : nil)
        let place = placeTitle()
        let clock = homeClock()
        button.title = clock.map { place.isEmpty ? " \($0)" : "\(place) · \($0)" } ?? place
        scheduleClockTick(clock != nil)
    }

    /// One wakeup per shown minute, re-armed from the wall clock each time so it lands on :00.
    private func scheduleClockTick(_ needed: Bool) {
        clockTick?.invalidate()
        clockTick = nil
        guard needed, let minute = Calendar.current.nextDate(after: Date(), matching: DateComponents(second: 0), matchingPolicy: .nextTime) else { return }
        let tick = Timer(fire: minute, interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.renderStatusItem() }
        }
        tick.tolerance = 0.2
        RunLoop.main.add(tick, forMode: .common)
        clockTick = tick
    }

    private func placeTitle() -> String {
        let m = monitor
        // While blocked every lookup fails, so "Offline" would hide the real reason.
        if m.kill.active { return " Blocked" }
        if m.geo.kind == .offline { return " Offline" }
        guard let loc = m.geo.location, let code = loc.countryCode else { return "" }
        switch m.settings.menuBarDisplay {
        case .code: return " \(code)"
        case .name: return " \(loc.country ?? code)"
        case .city: return " \(loc.city ?? code)"
        case .cityCountry: return " \(loc.cityPlace)"
        case .cityCode: return " \(loc.city.map { "\($0), \(code)" } ?? code)"
        case .flag: return " \(Countries.flag(code))"
        case .full: return " \(Countries.flag(code)) \(loc.cityPlace)"
        }
    }

    /// Home time, even while Match time zone has the system clock on the VPN's zone.
    private func homeClock() -> String? {
        let mac = TimeZone(identifier: monitor.systemTimeZone) ?? .current
        return clockText(monitor.settings.menuBarClock, home: homeClockZone(monitor.settings, mac: mac), mac: mac, at: Date())
    }

    /// The status window's essentials, a labeled row each: exit, VPN, leak checks, Mac time zone.
    /// A row that's off carries its tone: red for a leak, orange for a warning.
    private func shortStatus(_ warnings: [ConsistencyWarning]) -> [MenuHeader.Row] {
        let m = monitor, loc = m.geo.location
        // A check turned off isn't listed.
        func check(_ label: String, disabled: Bool, _ value: String, _ tone: Tone) -> (String, String?, Tone?) {
            (label, disabled ? nil : value, tone == .error || tone == .warning ? tone : nil)
        }
        let rows: [(String, String?, Tone?)] = [
            ("IP", loc?.ip, nil),
            ("Provider", loc?.isp, nil),
            ("VPN", m.geo.vpnName ?? loc?.isVpn.map { $0 ? "Detected" : "Not detected" }, nil),
            check("DNS", disabled: m.leak.dns.state == .off, m.leak.dns.state.label, m.leak.dns.state.tone),
            check("IPv6", disabled: m.leak.ipv6.state == .off, m.leak.ipv6.state.label, m.leak.ipv6.state.tone),
            check("UDP", disabled: m.leak.udp.state == .off, m.leak.udp.state.label, m.leak.udp.state.tone),
            ("Time zone", zoneName(m.systemTimeZone), warnings.contains { $0.kind == .timeZone || $0.kind == .automaticZone } ? .warning : nil),
        ]
        return rows.compactMap { row in row.1.map { MenuHeader.Row(label: row.0, value: $0, tone: row.2) } }
    }

    private func headerContent() -> MenuHeader.Content {
        let m = monitor
        let (mark, color) = statusMark()
        let checked = m.geo.checkedAt.map { " · checked \($0.formatted(.relative(presentation: .named)))" } ?? ""
        return MenuHeader.Content(
            glyph: StampGlyph.image(mark, color: color),
            title: m.kill.active ? "Internet blocked" : m.geo.kind == .offline ? "No connection" : m.geo.location?.cityPlace ?? "Location unknown",
            detail: m.kill.active ? (m.kill.verifying ? "Verifying connection" : m.kill.held ? "Network held" : "Kill switch engaged") : m.geoBadge.label + checked,
            issues: m.connectionIssues,
            status: m.kill.active ? [] : shortStatus(m.consistency))
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        let m = monitor
        menu.removeAllItems()
        menu.addItem(headerItem(MenuHeader { [unowned self] in headerContent() }) { [weak self] in self?.showStatus() })

        let warnings = m.consistency
        if !warnings.isEmpty {
            menu.addItem(.separator())
            menu.addItem(.sectionHeader(title: "Your Mac vs. your connection"))
            for w in warnings {
                let item = action(w.title, w.kind.symbol) { [weak self] in
                    if let tab = w.kind.settingsTab { self?.showSettingsTab(tab) }
                    else if let url = w.kind.systemPane { NSWorkspace.shared.open(url) }
                }
                if #available(macOS 14.4, *) { item.subtitle = w.detail } else { item.toolTip = w.detail }
                menu.addItem(item)
            }
        }

        if m.kill.active {
            menu.addItem(.separator())
            menu.addItem(action("Unblock Network", "wifi") { Task { await m.restoreConnection() } })
        } else if let at = m.kill.reblockAt, m.settings.killSwitch {
            menu.addItem(.separator())
            menu.addItem(disabled: "Unblocked — blocks again at \(at.formatted(date: .omitted, time: .shortened)) if still not allowed")
            menu.addItem(action("Re-arm Kill Switch", "shield") { m.rearmKillSwitch() })
        }
        menu.addItem(.separator())
        menu.addItem(action("Check Now", "arrow.clockwise") { Task { await m.checkAll() } })
        if let until = m.pausedUntil {
            menu.addItem(disabled: "Paused until \(until.formatted(date: .omitted, time: .shortened))")
            menu.addItem(action("Resume Now", "play.circle") { m.resume() })
        } else {
            let item = action("Pause for 1 Hour", "pause.circle") { m.pause() }
            let detail = "No alerts, and the kill switch won't block"
            if #available(macOS 14.4, *) { item.subtitle = detail } else { item.toolTip = detail }
            menu.addItem(item)
        }
        if m.installingUpdate {
            menu.addItem(disabled: "Installing Update…")
        } else if let release = m.latestRelease {
            // If it can't install in place, the release page has the disk image.
            let item = action("\(canInstallUpdates ? "Update to" : "Download") \(release.version)", "arrow.down.circle") {
                Task { if !(await m.installUpdate()) { NSWorkspace.shared.open(release.page) } }
            }
            let detail = canInstallUpdates ? "Installs the new version and restarts Whereabouts" : "Opens the release page for manual installation"
            if #available(macOS 14.4, *) { item.subtitle = detail } else { item.toolTip = detail }
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(action("Settings…", "gearshape", key: ",") { [weak self] in self?.openSettings() })
        menu.addItem(action("Quit Whereabouts", "power", key: "q") { NSApp.terminate(nil) })
    }

    /// The header opens the status window. Its title is what VoiceOver reads, and Return runs it too.
    private func headerItem(_ header: MenuHeader, _ run: @escaping () -> Void) -> NSMenuItem {
        let view = MenuRowView(rootView: header)
        view.onClick = run
        view.frame.size = view.fittingSize
        view.autoresizingMask = .width  // stretch to the menu's widest item
        let item = action("Show Status", "macwindow", run)
        item.view = view
        return item
    }

    private func action(_ title: String, _ symbol: String, key: String = "", _ run: @escaping () -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(MenuAction.fire), keyEquivalent: key)
        let target = MenuAction(run)
        item.target = target
        item.representedObject = target // the item keeps its target alive
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        return item
    }

    private func mainMenu() -> NSMenu {
        // Accessory apps never show this bar, but it's what makes ⌘C/⌘V/⌘W/⌘, work in the windows.
        let main = NSMenu()
        func submenu(_ title: String, _ items: [NSMenuItem]) {
            let menu = NSMenu(title: title)
            items.forEach(menu.addItem)
            let top = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            top.submenu = menu
            main.addItem(top)
        }
        func item(_ title: String, _ selector: Selector, _ key: String, _ mods: NSEvent.ModifierFlags = .command) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
            item.keyEquivalentModifierMask = mods
            return item
        }
        submenu("Whereabouts", [
            item("About Whereabouts", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), ""),
            .separator(),
            item("Settings…", #selector(openSettings), ","),
            .separator(),
            item("Quit Whereabouts", #selector(NSApplication.terminate(_:)), "q"),
        ])
        submenu("Edit", [
            item("Undo", Selector(("undo:")), "z"), item("Redo", Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            item("Cut", #selector(NSText.cut(_:)), "x"), item("Copy", #selector(NSText.copy(_:)), "c"),
            item("Paste", #selector(NSText.paste(_:)), "v"), item("Select All", #selector(NSText.selectAll(_:)), "a"),
        ])
        submenu("Window", [
            item("Close", #selector(NSWindow.performClose(_:)), "w"),
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
        ])
        return main
    }

    // MARK: Windows

    func showStatus() {
        if statusWindow == nil {
            let host = NSHostingController(rootView: StatusView().environment(monitor))
            host.sceneBridgingOptions = [.toolbars, .title]
            let window = NSWindow(contentViewController: host)
            window.title = "Whereabouts"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: 440, height: 640))
            window.contentMinSize = NSSize(width: 390, height: 480)
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            if !Demo.enabled { window.setFrameAutosaveName("StatusWindow") }
            statusWindow = window
        }
        present(statusWindow!)
    }

    @objc func openSettings() {
        if settingsWindow == nil {
            let tabs = NSTabViewController()
            tabs.tabStyle = .toolbar
            func tab<V: View>(_ title: String, _ symbol: String, _ view: V) {
                let host = NSHostingController(rootView: view.environment(monitor))
                host.preferredContentSize = NSSize(width: 560, height: 620)
                host.title = title // becomes the window title
                let item = NSTabViewItem(viewController: host)
                item.label = title
                item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
                tabs.addTabViewItem(item)
            }
            tab("General", "gearshape", GeneralSettings())
            tab("Location", "globe", LocationSettings())
            tab("Time Zone", "clock", TimeZoneSettings())
            tab("Sites", "safari", SiteSettings())
            tab("Protection", "lock.shield", ProtectionSettings())
            tab("About", "info.circle", AboutSettings())
            let window = NSWindow(contentViewController: tabs)
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            settingsWindow = window
        }
        present(settingsWindow!)
    }

    /// Frees a closed window and its SwiftUI views; the next open builds them again.
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if window === statusWindow { statusWindow = nil }
        if window === settingsWindow { settingsWindow = nil }
    }

    func showSettingsTab(_ tab: String) {
        openSettings()
        let tabs = settingsWindow?.contentViewController as? NSTabViewController
        if let i = tabs?.tabViewItems.firstIndex(where: { $0.label == tab }) { tabs?.selectedTabViewItemIndex = i }
    }

    private func present(_ window: NSWindow) {
        // From the menu-bar menu, activate() is only a request and macOS refuses it while another
        // app is in front: the window opened behind that app, or in front but unfocused, taking a
        // click before it answered. Ignoring other apps activates regardless.
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    func applyTheme(_ theme: String) {
        NSApp.appearance = theme == "light" ? NSAppearance(named: .aqua) : theme == "dark" ? NSAppearance(named: .darkAqua) : nil
    }

    // MARK: Edge line

    /// Thin click-through red line across the top of every display.
    private func setEdgeLine(_ visible: Bool) {
        let screens = visible ? NSScreen.screens : []
        while edgeLines.count < screens.count {
            let window = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
            window.backgroundColor = .systemRed
            window.hasShadow = false
            window.ignoresMouseEvents = true
            window.level = .screenSaver
            window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
            window.isReleasedWhenClosed = false
            edgeLines.append(window)
        }
        for (i, window) in edgeLines.enumerated() {
            guard i < screens.count else { window.orderOut(nil); continue }
            let f = screens[i].frame
            window.setFrame(NSRect(x: f.minX, y: f.maxY - 4, width: f.width, height: 4), display: true)
            window.orderFrontRegardless()
        }
    }
}

/// A SwiftUI menu row that clicks like an item: a view-based item gets no action from a click,
/// so its view closes the menu and runs it, as AppKit does for any other item.
private final class MenuRowView<Content: View>: NSHostingView<Content> {
    var onClick: () -> Void = {}

    override func mouseUp(with event: NSEvent) {
        enclosingMenuItem?.menu?.cancelTracking()
        onClick()
    }

    // The content can change while the menu is open (a check finishing adds an issue line), so the
    // frame follows it. SwiftUI relays out without invalidating the intrinsic size, so this watches
    // layout, and resizes on the next turn rather than mid-layout.
    override func layout() {
        super.layout()
        let fit = fittingSize
        guard fit.height != frame.height || fit.width > frame.width else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            setFrameSize(NSSize(width: max(fit.width, frame.width), height: fit.height))
        }
    }
}

/// The menu's first row: the verdict at full contrast, where a disabled item would grey it out.
private struct MenuHeader: View {
    /// Read in `body`, so the header follows the monitor while the menu is open instead of
    /// showing what it was when the menu opened.
    let read: () -> Content
    @State private var hovering = false

    struct Content {
        var glyph: NSImage
        var title: String
        var detail: String
        var issues: [String]
        var status: [Row]
    }

    struct Row {
        var label: String
        var value: String
        /// Set only when the row is off.
        var tone: Tone?
    }

    var body: some View {
        let c = read()
        HStack(alignment: .top, spacing: 8) {
            Image(nsImage: c.glyph).padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(c.title).font(.system(size: 13, weight: .semibold))
                Text(c.detail).font(.system(size: 11)).foregroundStyle(.secondary)
                ForEach(c.issues, id: \.self) { Text($0).font(.system(size: 11)).foregroundStyle(Tone.warning.textColor) }
                // Labels in a column of their own, so each value is found at a glance.
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 2) {
                    ForEach(c.status, id: \.label) { row in
                        GridRow {
                            Text(row.label).foregroundStyle(.secondary)
                            Text(row.value).foregroundStyle(row.tone?.textColor ?? .primary)
                        }
                    }
                }
                .font(.system(size: 11)).monospacedDigit()
                .padding(.top, c.status.isEmpty ? 0 : 5)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        // A click opens the status window, so the pointer gets a highlight, as on the other items.
        .background { RoundedRectangle(cornerRadius: 6).fill(.quaternary).padding(.horizontal, 5).opacity(hovering ? 1 : 0) }
        .onHover { hovering = $0 }
    }
}

private final class MenuAction: NSObject {
    let run: () -> Void
    init(_ run: @escaping () -> Void) { self.run = run }
    @objc func fire() { run() }
}

private extension NSMenu {
    func addItem(disabled title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        addItem(item)
    }
}

extension GeoKind {
    var label: String {
        switch self {
        case .safe: "Allowed"
        case .violation: "Not allowed"
        case .unknown: "Unknown"
        case .offline: "Offline"
        case .checking: "Checking…"
        }
    }
}
