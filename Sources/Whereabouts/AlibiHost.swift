import Foundation

// Alibi, the companion Chrome extension, hears about a new VPN exit through Chrome native messaging.
// The app writes each new exit to alibi.json. Chrome launches this same binary as the host
// (`Whereabouts chrome-extension://<id>/`), which sends that cover, then every change to it, until
// Chrome hangs up or the app quits. Without a host, Alibi falls back to its own lookup once a minute.
//
// The host says hello first, and whether it takes Alibi's cover: only while the app follows Alibi's
// location, so Alibi doesn't keep the port open for nothing. It says hello again if that changes. Alibi
// then sends its All sites cover whenever it changes (`{"cover": …}`). Each host keeps the one it heard
// in alibi-cover-<pid>.json and deletes it as it exits; the app skips any whose host is gone. With Match
// time zone and Follow Alibi's location on, the Mac's clock follows the place Alibi has you in. The host
// tells Alibi the zone the app holds the Mac on (`{"system": …}`), for Alibi's popup; Alibi keeps
// covering the zone itself.

/// What Alibi's "Match my IP address" cover is made of, built the way Alibi's own lookup builds it.
struct AlibiCover: Codable, Equatable {
    var timezone: String
    /// The country's most likely language, from CLDR: SE -> sv-SE.
    var locale: String
    var lat: Double?
    var lon: Double?
}

func alibiCover(_ l: Location) -> AlibiCover? {
    guard let zone = l.timeZone, TimeZone(identifier: zone) != nil, let code = l.countryCode,
          let language = Locale.Language(identifier: "und-\(code)").maximalIdentifier.split(separator: "-").first else { return nil }
    return AlibiCover(timezone: zone, locale: "\(language)-\(code)", lat: l.lat, lon: l.lon)
}

/// Alibi's All sites cover, as far as the Mac's clock goes: which kind it is, its zone and its locale.
struct AlibiWish: Codable, Equatable {
    var configuration: String
    var timezone: String?
    var locale: String?

    /// The zone of the place Alibi has you in, for the Mac to be held on. Off and "Match my IP address"
    /// name none: Alibi doesn't mind where the Mac is, so it follows the connection, as it does without Alibi.
    /// Neither does a zone the time zone helper wouldn't set.
    var zone: String? {
        guard configuration != "browserDefault", configuration != "ipAddress", let timezone,
              TimeZoneHelper.accepts(timezone) else { return nil }
        return timezone
    }
    /// That place's country, from its locale (sv-SE -> SE), for the Mac's region.
    var country: String? {
        guard zone != nil, let locale, let code = Locale(identifier: locale).region?.identifier,
              code.count == 2, code.allSatisfy(\.isLetter) else { return nil }
        return code
    }
}

/// One host's word: the cover its browser last sent, and when. The pid says whether that host still runs.
struct AlibiHeard: Codable, Equatable {
    var pid: Int32
    var heard: Date
    var cover: AlibiWish
}

/// The cover the Mac follows, from every running browser's: the newest one that names a place. Off and
/// Match my IP address ask nothing of the Mac, so they never outvote another browser's place. nil: no place.
func pickWish(_ heard: [AlibiHeard]) -> AlibiWish? {
    heard.filter { $0.cover.zone != nil }.max { $0.heard < $1.heard }?.cover
}

/// Alibi's All sites cover from one of its messages; nil for any other message, or one malformed.
func alibiWish(fromMessage data: Data) -> AlibiWish? {
    struct Message: Decodable { var cover: AlibiWish? }
    guard let wish = (try? JSONDecoder().decode(Message.self, from: data))?.cover,
          !wish.configuration.isEmpty, wish.configuration.count <= 64 else { return nil }
    if let zone = wish.timezone, TimeZone(identifier: zone) == nil { return nil }
    return wish
}

/// One native message: its byte count in native byte order, then the JSON.
func nativeMessage(_ json: Data) -> Data { withUnsafeBytes(of: UInt32(json.count)) { Data($0) } + json }

enum AlibiHost {
    static let name = "com.doxigo.whereabouts"
    /// Alibi's ID wherever it's loaded from, pinned by the `key` in its manifest.json.
    static let origin = "chrome-extension://dhlpjjenplighmpbogjpmljbahbnjpfa/"
    static let exitURL = Store.dir.appendingPathComponent("alibi.json")
    /// Alibi's All sites cover, as one host heard it: a file per host, so two browsers don't overwrite
    /// each other. The host deletes its own as it exits.
    static func wishURL(pid: Int32) -> URL { Store.dir.appendingPathComponent("alibi-cover-\(pid).json") }
    /// One file for every host, from before each host had its own, with nothing to say whether its
    /// browser still runs. Deleted at launch.
    static let oldWishURL = Store.dir.appendingPathComponent("alibi-cover.json")
    /// The pid tells the host whether the app that wrote the file is still running. The exit, once
    /// known; the zone the app holds the Mac on for Alibi, if it holds one.
    private struct Exit: Codable, Equatable { var pid: Int32; var cover: AlibiCover?; var system: String? }
    @MainActor private static var current = Exit(pid: getpid())
    @MainActor private static var written: Exit?

    /// Registers this copy as the host with Chrome and Brave. Runs at every launch, so a moved app re-registers.
    static func install() {
        guard let path = Bundle.main.executablePath,
              let manifest = try? JSONSerialization.data(withJSONObject: [
                  "name": name, "description": "Whereabouts tells Alibi where your VPN exit is",
                  "path": path, "type": "stdio", "allowed_origins": [origin],
              ], options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return }
        let support = Store.dir.deletingLastPathComponent()
        for browser in ["Google/Chrome", "BraveSoftware/Brave-Browser"] {
            let profile = support.appendingPathComponent(browser)
            guard FileManager.default.fileExists(atPath: profile.path) else { continue } // not installed
            let hosts = profile.appendingPathComponent("NativeMessagingHosts")
            do {
                try FileManager.default.createDirectory(at: hosts, withIntermediateDirectories: true)
                try manifest.write(to: hosts.appendingPathComponent("\(name).json"), options: .atomic)
            } catch {
                log.error("Couldn't register the Alibi host with \(browser): \(error.localizedDescription)")
            }
        }
    }

    /// Says the app runs, before its first check, so Alibi's cover reaches it from the start.
    @MainActor static func announce() {
        if !Demo.enabled { try? FileManager.default.removeItem(at: oldWishURL) }
        write()
    }

    /// Hands a new exit to the host, if it moved.
    @MainActor static func publish(_ location: Location) {
        guard let cover = alibiCover(location) else { return }
        current.cover = cover
        write()
    }

    /// Tells the host the zone the app holds the Mac on for Alibi's cover, or that it holds none.
    @MainActor static func publishSystem(_ zone: String?) {
        current.system = zone
        write()
    }

    @MainActor private static func write() {
        guard !Demo.enabled, current != written, let data = try? JSONEncoder().encode(current) else { return }
        try? FileManager.default.createDirectory(at: Store.dir, withIntermediateDirectories: true)
        if (try? data.write(to: exitURL, options: .atomic)) != nil { written = current }
    }

    /// Alibi's place for all sites, from the hosts of the browsers running now (pickWish); nil when none
    /// names one. A host killed outright leaves its file behind: that's deleted here, once its pid is gone.
    static func readWish() -> AlibiWish? {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: Store.dir.path) else { return nil }
        var heard: [AlibiHeard] = []
        for name in names where name.hasPrefix("alibi-cover-") && name.hasSuffix(".json") {
            let url = Store.dir.appendingPathComponent(name)
            // One that doesn't read may be mid-write: left alone.
            guard let data = try? Data(contentsOf: url), let one = try? JSONDecoder().decode(AlibiHeard.self, from: data) else { continue }
            guard kill(one.pid, 0) == 0 else {
                try? fm.removeItem(at: url)
                continue
            }
            heard.append(one)
        }
        return pickWish(heard)
    }

    /// The first message: what this host is, and whether it takes Alibi's cover now.
    static func helloMessage(takesCovers: Bool) -> Data {
        struct Hello: Encodable { var hello = "whereabouts"; var accepts: [String] }
        return encoded(Hello(accepts: takesCovers ? ["cover"] : []))
    }

    /// Whether the app follows Alibi's location now, as its settings say: Match time zone and Follow
    /// Alibi's location both on. Only then does Alibi's cover move the Mac.
    static func followsAlibi() -> Bool {
        guard let data = try? Data(contentsOf: Store.settingsURL),
              let settings = try? JSONDecoder().decode(AppSettings.self, from: data) else { return false }
        return settings.matchTimeZone && settings.followAlibi
    }

    /// The zone the app holds the Mac on, as `{"system": "…"}`, or `{"system": null}` for none.
    static func systemMessage(_ zone: String?) -> Data {
        struct System: Encodable {
            var system: String?
            enum CodingKeys: String, CodingKey { case system }
            func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                try c.encode(system, forKey: .system) // null, not left out
            }
        }
        return encoded(System(system: zone))
    }

    private static func encoded(_ value: some Encodable) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes] // Asia/Tokyo, not Asia\/Tokyo
        return (try? encoder.encode(value)) ?? Data("{}".utf8)
    }

    /// Host mode, Chrome's end of the pipe.
    static func serve() -> Never {
        let mine = wishURL(pid: getpid())
        // Every way out takes this host's cover with it, so the Mac never stays on a place that a
        // closed browser, or a removed Alibi, asked for.
        func leave() -> Never {
            try? FileManager.default.removeItem(at: mine)
            Darwin.exit(0)
        }
        // Chrome stops a host with SIGTERM (SIGKILL after a while, which readWish cleans up after). A write
        // to a pipe Chrome has closed fails instead of raising SIGPIPE, and the host leaves.
        signal(SIGPIPE, SIG_IGN)
        let stops = [SIGTERM, SIGINT, SIGHUP].map { number in
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { leave() }
            source.resume()
            return source
        }
        func say(_ json: Data) {
            do { try FileHandle.standardOutput.write(contentsOf: nativeMessage(json)) } catch { leave() }
        }
        var takes = followsAlibi()
        say(helloMessage(takesCovers: takes))
        // Alibi's messages, each a native message; Chrome hangs up by closing stdin.
        Thread.detachNewThread {
            let input = FileHandle.standardInput
            while true {
                let head = input.readData(ofLength: 4)
                guard head.count == 4 else { leave() }
                var left = Int(head.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })
                guard left <= 64 << 10 else {
                    // Far beyond anything Alibi sends: skip it.
                    while left > 0 {
                        let chunk = input.readData(ofLength: min(left, 64 << 10))
                        guard !chunk.isEmpty else { leave() }
                        left -= chunk.count
                    }
                    continue
                }
                let body = input.readData(ofLength: left)
                guard body.count == left else { leave() }
                if let wish = alibiWish(fromMessage: body), followsAlibi(),
                   let data = try? JSONEncoder().encode(AlibiHeard(pid: getpid(), heard: Date(), cover: wish)) {
                    try? FileManager.default.createDirectory(at: Store.dir, withIntermediateDirectories: true)
                    try? data.write(to: mine, options: .atomic)
                }
            }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        var sent: Data?
        var sentSystem: String??
        var appQuit: DispatchSourceProcess?
        func send() {
            // With the app not running there's nothing current to say. Hanging up hands Alibi back to its own lookup.
            guard let data = try? Data(contentsOf: exitURL), let exit = try? JSONDecoder().decode(Exit.self, from: data),
                  kill(exit.pid, 0) == 0 else { leave() }
            if appQuit == nil {
                appQuit = DispatchSource.makeProcessSource(identifier: exit.pid, eventMask: .exit, queue: .main)
                appQuit?.setEventHandler { leave() }
                appQuit?.resume()
            }
            if let cover = exit.cover.flatMap({ try? encoder.encode($0) }), cover != sent {
                say(cover)
                sent = cover
            }
            if sentSystem != .some(exit.system) {
                say(systemMessage(exit.system))
                sentSystem = .some(exit.system)
            }
            // The settings live in the same folder: switched in Settings, Alibi hears hello again, and
            // opens or closes the port to suit.
            let follows = followsAlibi()
            if follows != takes {
                takes = follows
                if !follows { try? FileManager.default.removeItem(at: mine) }
                say(helloMessage(takesCovers: follows))
            }
        }
        // Atomic writes swap the file, so watch its folder. Other files there change too; what was sent filters those out.
        let watch = DispatchSource.makeFileSystemObjectSource(fileDescriptor: open(Store.dir.path, O_EVTONLY), eventMask: .write, queue: .main)
        watch.setEventHandler { send() }
        watch.resume()
        send()
        withExtendedLifetime((watch, stops)) { dispatchMain() }
    }
}
