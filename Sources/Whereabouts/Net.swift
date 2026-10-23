import Foundation
import Network
import os

let log = Logger(subsystem: "com.doxigo.Whereabouts", category: "app")

// MARK: - Shell

struct ShellError: Error, LocalizedError {
    let status: Int32
    let output: String
    var errorDescription: String? { "exit \(status): \(output)" }
}

/// Runs a binary and returns stdout. Killed after `timeout`; throws on a non-zero exit.
func runSync(_ path: String, _ args: [String], timeout: TimeInterval) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = args
    let out = Pipe(), err = Pipe()
    process.standardOutput = out
    process.standardError = err
    try process.run()

    let killer = DispatchWorkItem { if process.isRunning { process.terminate() } }
    DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
    // Drain stderr concurrently so a chatty command can't fill a pipe and stall.
    var errData = Data()
    let errDone = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
        errData = err.fileHandleForReading.readDataToEndOfFile()
        errDone.signal()
    }
    let outData = out.fileHandleForReading.readDataToEndOfFile()
    errDone.wait()
    process.waitUntilExit()
    killer.cancel()

    let stdout = String(decoding: outData, as: UTF8.self)
    guard process.terminationStatus == 0 else {
        throw ShellError(status: process.terminationStatus,
                         output: String(decoding: errData, as: UTF8.self) + stdout)
    }
    return stdout
}

func run(_ path: String, _ args: [String], timeout: TimeInterval = 5) async throws -> String {
    try await withCheckedThrowingContinuation { cont in
        DispatchQueue.global().async {
            cont.resume(with: Result { try runSync(path, args, timeout: timeout) })
        }
    }
}

// MARK: - HTTP

struct HTTPError: Error { let status: Int }

/// A fresh ephemeral session per request: a pooled keep-alive connection opened
/// before a VPN switch would otherwise report the old exit.
func fetchData(_ url: String, timeout: TimeInterval = 10) async throws -> Data {
    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = timeout
    config.timeoutIntervalForResource = timeout
    config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
    let session = URLSession(configuration: config)
    defer { session.finishTasksAndInvalidate() }
    var request = URLRequest(url: URL(string: url)!)
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    let (data, response) = try await session.data(for: request)
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    guard status == 200 else { throw HTTPError(status: status) }
    return data
}

func fetchJSON(_ url: String) async throws -> [String: Any] {
    let object = try JSONSerialization.jsonObject(with: try await fetchData(url))
    guard let dict = object as? [String: Any] else { throw HTTPError(status: -1) }
    return dict
}

// MARK: - TCP probe

private final class Once: @unchecked Sendable {
    private var done = false
    private let lock = NSLock()
    func claim() -> Bool { lock.withLock { defer { done = true }; return !done } }
}

/// Connect latency in ms, or nil on failure/timeout. No ICMP, so no root needed.
func tcpProbe(_ host: String, _ port: UInt16, timeout: TimeInterval) async -> Int? {
    await withCheckedContinuation { cont in
        let connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        let once = Once()
        let start = Date()
        let finish: (Int?) -> Void = { result in
            guard once.claim() else { return }
            connection.cancel()
            cont.resume(returning: result)
        }
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready: finish(Int(Date().timeIntervalSince(start) * 1000))
            case .failed, .cancelled, .waiting: finish(nil)
            default: break
            }
        }
        connection.start(queue: .global())
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { finish(nil) }
    }
}

/// Probe raw IPs, never hostnames: a resolver still coming up after wake would look like a dead link.
func anyReachable(_ targets: [(String, UInt16)] = [("1.1.1.1", 443), ("8.8.8.8", 443)],
                  timeout: TimeInterval = 2.5) async -> Bool {
    await withTaskGroup(of: Bool.self) { group in
        for (host, port) in targets { group.addTask { await tcpProbe(host, port, timeout: timeout) != nil } }
        for await ok in group where ok { group.cancelAll(); return true }
        return false
    }
}

// MARK: - Interfaces

/// Interfaces carrying a non-loopback IPv4 address.
func ipv4InterfaceNames() -> [String] {
    var names: [String] = []
    var head: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&head) == 0 else { return [] }
    defer { freeifaddrs(head) }
    var cursor = head
    while let ifa = cursor {
        let flags = Int32(ifa.pointee.ifa_flags)
        if ifa.pointee.ifa_addr?.pointee.sa_family == UInt8(AF_INET), flags & IFF_LOOPBACK == 0 {
            names.append(String(cString: ifa.pointee.ifa_name))
        }
        cursor = ifa.pointee.ifa_next
    }
    return names
}

func isTunnelInterface(_ name: String?) -> Bool {
    guard let name = name?.lowercased() else { return false }
    return ["utun", "ipsec", "ppp", "tun", "tap", "wg"].contains { name.hasPrefix($0) }
}

// MARK: - Geolocation providers

enum Provider { case ipApi, ipWho }

private func string(_ d: [String: Any], _ key: String) -> String? { d[key] as? String }

/// ip-api.com: the only free provider with proxy/hosting (VPN) flags. With an
/// address it geolocates that address instead of this machine's exit.
func fetchIpApi(_ ip: String? = nil) async throws -> Location {
    let path = ip?.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ""
    let d = try await fetchJSON("http://ip-api.com/json/\(path)?fields=status,message,query,country,countryCode,regionName,city,isp,proxy,hosting,timezone,lat,lon")
    guard string(d, "status") == "success" else { throw HTTPError(status: -2) }
    let proxy = d["proxy"] as? Bool, hosting = d["hosting"] as? Bool
    return Location(ip: string(d, "query"), country: string(d, "country"),
                    countryCode: string(d, "countryCode")?.uppercased(), region: string(d, "regionName"), city: string(d, "city"),
                    isp: string(d, "isp"),
                    isVpn: proxy == nil && hosting == nil ? nil : (proxy ?? false) || (hosting ?? false),
                    timeZone: string(d, "timezone"), lat: d["lat"] as? Double, lon: d["lon"] as? Double)
}

/// ipwho.is over HTTPS — no VPN detection.
func fetchIpWho(_ ip: String? = nil) async throws -> Location {
    let path = ip?.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ""
    let d = try await fetchJSON("https://ipwho.is/\(path)")
    guard d["success"] as? Bool != false else { throw HTTPError(status: -2) }
    let connection = d["connection"] as? [String: Any] ?? [:]
    return Location(ip: string(d, "ip"), country: string(d, "country"),
                    countryCode: string(d, "country_code")?.uppercased(), region: string(d, "region"), city: string(d, "city"),
                    isp: string(connection, "isp") ?? string(connection, "org"), isVpn: nil,
                    timeZone: (d["timezone"] as? [String: Any]).flatMap { string($0, "id") },
                    lat: d["latitude"] as? Double, lon: d["longitude"] as? Double)
}

// ponytail: one entry per network ever looked up (a handful a day); prune if that ever matters.
@MainActor private var geolocated: [String: (at: Date, location: Location)] = [:]

/// The /24 (IPv4) or /48 (IPv6) an address sits in: one operator, one location. A public
/// resolver's egress hops between addresses there on nearly every lookup.
func networkKey(_ ip: String) -> String {
    ip.contains(":") ? ip.split(separator: ":", omittingEmptySubsequences: false).prefix(3).joined(separator: ":")
        : ip.split(separator: ".").prefix(3).joined(separator: ".")
}

/// Geolocate any address (leak checks). HTTPS first — a leak verdict shouldn't rest on plaintext.
/// Kept an hour per network: the leak checks ask about the same few every minute, and only
/// read the place and provider, which the whole network shares.
@MainActor func geolocate(_ ip: String) async -> Location? {
    let key = networkKey(ip)
    if let hit = geolocated[key], hit.at.timeIntervalSinceNow > -3600 { return hit.location }
    var location = try? await fetchIpWho(ip)
    if location == nil { location = try? await fetchIpApi(ip) }
    if let location { geolocated[key] = (Date(), location) }
    return location
}

/// Provider names drift ("Mullvad VPN AB" vs "Mullvad"), so match a fragment either way.
func ispMatches(_ isp: String?, _ expected: [String]) -> Bool {
    guard let value = isp?.trimmingCharacters(in: .whitespaces).lowercased(), !value.isEmpty else { return false }
    return expected.contains { entry in
        let needle = entry.trimmingCharacters(in: .whitespaces).lowercased()
        return !needle.isEmpty && (value.contains(needle) || needle.contains(value))
    }
}

// MARK: - VPN name

private let vpnClients: [(prefixes: [String], name: String)] = [
    (["mullvad"], "Mullvad VPN"), (["tailscale"], "Tailscale"), (["wireguard", "wg-"], "WireGuard"),
    (["nordvpn"], "NordVPN"), (["expressvpn"], "ExpressVPN"), (["protonvpn"], "Proton VPN"),
    (["surfshark"], "Surfshark"), (["cloudflarewarp", "warp-svc"], "Cloudflare WARP"),
    (["windscribe"], "Windscribe"), (["pia-", "private internet access"], "Private Internet Access"),
    (["openvpn"], "OpenVPN"),
]

/// The connected VPN's name. IP providers only flag "looks like a proxy", so this
/// asks the machine: a connected network service first (system VPNs and
/// NetworkExtension clients), then a known client process — but only while a
/// tunnel really carries an IPv4, so an idle client is never reported as connected.
func activeVpnName() async -> String? {
    if let list = try? await run("/usr/sbin/scutil", ["--nc", "list"], timeout: 4) {
        for line in list.split(separator: "\n") where line.contains("(Connected)") {
            if let name = line.split(separator: "\"", omittingEmptySubsequences: false).dropFirst().first, !name.isEmpty {
                return String(name)
            }
        }
    }
    guard let tunnel = ipv4InterfaceNames().first(where: isTunnelInterface) else { return nil }
    if let ps = try? await run("/bin/ps", ["-Ac", "-o", "comm="], timeout: 4) {
        let processes = ps.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        for client in vpnClients where processes.contains(where: { p in client.prefixes.contains { p.hasPrefix($0) } }) {
            return client.name
        }
    }
    return tunnel
}
