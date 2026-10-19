import Foundation

// Network kill switch: loads block rules into the macOS packet filter (pf), the
// same mechanism a VPN client's "network lock" uses. Interfaces are never touched
// (Wi-Fi keeps its lease), the LAN keeps working, and nothing persistent is
// written, so a reboot always restores traffic.
//
// Rules live in the anchor `com.apple/100.Whereabouts`: /etc/pf.conf already
// evaluates `anchor "com.apple/*"`, and `100.` sorts ahead of Apple's own
// anchors so our `quick` rules win. pf needs root, so a one-time admin prompt
// installs a root-owned helper plus a passwordless-sudo rule scoped to its three
// argument-less subcommands; every trigger after that is a silent `sudo -n`.

/// What a monitor currently sees, for deciding when a paused kill switch may
/// re-arm. `unknown` (offline, mid-reconnect) must never count as a recovery.
enum TriggerState { case violating, clear, unknown }

/// Why the kill switch should block again when the unblock window ends; nil lets the next check decide.
func reblockReason(_ geo: GeoStatus, _ site: SiteWatchStatus) -> String? {
    // An unconfirmed violation never cuts the network on its own; it waits for the next check.
    if geo.kind == .violation && geo.confirmed != false { return geo.message }
    if site.state == .mismatch && site.rule?.killSwitch == true { return site.message }
    return nil
}

enum KillSwitch {
    static let helperVersion = 1
    static let helperPath = "\(Privileged.appDir)/killswitch-helper.sh"
    static let tokenFile = "\(Privileged.appDir)/killswitch-pf.token"
    static let sudoersPath = "/etc/sudoers.d/whereabouts-killswitch"
    static let anchor = "com.apple/100.Whereabouts"

    /// Lifts the block and removes the helper without the app — the safety net
    /// for a force-quit while blocked, or deleting the app while armed.
    static var manualUnblockCommand: String {
        "sudo pfctl -a \(Privileged.q(anchor)) -F all && sudo rm -f \(Privileged.q(sudoersPath)) \(Privileged.q(helperPath)) \(Privileged.q(tokenFile))"
    }

    static let helperScript = #"""
    #!/bin/bash
    # WHEREABOUTS_HELPER_VERSION=\#(helperVersion)
    # Whereabouts kill switch helper. Cuts internet traffic with pf. Interfaces are
    # never touched and nothing persistent is written, so a reboot restores traffic.
    set -uo pipefail

    PFCTL=/sbin/pfctl
    ANCHOR=\#(Privileged.q(anchor))
    TOKEN_FILE=\#(Privileged.q(tokenFile))

    emit_rules() {
      cat <<'WA_RULES'
    pass quick on lo0 all
    # Local network stays reachable (router, printers, AirDrop, VMs). DESTINATION
    # only: a "from <private>" rule would match this Mac's own address and pass
    # the entire internet.
    pass quick inet from any to { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 169.254.0.0/16, 224.0.0.0/4, 255.255.255.255 }
    pass quick inet6 from any to { ::1, fe80::/10, fc00::/7, ff00::/8 }
    # DHCP/DHCPv6, so interfaces keep their leases.
    pass quick inet proto udp from any port 68 to any port 67
    pass quick inet proto udp from any port 67 to any port 68
    pass quick inet6 proto udp from any port 546 to any port 547
    pass quick inet6 proto udp from any port 547 to any port 546
    # Everything else - the internet, including any VPN tunnel - is dropped.
    block drop quick all
    WA_RULES
    }

    case "${1:-}" in
      engage)
        # Without the anchor point our rules would load but never be evaluated.
        if ! $PFCTL -s rules 2>/dev/null | grep -qF 'anchor "com.apple/*"'; then
          echo "whereabouts: /etc/pf.conf has no com.apple anchor point" >&2
          exit 5
        fi
        if ! emit_rules | $PFCTL -a "$ANCHOR" -f - 2>/dev/null; then
          echo "whereabouts: failed to load pf block rules" >&2
          exit 3
        fi
        # pf enable is reference counted; hold exactly one token so other pf
        # users (Internet Sharing, the app firewall) are never disturbed.
        if [ ! -s "$TOKEN_FILE" ]; then
          TOKEN=$($PFCTL -E 2>&1 | awk '/Token/ { print $NF }' | tail -n 1)
          if [ -n "$TOKEN" ]; then
            echo "$TOKEN" > "$TOKEN_FILE"
            chmod 600 "$TOKEN_FILE"
          fi
        fi
        if ! $PFCTL -s info 2>/dev/null | grep -qF "Status: Enabled"; then
          $PFCTL -a "$ANCHOR" -F all >/dev/null 2>&1
          echo "whereabouts: pf could not be enabled" >&2
          exit 4
        fi
        # Drop existing state, or traffic already in flight rides past the block.
        $PFCTL -F states >/dev/null 2>&1
        echo active
        ;;
      release)
        $PFCTL -a "$ANCHOR" -F all >/dev/null 2>&1
        if [ -s "$TOKEN_FILE" ]; then
          while IFS= read -r tok; do
            [ -n "$tok" ] && $PFCTL -X "$tok" >/dev/null 2>&1
          done < "$TOKEN_FILE"
          rm -f "$TOKEN_FILE"
        fi
        echo inactive
        ;;
      status)
        if $PFCTL -a "$ANCHOR" -s rules 2>/dev/null | grep -qF "block drop quick"; then
          echo active
        else
          echo inactive
        fi
        ;;
      *)
        echo "Usage: $0 {engage|release|status}" >&2
        exit 1
        ;;
    esac
    """#

    static func setupScript(user: String) -> String {
        let helper = Privileged.sudoersPath(helperPath)
        return Privileged.installScript(helperPath: helperPath, helper: helperScript, sudoersPath: sudoersPath,
                                        grants: ["engage", "release", "status"].map { "\(user) ALL=(root) NOPASSWD: \(helper) \($0)" })
    }

    static let teardownScript = """
    #!/bin/bash
    set -uo pipefail
    # Lift any active block first — removing the helper must never leave pf locked.
    \(Privileged.q(helperPath)) release >/dev/null 2>&1 || /sbin/pfctl -a \(Privileged.q(anchor)) -F all >/dev/null 2>&1
    /bin/rm -f \(Privileged.q(sudoersPath)) \(Privileged.q(helperPath)) \(Privileged.q(tokenFile))
    /bin/rmdir \(Privileged.q(Privileged.appDir)) 2>/dev/null
    exit 0
    """

    static func sudoHelper(_ command: String, timeout: TimeInterval = 10) async throws -> String {
        try await run("/usr/bin/sudo", ["-n", helperPath, command], timeout: timeout)
    }

    /// Installed helper version: nil when absent, 0 when unversioned.
    static func installedVersion() -> Int? {
        guard let content = try? String(contentsOfFile: helperPath, encoding: .utf8) else { return nil }
        return content.firstMatch(of: /WHEREABOUTS_HELPER_VERSION=(\d+)/).flatMap { Int($0.1) } ?? 0
    }

}

extension Monitor {
    /// A paused kill switch re-arms only once every reporting monitor is clear —
    /// i.e. you fixed it, not that the check failed while the network reconnects.
    func reportTriggerState(_ source: String, _ state: TriggerState) {
        triggerStates[source] = state
        guard kill.suppressed, !triggerStates.isEmpty, triggerStates.values.allSatisfy({ $0 == .clear }) else { return }
        kill.reblockAt = nil
        log.info("Kill switch re-armed — every monitor is clear again")
    }

    func rearmKillSwitch() { kill.reblockAt = nil }

    /// Seconds a manual unblock gives the VPN to reconnect before the kill switch blocks again.
    static let reblockDelay: Double = 120

    /// The end of the unblock window: the kill switch arms again, and blocks at once
    /// if the location still isn't allowed.
    func reblockIfStillWrong() async {
        guard kill.suppressed else { return } // re-armed meanwhile
        // A fresh answer, taken while still standing down so this check can't fire twice.
        let status = await checkGeo()
        guard kill.suppressed else { return } // that check came back clear and re-armed it
        kill.reblockAt = nil
        siteAlertKey = nil // a site mismatch that outlived the window counts as new
        if settings.killSwitch, let reason = reblockReason(status, site) {
            log.warning("Still not allowed when the unblock window ended — blocking again")
            await activateKillSwitch(reason)
        } else {
            // Unconfirmed or not known yet: the next violating check decides, as usual.
            treatViolationAsNew()
        }
    }

    /// Toggled from Settings: install or remove the privileged helper.
    func setKillSwitch(_ on: Bool) async {
        guard on != settings.killSwitch else { return }
        update { $0.killSwitch = on }
        guard on else {
            do {
                try await Privileged.run(KillSwitch.teardownScript, prompt: "Whereabouts needs your admin password to remove the kill switch helper.")
                kill = KillSwitchStatus(reblockAt: kill.reblockAt)
            } catch {
                log.error("Kill switch teardown failed: \(error.localizedDescription)")
            }
            return
        }
        if await installKillSwitchHelper() {
            // Turning it on is an explicit arm: drop any pause from an earlier unblock.
            rearmKillSwitch()
            await refreshKillSwitchState()
        } else {
            update { $0.killSwitch = false }
        }
    }

    @discardableResult
    func installKillSwitchHelper() async -> Bool {
        guard let user = Privileged.sudoUser() else {
            kill.error = "Your account name can't be used in a sudo rule, so the kill switch can't be set up."
            return false
        }
        do {
            try await Privileged.run(KillSwitch.setupScript(user: user),
                                               prompt: "Whereabouts needs your admin password once to set up the kill switch firewall rules. It won't ask again.")
            kill.needsSetup = false
            kill.error = nil
            return true
        } catch {
            if !Privileged.isUserCanceled(error) { log.error("Kill switch setup failed: \(error.localizedDescription)") }
            kill.error = "Kill switch setup was canceled or failed — it needs a one-time admin password to install its firewall rules."
            return false
        }
    }

    /// Reconcile with the real pf state. A crash while blocked leaves the block in place by design.
    func refreshKillSwitchState() async {
        let version = KillSwitch.installedVersion()
        kill.needsSetup = settings.killSwitch && version != KillSwitch.helperVersion
        guard version == KillSwitch.helperVersion,
              let engaged = try? await KillSwitch.sudoHelper("status").trimmingCharacters(in: .whitespacesAndNewlines) == "active"
        else { return }
        if engaged && !kill.active {
            kill.active = true
            kill.reason = kill.reason ?? "Network is still blocked from an earlier session."
        } else if !engaged && kill.active {
            kill.active = false
            kill.reason = nil
        }
    }

    func activateKillSwitch(_ reason: String) async {
        guard !kill.active, !killInFlight, !Demo.enabled else { return }
        // The user unblocked to reconnect; blocking again inside that window would
        // undo their decision. reblockIfStillWrong() takes over when it ends.
        guard !kill.suppressed else {
            log.info("Kill switch trigger ignored — inside the manual unblock window")
            return
        }
        guard pausedUntil == nil else {
            log.info("Kill switch trigger ignored — paused from the menu")
            return
        }
        killInFlight = true
        defer { killInFlight = false }
        do {
            _ = try await KillSwitch.sudoHelper("engage")
            kill.active = true
            kill.reason = reason
            kill.error = nil
            killActivation += 1
            log.warning("Kill switch engaged: \(reason)")
            verifyBlocked(killActivation)
        } catch {
            kill.error = "\(error)".contains("no com.apple anchor point")
                ? "Could not block traffic: /etc/pf.conf is missing its anchor point, so the firewall rules can't be applied."
                : "Could not block traffic — the helper may be missing. Turn the kill switch off and on again to reinstall it."
            log.error("Kill switch engage failed: \(error.localizedDescription)")
            await refreshKillSwitchState()
        }
    }

    /// Confirm from userland that traffic really is dropped: a ruleset that loads
    /// but isn't enforced is the one failure a kill switch must never hide.
    private func verifyBlocked(_ generation: Int) {
        Task {
            let leaking = await anyReachable()
            guard generation == killActivation, kill.active else { return }
            if leaking {
                kill.error = "Traffic is still reaching the internet — the firewall rules loaded but aren't being enforced. Turn the kill switch off and on again to reinstall the helper."
            }
        }
    }

    /// Manual unblock. The kill switch stands down for `reblockDelay` so the VPN can
    /// reconnect, or the next check (still in the wrong place) would re-engage it at once.
    func restoreConnection() async {
        kill.reblockAt = Date().addingTimeInterval(Self.reblockDelay)
        if Demo.enabled { kill.active = false; return }
        reblockTask?.cancel()
        reblockTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.reblockDelay))
            if !Task.isCancelled { await self?.reblockIfStillWrong() }
        }
        guard kill.active, !killInFlight else { return }
        killInFlight = true
        defer { killInFlight = false }
        do {
            _ = try await KillSwitch.sudoHelper("release")
            kill.active = false
            kill.reason = nil
            kill.error = nil
            killActivation += 1
        } catch {
            kill.error = "Failed to lift the block. Run this in Terminal, or reboot: \(KillSwitch.manualUnblockCommand)"
        }
    }

    /// On quit — synchronous so the app can't exit first. A crash still fails closed.
    func releaseKillSwitchOnQuit() {
        // A demo's "engaged" switch is made up; releasing would touch the real firewall.
        guard kill.active, !Demo.enabled else { return }
        do { _ = try runSync("/usr/bin/sudo", ["-n", KillSwitch.helperPath, "release"], timeout: 3) }
        catch { log.error("Failed to lift the kill switch on quit: \(error.localizedDescription)") }
    }
}
