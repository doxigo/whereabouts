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

    let killer = DispatchWorkItem {
        guard process.isRunning else { return }
        process.terminate()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.25) {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
    }
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

private final class HTTPSOnly: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(request.url?.scheme == "https" ? request : nil)
    }
}

/// A fresh ephemeral session per request: a pooled keep-alive connection opened
/// before a VPN switch would otherwise report the old exit.
func fetchData(_ url: String, timeout: TimeInterval = 10) async throws -> Data {
    guard let url = URL(string: url), url.scheme == "https" else { throw URLError(.secureConnectionFailed) }
    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = timeout
    config.timeoutIntervalForResource = timeout
    config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
    let session = URLSession(configuration: config, delegate: HTTPSOnly(), delegateQueue: nil)
    defer { session.finishTasksAndInvalidate() }
    var request = URLRequest(url: url)
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

// MARK: - STUN

private let stunCookie: [UInt8] = [0x21, 0x12, 0xA4, 0x42]

/// A STUN binding request (RFC 5389), the question WebRTC asks: which address did this come from?
func stunRequest(_ transaction: [UInt8]) -> Data { Data([0x00, 0x01, 0x00, 0x00] + stunCookie + transaction) }

/// The address in a STUN server's answer to `transaction`: XOR-MAPPED-ADDRESS, or the older MAPPED-ADDRESS
/// that some NATs rewrite. nil for anything else.
// ponytail: IPv4 only; stunAddress asks over IPv4.
func stunMappedAddress(_ data: Data, transaction: [UInt8]) -> String? {
    let b = [UInt8](data)
    guard b.count >= 20, b[0] == 0x01, b[1] == 0x01, Array(b[4..<8]) == stunCookie, Array(b[8..<20]) == transaction else { return nil }
    var plain: String?
    var i = 20
    while i + 4 <= b.count {
        let type = Int(b[i]) << 8 | Int(b[i + 1]), length = Int(b[i + 2]) << 8 | Int(b[i + 3])
        let value = b.dropFirst(i + 4).prefix(length)
        if value.count == 8, value[value.startIndex + 1] == 0x01 {
            let address = value.suffix(4)
            if type == 0x0020 { return zip(address, stunCookie).map { String($0 ^ $1) }.joined(separator: ".") }
            if type == 0x0001 { plain = address.map(String.init).joined(separator: ".") }
        }
        i += 4 + (length + 3) / 4 * 4
    }
    return plain
}

/// The address `host` saw a UDP request from this Mac come from, as a page's WebRTC would learn it.
/// Over IPv4, so it compares with the IPv4 exit; the IPv6 check covers the rest.
func stunAddress(_ host: String, _ port: UInt16, timeout: TimeInterval = 4) async -> String? {
    let parameters = NWParameters.udp
    (parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options)?.version = .v4
    let connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: parameters)
    let transaction = (0..<12).map { _ in UInt8.random(in: 0...255) }
    return await withCheckedContinuation { cont in
        let once = Once()
        let finish: (String?) -> Void = { result in
            guard once.claim() else { return }
            connection.cancel()
            cont.resume(returning: result)
        }
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                connection.send(content: stunRequest(transaction), completion: .contentProcessed { if $0 != nil { finish(nil) } })
                connection.receiveMessage { data, _, _, _ in finish(data.flatMap { stunMappedAddress($0, transaction: transaction) }) }
            case .failed, .cancelled, .waiting: finish(nil)
            default: break
            }
        }
        connection.start(queue: .global())
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { finish(nil) }
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

/// In the order they're asked. The raw value is the name the timeline shows.
enum Provider: String, CaseIterable {
    case ipWho = "ipwho.is", ipApi = "ipapi.co", ipInfo = "ipinfo.io"

    func fetch(_ ip: String) async throws -> Location {
        switch self {
        case .ipWho: try await fetchIpWho(ip)
        case .ipApi: try await fetchIpApi(ip)
        case .ipInfo: try await fetchIpInfo(ip)
        }
    }
}

private func string(_ d: [String: Any], _ key: String) -> String? { d[key] as? String }

/// ipapi.co is an independent HTTPS fallback. Neither provider's free tier supplies VPN flags.
func fetchIpApi(_ ip: String? = nil) async throws -> Location {
    let path = ip.map { $0 + "/" } ?? ""
    if let ip, !isIPAddress(ip) { throw HTTPError(status: -2) }
    return try parseIpApi(try await fetchJSON("https://ipapi.co/\(path)json/"))
}

func parseIpApi(_ d: [String: Any]) throws -> Location {
    guard d["error"] as? Bool != true, let ip = string(d, "ip"), isIPAddress(ip),
          let country = string(d, "country_code"), country.count == 2 else { throw HTTPError(status: -2) }
    return Location(ip: ip, country: string(d, "country_name"), countryCode: country.uppercased(),
                    region: string(d, "region"), city: string(d, "city"), isp: string(d, "org"),
                    asn: string(d, "asn").flatMap(asNumber), timeZone: string(d, "timezone"),
                    lat: d["latitude"] as? Double, lon: d["longitude"] as? Double)
}

/// ipwho.is over HTTPS — no VPN detection.
func fetchIpWho(_ ip: String? = nil) async throws -> Location {
    if let ip, !isIPAddress(ip) { throw HTTPError(status: -2) }
    return try parseIpWho(try await fetchJSON("https://ipwho.is/\(ip ?? "")"))
}

func parseIpWho(_ d: [String: Any]) throws -> Location {
    guard d["success"] as? Bool == true, let ip = string(d, "ip"), isIPAddress(ip),
          let country = string(d, "country_code"), country.count == 2 else { throw HTTPError(status: -2) }
    let connection = d["connection"] as? [String: Any] ?? [:]
    return Location(ip: ip, country: string(d, "country"),
                    countryCode: country.uppercased(), region: string(d, "region"), city: string(d, "city"),
                    isp: string(connection, "isp") ?? string(connection, "org"), asn: connection["asn"] as? Int, isVpn: nil,
                    timeZone: (d["timezone"] as? [String: Any]).flatMap { string($0, "id") },
                    lat: d["latitude"] as? Double, lon: d["longitude"] as? Double)
}

/// ipinfo.io, the third: ipapi.co turns away a VPN's shared addresses as rate-limited, which left ipwho.is alone.
func fetchIpInfo(_ ip: String) async throws -> Location {
    guard isIPAddress(ip) else { throw HTTPError(status: -2) }
    return try parseIpInfo(try await fetchJSON("https://ipinfo.io/\(ip)/json"))
}

func parseIpInfo(_ d: [String: Any]) throws -> Location {
    guard let ip = string(d, "ip"), isIPAddress(ip), let country = string(d, "country"), country.count == 2 else { throw HTTPError(status: -2) }
    // "AS9009 M247 Europe SRL", and "53.4809,-2.2374".
    let org = string(d, "org"), asn = org.flatMap(asNumber)
    let place = (string(d, "loc") ?? "").split(separator: ",").compactMap { Double($0) }
    return Location(ip: ip, country: Countries.name(country.uppercased()), countryCode: country.uppercased(),
                    region: string(d, "region"), city: string(d, "city"),
                    isp: asn == nil ? org : org?.split(separator: " ").dropFirst().joined(separator: " "), asn: asn,
                    timeZone: string(d, "timezone"), lat: place.count == 2 ? place[0] : nil, lon: place.count == 2 ? place[1] : nil)
}

func isIPAddress(_ text: String) -> Bool { IPv4Address(text) != nil || IPv6Address(text) != nil }

func lookupExit() async -> (Location, Provider)? {
    // A fresh IP echo checks the route every time; cache only that exact IP's metadata.
    for url in ["https://api.ipify.org", "https://ipv4.icanhazip.com"] {
        guard let data = try? await fetchData(url, timeout: 5),
              let ip = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              IPv4Address(ip) != nil else { continue }
        return await exitMetadata(ip)
    }
    return nil
}

@MainActor private var exitCache: (at: Date, location: Location, source: Provider)?

@MainActor func invalidateExitMetadata() { exitCache = nil }

@MainActor private func exitMetadata(_ ip: String) async -> (Location, Provider)? {
    if let hit = exitCache, hit.location.ip == ip, hit.at.timeIntervalSinceNow > -3600 { return (hit.location, hit.source) }
    for source in Provider.allCases {
        guard let location = try? await source.fetch(ip), location.ip == ip else { continue }
        exitCache = (Date(), location, source)
        return (location, source)
    }
    return nil
}

func confirmLocationViolation(_ primary: Location, source: Provider, reason: ViolationReason, settings: AppSettings) async -> Bool {
    guard let ip = primary.ip else { return false }
    // The first other provider to answer decides: one that's down or rate-limited is no opinion.
    var answer: Location?
    for other in Provider.allCases where other != source && answer == nil { answer = try? await other.fetch(ip) }
    guard let second = answer, second.ip == ip, second.countryCode == primary.countryCode else { return false }
    if reason == .isp {
        guard let isp = second.isp else { return false }
        return !ispMatches(isp, settings.expectedIsps)
    }
    if reason == .profile {
        guard let profile = settings.activeProfile, second.asn == primary.asn,
              second.city?.lowercased() == primary.city?.lowercased() else { return false }
        return profileVerdict(second, profile).kind == .violation
    }
    return true
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

/// ip-api's "AS56655 Gigahost AS" → 56655.
func asNumber(_ text: String) -> Int? {
    text.split(separator: " ").first.flatMap { $0.hasPrefix("AS") ? Int($0.dropFirst(2)) : nil }
}

/// Whether two lookups found the same network. Each service names it its own way (ip-api: "TERRAHOST",
/// ipwho.is: "Gigahost AS"), so the AS number settles it when both have one.
func sameNetwork(_ a: Location, _ b: Location) -> Bool {
    if let x = a.asn, let y = b.asn { return x == y }
    return ispMatches(a.isp, [b.isp ?? ""])
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
