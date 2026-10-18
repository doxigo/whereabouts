import Foundation

/// The zone the menu-bar clock shows: home while Match time zone has the Mac on
/// the exit's zone, otherwise simply the Mac's own (a stale home zone is ignored).
func homeClockZone(_ s: AppSettings, mac: TimeZone) -> TimeZone {
    guard s.matchTimeZone, let home = s.homeTimeZone.flatMap(TimeZone.init(identifier:)) else { return mac }
    return home
}

/// Menu-bar clock text, or nil when there's nothing to show.
func clockText(_ style: MenuBarClock, home: TimeZone, mac: TimeZone, at date: Date, locale: Locale = .autoupdatingCurrent) -> String? {
    // Same offset = the system clock already reads home time.
    if style == .away, home.secondsFromGMT(for: date) == mac.secondsFromGMT(for: date) { return nil }
    func format(_ template: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = home
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter.string(from: date)
    }
    let time = format("jmm")
    switch style {
    case .away: return "\(time) home"
    case .time: return time
    // Date and time apart, like the system clock; one template reads "Sun, 18 Oct at 21:48".
    case .day: return "\(format("EEE")) \(time)"
    case .date: return "\(format("EEEMMMd")) \(time)"
    }
}

/// The macOS clock can't be removed by any app. The closest is its analog face
/// with the date off, which leaves a small icon; these are the same switches as
/// System Settings › Control Center › Clock Options.
enum SystemClock {
    private static let prefs = UserDefaults(suiteName: "com.apple.menuextra.clock")
    private static let backupKey = "systemClockBackup"
    private static let keys = ["IsAnalog", "ShowDate", "ShowDayOfWeek"]

    static var isShrunk: Bool {
        prefs?.bool(forKey: "IsAnalog") == true && prefs?.integer(forKey: "ShowDate") == 2 // 2 = Never
    }

    /// Keeps the user's own clock options so turning this off puts them back exactly.
    static func setShrunk(_ on: Bool) async {
        guard let prefs, on != isShrunk else { return }
        if on {
            UserDefaults.standard.set(prefs.dictionaryRepresentation().filter { keys.contains($0.key) }, forKey: backupKey)
            prefs.set(true, forKey: "IsAnalog")
            prefs.set(2, forKey: "ShowDate")
            prefs.set(false, forKey: "ShowDayOfWeek")
        } else {
            let backup = UserDefaults.standard.dictionary(forKey: backupKey) ?? [:]
            for key in keys { prefs.set(backup[key], forKey: key) }
            UserDefaults.standard.removeObject(forKey: backupKey)
        }
        // ponytail: Control Center may not notice a change made outside System Settings, so restart it (launchd relaunches it at once).
        _ = try? await run("/usr/bin/killall", ["ControlCenter"])
    }
}
