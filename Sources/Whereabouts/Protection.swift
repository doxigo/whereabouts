import Foundation

enum ProtectionAction: Equatable {
    case none
    case block(String)
    case releaseHold
    case verify
}

struct ProtectionState {
    private var previousViolation: Location?

    mutating func accept(_ status: inout GeoStatus) {
        guard status.kind == .violation else { previousViolation = nil; return }
        if status.confirmed == false, let location = status.location, location == previousViolation {
            status.confirmed = true
        }
        previousViolation = status.location
    }

    mutating func invalidate() { previousViolation = nil }

    static func action(settings: AppSettings, geo: GeoStatus, site: SiteWatchStatus,
                       kill: KillSwitchStatus, paused: Bool) -> ProtectionAction {
        guard settings.killSwitch, !paused, !kill.suppressed else { return .none }
        var siteReason: String?
        if settings.browserWatch, site.state == .mismatch, let rule = site.rule, rule.killSwitch,
           geo.kind == .safe || geo.kind == .violation, let location = geo.location, !locationSatisfies(location, rule) {
            siteReason = site.message
        }
        if let reason = geo.kind == .violation && geo.confirmed != false ? geo.message : siteReason {
            return !kill.active || kill.held ? .block(reason) : .none
        }
        if settings.strictProtection, geo.kind != .safe, !kill.active || kill.held { return .verify }
        if kill.held && geo.kind == .safe { return .releaseHold }
        return .none
    }
}

func statusMark(geo: GeoKind, site: SiteState, blocked: Bool, leaking: Bool) -> StampGlyph.Mark {
    if blocked { return .blocked }
    if geo == .violation || site == .mismatch { return .refused }
    if leaking { return .leak }
    switch geo {
    case .safe: return .admitted
    case .violation: return .refused
    case .unknown: return .unknown
    case .offline: return .offline
    case .checking: return .checking
    }
}

func nextCheckDelay(interval: Double, elapsed: Double) -> Double {
    max(0, interval - elapsed)
}
