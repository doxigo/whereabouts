import Foundation

// Alibi, the companion Chrome extension, hears about a new VPN exit through Chrome native messaging.
// The app writes each new exit to alibi.json. Chrome launches this same binary as the host
// (`Whereabouts chrome-extension://<id>/`), which sends that cover, then every change to it, until
// Chrome hangs up or the app quits. Without a host, Alibi falls back to its own lookup once a minute.

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

/// One native message: its byte count in native byte order, then the JSON.
func nativeMessage(_ json: Data) -> Data { withUnsafeBytes(of: UInt32(json.count)) { Data($0) } + json }

enum AlibiHost {
    static let name = "com.doxigo.whereabouts"
    /// Alibi's ID wherever it's loaded from, pinned by the `key` in its manifest.json.
    static let origin = "chrome-extension://dhlpjjenplighmpbogjpmljbahbnjpfa/"
    static let exitURL = Store.dir.appendingPathComponent("alibi.json")
    /// The pid tells the host whether the app that wrote the exit is still running.
    private struct Exit: Codable { var pid: Int32; var cover: AlibiCover }
    @MainActor private static var published: AlibiCover?

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

    /// Hands a new exit to the host, if it moved.
    @MainActor static func publish(_ location: Location) {
        guard !Demo.enabled, let cover = alibiCover(location), cover != published,
              let data = try? JSONEncoder().encode(Exit(pid: getpid(), cover: cover)) else { return }
        try? FileManager.default.createDirectory(at: Store.dir, withIntermediateDirectories: true)
        if (try? data.write(to: exitURL, options: .atomic)) != nil { published = cover }
    }

    /// Host mode, Chrome's end of the pipe.
    static func serve() -> Never {
        // Chrome hangs up by closing stdin; Alibi never sends anything.
        Thread.detachNewThread {
            while !FileHandle.standardInput.availableData.isEmpty {}
            exit(0)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        var sent: Data?
        var appQuit: DispatchSourceProcess?
        func send() {
            // With the app not running there's nothing current to say. Hanging up hands Alibi back to its own lookup.
            guard let data = try? Data(contentsOf: exitURL), let exit = try? JSONDecoder().decode(Exit.self, from: data),
                  kill(exit.pid, 0) == 0, let cover = try? encoder.encode(exit.cover) else { Darwin.exit(0) }
            if appQuit == nil {
                appQuit = DispatchSource.makeProcessSource(identifier: exit.pid, eventMask: .exit, queue: .main)
                appQuit?.setEventHandler { Darwin.exit(0) }
                appQuit?.resume()
            }
            guard cover != sent else { return }
            FileHandle.standardOutput.write(nativeMessage(cover))
            sent = cover
        }
        // Atomic writes swap the file, so watch its folder. Other files there change too; `sent` filters those out.
        let watch = DispatchSource.makeFileSystemObjectSource(fileDescriptor: open(Store.dir.path, O_EVTONLY), eventMask: .write, queue: .main)
        watch.setEventHandler { send() }
        watch.resume()
        send()
        dispatchMain()
    }
}
