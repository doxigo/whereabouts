import Foundation

// Leak checks: the paths that bypass a VPN even when the IPv4 exit looks
// perfect — IPv6 traffic, UDP (what WebRTC shows a page) and DNS queries. Each is
// judged against the current IPv4 exit, and they deliberately never engage the kill
// switch: a verdict drawn from a resolver list can't justify cutting someone's internet.

// Anycast resolvers geolocate to the nearest edge node, not a path, so country
// alone never makes them a leak.
private let globalResolvers: Set<String> = [
    "1.1.1.1", "1.0.0.1", "8.8.8.8", "8.8.4.4", "9.9.9.9", "149.112.112.112",
    "208.67.222.222", "208.67.220.220", "94.140.14.14", "94.140.15.15",
    "2606:4700:4700::1111", "2606:4700:4700::1001", "2001:4860:4860::8888", "2001:4860:4860::8844", "2620:fe::fe",
]

struct ResolverBlock: Equatable {
    var nameservers: [String] = []
    var iface: String?
    /// Split-DNS entries serve one domain only, so they aren't the default.
    var scopedDomain: String?
}

/// Default resolver blocks from `scutil --dns` (the section above the scoped ones).
func parseResolvers(_ output: String) -> [ResolverBlock] {
    let head = output.components(separatedBy: "DNS configuration (for scoped queries)")[0]
    var blocks: [ResolverBlock] = []
    for raw in head.split(separator: "\n") {
        let line = raw.trimmingCharacters(in: .whitespaces)
        if line.wholeMatch(of: /resolver #\d+/) != nil {
            blocks.append(ResolverBlock())
        } else if blocks.isEmpty {
            continue
        } else if let m = line.wholeMatch(of: /nameserver\[\d+\]\s*:\s*(\S+)/) {
            blocks[blocks.count - 1].nameservers.append(String(m.1))
        } else if let m = line.firstMatch(of: /^if_index\s*:\s*\d+\s*\(([^)]+)\)/) {
            blocks[blocks.count - 1].iface = String(m.1)
        } else if let m = line.wholeMatch(of: /domain\s*:\s*(\S+)/) {
            blocks[blocks.count - 1].scopedDomain = String(m.1)
        }
    }
    return blocks.filter { !$0.nameservers.isEmpty }
}

/// Reachable only on the LAN or a tunnel's own subnet — a router or a VPN-internal resolver.
func isPrivateAddress(_ address: String) -> Bool {
    let value = address.lowercased()
    if value.contains(":") {
        return value == "::1" || ["fc", "fd", "fe8", "fe9", "fea", "feb"].contains { value.hasPrefix($0) }
    }
    let parts = value.split(separator: ".").compactMap { Int($0) }
    guard parts.count == 4 else { return false }
    let (a, b) = (parts[0], parts[1])
    return a == 0 || a == 10 || a == 127 || (a == 169 && b == 254) || (a == 172 && (16...31).contains(b))
        || (a == 192 && b == 168)
        // 100.64.0.0/10 (carrier-grade NAT) is what many VPNs use for their resolver.
        || (a == 100 && (64...127).contains(b))
}

private let cloudflareResolvers: Set<String> = ["1.1.1.1", "1.0.0.1", "2606:4700:4700::1111", "2606:4700:4700::1001"]

/// The `dig` question that makes `resolver` say where lookups reach it from. Google's names the
/// client subnet a resolver passes on, but Cloudflare passes none, so Google would only see
/// Cloudflare; Cloudflare's own whoami names the client.
func egressQuery(_ resolver: String) -> [String] {
    cloudflareResolvers.contains(resolver.lowercased()) ? ["@\(resolver)", "ch", "txt", "whoami.cloudflare"] : ["txt", "o-o.myaddr.l.google.com"]
}

/// The address a lookup reaches the internet from, from `dig +short` with `egressQuery`: the client
/// subnet a resolver passes on (ECS) if any, else the one address it names.
func dnsEgress(_ digOutput: String) -> String? {
    let values = digOutput.split(separator: "\n").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\" ")) }
    if let ecs = values.first(where: { $0.hasPrefix("edns0-client-subnet ") }) {
        return ecs.dropFirst("edns0-client-subnet ".count).split(separator: "/").first.map(String.init)
    }
    return values.first { !$0.isEmpty && !$0.hasPrefix(";") }
}

/// A resolver on this Mac itself: a DNS proxy (Cloudflare WARP, NextDNS, dnscrypt-proxy) that forwards queries on its own.
func isLoopbackAddress(_ address: String) -> Bool { address == "::1" || address.hasPrefix("127.") }

extension Monitor {
    func checkLeaks() async {
        guard !leakInFlight else { return }
        leakInFlight = true
        defer { leakInFlight = false }
        let baseline = geo.location
        async let ipv6 = checkIpv6(baseline)
        async let udp = checkUdp(baseline)
        async let dns = checkDns(baseline)
        leak = LeakStatus(ipv6: await ipv6, udp: await udp, dns: await dns)
        announceLeaks()
    }

    private func checkIpv6(_ baseline: Location?) async -> ExitCheck {
        guard settings.ipv6Check else { return ExitCheck(state: .off, message: "IPv6 leak check is off.") }

        // AAAA-only hosts: an answer proves real IPv6 egress and shows the address the internet sees.
        // Then dual-stack ones: a proxy on the way reaches those over IPv6 even when this Mac has none.
        var ip: String?
        for url in ["https://api6.ipify.org?format=json", "https://ipv6.icanhazip.com",
                    "https://api64.ipify.org?format=json", "https://icanhazip.com"] where ip == nil {
            guard let data = try? await fetchData(url, timeout: 6) else { continue }
            let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            let value = text.hasPrefix("{")
                ? ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["ip"] as? String
                : text
            // No colon isn't IPv6 — an IPv4 echo would be a false "you have IPv6".
            if let value, value.contains(":") { ip = value }
        }
        guard let ip else { return ExitCheck(state: .none, message: "No IPv6 connectivity — nothing can leak over IPv6.") }

        let located = await geolocate(ip)
        var check = ExitCheck(state: .unknown, ip: ip, isp: located?.isp, message: "")
        guard let located, let code = located.countryCode else {
            check.message = "You have IPv6 (\(ip)) but its location couldn't be resolved."
            return check
        }
        guard let baseline, let baseCode = baseline.countryCode else {
            check.message = "IPv6 exits in \(located.place) — waiting on an IPv4 result to compare against."
            return check
        }
        if code != baseCode {
            check.state = .leak
            check.message = "IPv6 traffic exits in \(located.place) while IPv4 exits in \(baseline.place) — your IPv6 is bypassing the tunnel."
        } else if settings.ispMode == .allowlist, !settings.expectedIsps.isEmpty, let isp = located.isp,
                  !ispMatches(isp, settings.expectedIsps) {
            // Same country, different provider: the "VPN only tunnels IPv4" case.
            check.state = .leak
            check.message = "IPv6 exits in \(located.place) through \(isp), which isn't one of your expected providers."
        } else {
            check.state = .ok
            check.message = "IPv6 exits in \(located.place), same as IPv4."
        }
        return check
    }

    /// Asks two STUN servers, since a proxy can send each connection out a different address.
    private func checkUdp(_ baseline: Location?) async -> ExitCheck {
        guard settings.udpCheck else { return ExitCheck(state: .off, message: "UDP leak check is off.") }
        let seen = await withTaskGroup(of: String?.self) { group in
            for (host, port) in [("stun.l.google.com", UInt16(19302)), ("stun.cloudflare.com", 3478)] {
                group.addTask { await stunAddress(host, port) }
            }
            var seen: [String] = []
            for await ip in group { if let ip, !seen.contains(ip) { seen.append(ip) } }
            return seen
        }
        guard !seen.isEmpty else {
            return ExitCheck(state: .none, message: "No STUN server answered over UDP, so WebRTC has no address to show sites.")
        }
        guard let baseline, let exitIp = baseline.ip, let exitCode = baseline.countryCode else {
            return ExitCheck(state: .unknown, ip: seen.joined(separator: ", "),
                             message: "UDP leaves from \(seen.joined(separator: ", ")). Waiting on an IPv4 result to compare against.")
        }
        let others = seen.filter { $0 != exitIp }
        guard !others.isEmpty else {
            return ExitCheck(state: .ok, ip: exitIp, isp: baseline.isp, message: "UDP leaves from your IP address too, so WebRTC shows sites nothing new.")
        }
        var places: [Location] = []
        for other in others {
            guard let located = await geolocate(other), let code = located.countryCode else { continue }
            if code != exitCode {
                return ExitCheck(state: .leak, ip: other, isp: located.isp,
                                 message: "UDP leaves from \(other) in \(located.place) while your IP exits in \(baseline.place). WebRTC shows sites that address: UDP is bypassing the tunnel.")
            }
            if settings.ispMode == .allowlist, !settings.expectedIsps.isEmpty, let isp = located.isp, !ispMatches(isp, settings.expectedIsps) {
                return ExitCheck(state: .leak, ip: other, isp: isp,
                                 message: "UDP leaves from \(other) in \(located.place) through \(isp), which isn't one of your expected providers.")
            }
            places.append(located)
        }
        let list = others.joined(separator: ", ")
        guard let place = places.first else {
            return ExitCheck(state: .unknown, ip: list, message: "UDP leaves from \(list), not your IP address, and its location couldn't be resolved.")
        }
        // Same place, but a page sees two addresses for one visitor: a proxy sending UDP, or each connection, out another way.
        return ExitCheck(state: .differs, ip: list, isp: place.isp,
                         message: "UDP leaves from \(list), not \(exitIp), though in \(place.place) too. WebRTC shows sites both addresses, which gives a proxy away. Send everything out one address, or seal WebRTC in Alibi.")
    }

    private func checkDns(_ baseline: Location?) async -> DnsCheck {
        guard settings.dnsCheck else { return DnsCheck(state: .off, message: "DNS leak check is off.") }
        guard let output = try? await run("/usr/sbin/scutil", ["--dns"]) else {
            return DnsCheck(state: .unknown, message: "Couldn't read the system DNS configuration.")
        }
        let blocks = parseResolvers(output)
        guard let block = blocks.first(where: { $0.scopedDomain == nil }) ?? blocks.first else {
            return DnsCheck(state: .unknown, message: "No DNS resolvers are configured.")
        }

        let iface = block.iface
        let tunnel = isTunnelInterface(iface)
        var resolvers = block.nameservers.prefix(3).map {
            DnsResolver(address: $0, iface: iface, isPrivate: isPrivateAddress($0))
        }
        // Only public addresses geolocate (anycast ones only to their registry), and the first two answer the question.
        for i in resolvers.indices.filter({ !resolvers[$0].isPrivate && !globalResolvers.contains(resolvers[$0].address.lowercased()) }).prefix(2) {
            guard let l = await geolocate(resolvers[i].address) else { continue }
            resolvers[i].country = l.country
            resolvers[i].countryCode = l.countryCode
            resolvers[i].isp = l.isp
        }

        let list = resolvers.map(\.address).joined(separator: ", ")
        // A router resolver is normal without a VPN and a leak with one.
        let vpnLikely = baseline.map { $0.isVpn == true
            || (settings.ispMode == .allowlist && !settings.expectedIsps.isEmpty && ispMatches($0.isp, settings.expectedIsps)) } ?? false

        if tunnel {
            return DnsCheck(state: .ok, resolvers: resolvers, message: "DNS queries go through your VPN tunnel (\(list) via \(iface ?? "tunnel")).")
        }
        // The settings only hint; a lookup that reports where it left from settles it. Leaving through
        // the VPN's own provider means DNS rides the tunnel, e.g. a VPN on the router that intercepts it.
        if vpnLikely, let baseline, let exitIsp = baseline.isp,
           let out = try? await run("/usr/bin/dig", ["+short", "+time=3", "+tries=1"] + egressQuery(resolvers[0].address), timeout: 8),
           let egress = dnsEgress(out), let via = await geolocate(egress), sameNetwork(via, baseline) {
            return DnsCheck(state: .ok, resolvers: resolvers,
                            message: "DNS goes to \(list), and lookups leave from \(egress) (\(via.isp ?? exitIsp)), the same provider as your VPN exit, so they ride the tunnel.")
        }
        let primary = resolvers[0]
        // Where a local proxy sends queries (usually encrypted, often through the tunnel) isn't in scutil.
        if isLoopbackAddress(primary.address) {
            return DnsCheck(state: .inconclusive, resolvers: resolvers,
                            message: "DNS goes to a proxy on this Mac (\(list)), like the one Cloudflare WARP or NextDNS runs. It forwards queries itself, so Whereabouts can't see where they end up.")
        }
        if primary.isPrivate {
            return vpnLikely
                ? DnsCheck(state: .leak, resolvers: resolvers, message: "Your VPN is up but DNS goes to \(list) on \(iface ?? "your local network") — queries are resolved outside the tunnel.")
                : DnsCheck(state: .inconclusive, resolvers: resolvers, message: "DNS goes to your local network (\(list)). No VPN is detected, so there's no tunnel for queries to escape.")
        }
        let anycast = resolvers.contains { globalResolvers.contains($0.address.lowercased()) }
        let exitCode = baseline?.countryCode
        if !anycast, vpnLikely, let code = primary.countryCode, let exitCode, code != exitCode {
            let who = primary.isp.map { " (\($0))" } ?? ""
            return DnsCheck(state: .leak, resolvers: resolvers,
                            message: "DNS goes to \(primary.address)\(who) in \(primary.country ?? code), while your IP exits in \(baseline?.place ?? exitCode) — your queries are resolved outside the tunnel.")
        }
        let whereText = primary.country.map { " in \($0)" } ?? ""
        return DnsCheck(state: .inconclusive, resolvers: resolvers,
                        message: "DNS goes to \(list)\(whereText), configured on \(iface ?? "a physical interface") rather than a tunnel — Whereabouts can't confirm whether the queries ride your VPN.")
    }

    /// Every open leak-check issue, for the status window's hero and the menu's header: leaks, and UDP
    /// from another address in the same place, which isn't a leak but still shows sites two addresses.
    var connectionIssues: [String] {
        (leaking ? [leakHeadline] : []) + (leak.udp.state == .differs ? ["UDP leaves from another address"] : [])
    }

    var leakHeadline: String {
        let paths = [("DNS", leak.dns.state == .leak), ("IPv6", leak.ipv6.state == .leak), ("UDP", leak.udp.state == .leak)].filter(\.1).map(\.0)
        return "\(ListFormatter.localizedString(byJoining: paths.isEmpty ? ["DNS"] : paths)) leak"
    }

    /// Notifies once per distinct leak; the menu bar shows it for as long as it lasts.
    private func announceLeaks() {
        let messages = [leak.ipv6.state == .leak ? leak.ipv6.message : nil, leak.udp.state == .leak ? leak.udp.message : nil,
                        leak.dns.state == .leak ? leak.dns.message : nil]
            .compactMap { $0 }
        guard !messages.isEmpty else { leakAlertKey = nil; return }
        let key = messages.joined(separator: "|")
        guard key != leakAlertKey else { return }
        leakAlertKey = key
        log.warning("Leak detected: \(key)")
        notify(leakHeadline, messages.joined(separator: " "), sound: true, topic: "leak")
    }
}
