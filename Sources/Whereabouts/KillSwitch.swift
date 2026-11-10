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
// argument-less subcommands, plus `hold`, which checks its own arguments; every
// trigger after that is a silent `sudo -n`.

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
    static let helperVersion = 5
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
    # macOS sudo keeps the caller's PATH (no secure_path), so without this any program
    # running as the user could plant its own grep or rm and run it as root.
    export PATH=/usr/bin:/bin:/usr/sbin:/sbin

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
    WA_RULES
      # A hold for sleep also lets through VPN tunnels and the addresses it was given.
      [ -n "${HOLD_RULES:-}" ] && printf '%s\n' "$HOLD_RULES"
      # Everything else - the internet, including any VPN tunnel outside a hold - is dropped.
      if [ "${mode:-}" = verify ]; then echo 'block drop quick all label "whereabouts-verify"'
      else echo 'block drop quick all'; fi
    }

    load_rules() {
      # Without the anchor point our rules would load but never be evaluated.
      if ! $PFCTL -s rules 2>/dev/null | grep -qF 'anchor "com.apple/*"'; then
        echo "whereabouts: /etc/pf.conf has no com.apple anchor point" >&2
        exit 5
      fi
      if ! RULE_ERROR=$(emit_rules | $PFCTL -a "$ANCHOR" -f - 2>&1); then
        echo "whereabouts: failed to load pf block rules: $RULE_ERROR" >&2
        exit 3
      fi
      # pf enable is reference counted; hold our own token so other pf users
      # (Internet Sharing, the app firewall) are never disturbed. The token file
      # outlives its reference when the Mac reboots or loses power while blocked,
      # so ask again whenever pf isn't actually on; release drops every token listed.
      # ponytail: a stale token is trusted while someone else keeps pf on. Check
      # `pfctl -s References` for it if that ever lets a block lapse.
      if [ ! -s "$TOKEN_FILE" ] || ! $PFCTL -s info 2>/dev/null | grep -qF "Status: Enabled"; then
        TOKEN=$($PFCTL -E 2>&1 | awk '/Token/ { print $NF }' | tail -n 1)
        if [ -n "$TOKEN" ]; then
          echo "$TOKEN" >> "$TOKEN_FILE"
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
    }

    case "${1:-}" in
      engage)
        load_rules
        ;;
      hold|verify)
        # The Mac is going to sleep: block, but let a VPN reconnect and the app check where
        # it is. Tunnels pass whole (what goes in still leaves through the physical interface,
        # where only the given addresses pass). "flags any" keeps a flow alive after the flush.
        # "dns:<address>" passes only DNS to it, so the app's lookups can resolve.
        mode="$1"
        shift
        [ $# -le 64 ] || { echo "whereabouts: too many addresses" >&2; exit 2; }
        HOLD_RULES=""
        if [ "$mode" = hold ]; then
          HOLD_RULES="pass quick on { $(echo utun{0..31} ipsec{0..3} ppp{0..3}) } all flags any"
        fi
        for arg in "$@"; do
          addr="${arg#dns:}"
          addr="${addr#vpn:}"
          if [[ "$addr" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then family=inet
          elif [[ "$addr" =~ ^[0-9A-Fa-f:]{2,39}$ && "$addr" == *:* ]]; then family=inet6
          else echo "whereabouts: invalid address" >&2; exit 2
          fi
          if [[ "$arg" == dns:* ]]; then
            HOLD_RULES+=$'\n'"pass quick $family proto udp from any to $addr port 53"$'\n'"pass quick $family proto tcp from any to $addr port 53 flags any"
          elif [ "$mode" = verify ] && [[ "$arg" != vpn:* ]]; then
            HOLD_RULES+=$'\n'"pass quick $family proto tcp from any to $addr port 443 flags any"
          else
            HOLD_RULES+=$'\n'"pass quick $family from any to $addr flags any"$'\n'"pass quick $family from $addr to any flags any"
          fi
        done
        load_rules
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
        RULES=$($PFCTL -a "$ANCHOR" -s rules 2>/dev/null)
        if echo "$RULES" | grep -qF "whereabouts-verify"; then
          echo verifying
        elif echo "$RULES" | grep -qF "block drop quick"; then
          echo active
        else
          echo inactive
        fi
        ;;
      *)
        echo "Usage: $0 {engage|hold [address...]|verify [address...]|release|status}" >&2
        exit 1
        ;;
    esac
    """#

    static func setupScript(user: String) -> String {
        let helper = Privileged.sudoersPath(helperPath)
        return Privileged.installScript(helperPath: helperPath, helper: helperScript, sudoersPath: sudoersPath,
                                        grants: ["engage", "hold", "hold *", "verify", "verify *", "release", "status"].map { "\(user) ALL=(root) NOPASSWD: \(helper) \($0)" })
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

    /// Whether the helper takes `address`, by its own test: a dotted quad, or IPv6 written in hex digits
    /// and colons alone. Foundation takes more ("fe80::1%en0", "::ffff:192.0.2.1"), and one address the
    /// helper refuses fails the whole hold.
    static func accepts(_ address: String) -> Bool {
        isIPAddress(address) && address.wholeMatch(of: /([0-9]{1,3}\.){3}[0-9]{1,3}|[0-9A-Fa-f:]{2,39}/) != nil
    }

    /// What a hold lets through: the location lookups, DNS to public resolvers (the local
    /// network's pass already), and, while a tunnel carries the connection, the VPN's server.
    /// Blocking discovery, prepared off the main thread before sleep.
    static func dnsAddresses() -> [String] {
        (try? runSync("/usr/sbin/scutil", ["--dns"], timeout: 3)).map(dnsHoldAddresses) ?? []
    }

    static func holdAddresses(strict: Bool = false) -> [String] {
        let lookups = ["api.ipify.org", "ipv4.icanhazip.com", "ipwho.is", "ipapi.co"].flatMap(resolveAddresses)
        var passed = dnsAddresses() + lookups
        if let probe = lookups.first(where: { !$0.contains(":") }),
           let route = try? runSync("/sbin/route", ["-n", "get", probe], timeout: 3),
           isTunnelInterface(route.firstMatch(of: /interface: (\S+)/).map { String($0.1) }) {
            // -l: without it netstat cuts an IPv6 address to 16 characters, which matches no local address.
            let netstat = ["inet", "inet6"].compactMap { try? runSync("/usr/sbin/netstat", ["-anl", "-f", $0], timeout: 3) }.joined()
            passed += directPeers(netstat, local: Set(physicalAddresses())).filter { !lookups.contains($0) }.map { strict ? "vpn:\($0)" : $0 }
        }
        return Array(passed.prefix(64)) // the helper's limit
    }
}

/// The `dns:` arguments for a hold, from `scutil --dns`: the default resolvers, but not a proxy on this
/// Mac or an address the helper refuses. A link-local one ("fe80::1%en0") is on the local network, which passes anyway.
func dnsHoldAddresses(_ scutil: String) -> [String] {
    let resolvers = parseResolvers(scutil).first { $0.scopedDomain == nil }?.nameservers ?? []
    return resolvers.filter { KillSwitch.accepts($0) && !isLoopbackAddress($0) }.prefix(4).map { "dns:\($0)" }
}

/// The public peers this Mac reaches from a physical interface's own address, from `netstat -anl`.
/// While a tunnel carries the connection, that's the VPN's server, plus whatever bypasses the VPN anyway.
// ponytail: a VPN on an unconnected socket (wireguard-go) shows no peer here, so a hold can't let it reconnect.
func directPeers(_ netstat: String, local: Set<String>) -> [String] {
    // "192.0.2.1.443" → "192.0.2.1"; "*.*" and "*.5353" have no address.
    func address(_ field: Substring) -> String? {
        guard !field.hasPrefix("*"), let dot = field.lastIndex(of: ".") else { return nil }
        return String(field[..<dot])
    }
    var peers: [String] = []
    for line in netstat.split(separator: "\n") {
        let fields = line.split(separator: " ")
        guard fields.count >= 5, fields[0].hasPrefix("tcp") || fields[0].hasPrefix("udp"),
              let mine = address(fields[3]), local.contains(mine),
              let peer = address(fields[4]), KillSwitch.accepts(peer), !isPrivateAddress(peer), !peers.contains(peer) else { continue }
        peers.append(peer)
    }
    return peers
}

/// Numeric addresses of every interface that isn't loopback or a tunnel.
private func physicalAddresses() -> [String] {
    var addresses: [String] = []
    var head: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&head) == 0 else { return [] }
    defer { freeifaddrs(head) }
    for ifa in sequence(first: head, next: { $0?.pointee.ifa_next }) {
        guard let ifa, let addr = ifa.pointee.ifa_addr, Int32(ifa.pointee.ifa_flags) & IFF_LOOPBACK == 0,
              !isTunnelInterface(String(cString: ifa.pointee.ifa_name)), let text = numericHost(addr) else { continue }
        addresses.append(text)
    }
    return addresses
}

private func resolveAddresses(_ host: String) -> [String] {
    var hints = addrinfo()
    hints.ai_socktype = SOCK_STREAM
    var head: UnsafeMutablePointer<addrinfo>?
    guard getaddrinfo(host, nil, &hints, &head) == 0 else { return [] }
    defer { freeaddrinfo(head) }
    var addresses: [String] = []
    for ai in sequence(first: head, next: { $0?.pointee.ai_next }) {
        if let addr = ai?.pointee.ai_addr, let text = numericHost(addr), !addresses.contains(text) { addresses.append(text) }
    }
    return addresses
}

private func numericHost(_ addr: UnsafePointer<sockaddr>) -> String? {
    guard [AF_INET, AF_INET6].contains(Int32(addr.pointee.sa_family)) else { return nil }
    var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
    guard getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { return nil }
    return String(cString: host)
}

extension Monitor {
    func cancelVerificationSetup() async {
        verificationTask?.cancel()
        while killInFlight { try? await Task.sleep(for: .milliseconds(50)) }
    }

    func reconcileStrictSetting() async {
        if !settings.strictProtection {
            await cancelVerificationSetup()
            if kill.verifying && (geo.kind != .violation || geo.confirmed == false) { await releaseHold() }
        }
        await reconcileProtection()
    }

    func engageVerificationHold() async {
        if let task = verificationTask { await task.value; return }
        guard settings.killSwitch, settings.strictProtection, !kill.suppressed, pausedUntil == nil,
              !killInFlight, !Demo.enabled, !kill.active || kill.held else { return }
        if kill.verifying && verificationGeneration == pathChanges { return }
        let generation = pathChanges
        let task = Task { await configureVerificationHold(generation) }
        verificationTask = task
        await task.value
        verificationTask = nil
        if generation != pathChanges && settings.strictProtection { await reconcileProtection() }
    }

    private func configureVerificationHold(_ generation: Int) async {
        do {
            try await loadVerificationRules([])
            kill.active = true
            kill.held = true
            kill.verifying = true
            kill.reason = "Strict protection: waiting for an allowed location check."
            kill.error = nil
            killActivation += 1
            recordProtection("Firewall", "Restricted internet while verifying the connection.")
            for dnsOnly in [true, false] {
                let addresses = await verificationAddresses(dnsOnly)
                guard generation == pathChanges, settings.strictProtection, settings.killSwitch,
                      kill.held, kill.verifying, !killInFlight, !kill.suppressed, pausedUntil == nil, !Task.isCancelled else { return }
                try await loadVerificationRules(addresses)
            }
            verificationGeneration = generation
            if !testing { verifyBlocked(killActivation) }
        } catch {
            guard settings.killSwitch, settings.strictProtection, !killInFlight, !kill.suppressed, !Task.isCancelled else { return }
            // Older helpers can still fail closed, but need an upgrade to allow verification.
            do {
                killInFlight = true
                defer { killInFlight = false }
                _ = try await firewall("engage")
                kill.active = true
                kill.held = false
                kill.verifying = false
                kill.reason = "Strict protection blocked traffic because verification rules failed."
                kill.error = "Verification could not be set up. Use Unblock Now, then Set Up Now to update the firewall helper."
            } catch {
                kill.error = "Strict protection could not block traffic. Set up the kill switch helper before relying on it."
            }
            recordProtection("Firewall error", kill.error ?? "Verification failed.")
        }
    }

    private func loadVerificationRules(_ addresses: [String]) async throws {
        killInFlight = true
        defer { killInFlight = false }
        try await verificationFirewall(addresses)
    }

    /// A paused kill switch re-arms only once every reporting monitor is clear —
    /// i.e. you fixed it, not that the check failed while the network reconnects.
    func reportTriggerState(_ source: String, _ state: TriggerState) {
        triggerStates[source] = state
        guard kill.suppressed, !triggerStates.isEmpty, triggerStates.values.allSatisfy({ $0 == .clear }) else { return }
        kill.reblockAt = nil
        log.info("Kill switch re-armed — every monitor is clear again")
    }

    func rearmKillSwitch() {
        kill.reblockAt = nil
        reblockTask?.cancel()
        recordProtection("Firewall", "Protection re-armed.")
        if !testing { Task { await checkAll(); await reconcileProtection() } }
    }

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
        if settings.strictProtection { await reconcileProtection(); return }
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
            await cancelVerificationSetup()
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
            await refreshKillSwitchState()
            rearmKillSwitch()
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
              let state = try? await KillSwitch.sudoHelper("status").trimmingCharacters(in: .whitespacesAndNewlines),
              ["active", "verifying", "inactive"].contains(state)
        else { return }
        let engaged = state != "inactive"
        if state == "verifying" { kill.held = true; kill.verifying = true }
        if engaged && !kill.active {
            kill.active = true
            kill.reason = kill.reason ?? "Network is still blocked from an earlier session."
        } else if !engaged && kill.active {
            kill.active = false
            kill.held = false
            kill.verifying = false
            kill.reason = nil
        }
    }

    func activateKillSwitch(_ reason: String) async {
        // A hold for sleep is a block already, but it lets VPN tunnels through: this one doesn't.
        guard settings.killSwitch, !kill.active || kill.held, !killInFlight, !Demo.enabled else { return }
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
            _ = try await firewall("engage")
            kill.active = true
            kill.held = false
            kill.verifying = false
            kill.reason = reason
            kill.error = nil
            killActivation += 1
            log.warning("Kill switch engaged: \(reason)")
            recordProtection("Firewall", "Blocked traffic: \(reason)")
            if !testing { verifyBlocked(killActivation) }
        } catch {
            kill.error = "\(error)".contains("no com.apple anchor point")
                ? "Could not block traffic: /etc/pf.conf is missing its anchor point, so the firewall rules can't be applied."
                : "Could not block traffic — the helper may be missing. Turn the kill switch off and on again to reinstall it."
            log.error("Kill switch engage failed: \(error.localizedDescription)")
            recordProtection("Firewall error", kill.error ?? "Blocking failed.")
            if !testing { await refreshKillSwitchState() }
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
        await cancelVerificationSetup()
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
            _ = try await firewall("release")
            kill.active = false
            kill.held = false
            kill.verifying = false
            kill.reason = nil
            kill.error = nil
            killActivation += 1
            recordProtection("Firewall", "Manually unblocked for two minutes.")
        } catch {
            kill.error = "Failed to lift the block. Run this in Terminal, or reboot: \(KillSwitch.manualUnblockCommand)"
        }
    }

    /// Going to sleep: block until the first check after waking finds the location allowed, so
    /// nothing reconnects over a bare connection before the VPN does. The VPN and the app's own
    /// lookups still get through. Synchronous: macOS waits for this notification's observers.
    func holdForSleep() {
        guard settings.killSwitch, settings.holdOnWake || settings.strictProtection, !kill.active, !kill.suppressed, pausedUntil == nil,
              !killInFlight, !Demo.enabled, testing || KillSwitch.installedVersion() == KillSwitch.helperVersion else { return }
        let addresses = preparedHoldAddresses
        do {
            if settings.strictProtection { try strictSleepFirewall(addresses) }
            else { try holdFirewall(addresses) }
        } catch {
            kill.error = "Could not hold the network for sleep. Turn the kill switch off and on again to reinstall its helper."
            log.error("Sleep hold failed: \(error.localizedDescription)")
            return
        }
        kill.active = true
        kill.held = true
        kill.verifying = settings.strictProtection
        kill.reason = "Held since your Mac went to sleep, until a check finds your location allowed."
        kill.error = nil
        killActivation += 1
        // The last answer is from before sleep; the next one decides.
        markChecking("Mac is going to sleep.")
        recordProtection("Firewall", "Held the network for sleep.")
        log.info("Network held for sleep, letting \(addresses.count) addresses through")
    }

    /// The first check after waking found the location allowed.
    func releaseHold() async {
        guard kill.held, !killInFlight else { return }
        killInFlight = true
        defer { killInFlight = false }
        do {
            _ = try await firewall("release")
            kill.active = false
            kill.held = false
            kill.verifying = false
            kill.reason = nil
            kill.error = nil
            killActivation += 1
            log.info("Sleep hold lifted — your location is allowed")
            recordProtection("Firewall", "Verification hold released.")
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
