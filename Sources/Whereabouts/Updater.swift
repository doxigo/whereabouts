import Foundation

let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
let appBuild = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
let repoURL = URL(string: "https://github.com/doxigo/whereabouts")!

/// A GitHub release newer than this build.
struct Release {
    let version: String
    let page: URL
    /// The disk image to install from; nil if the release has none.
    let dmg: URL?
}

/// GitHub's latest-release JSON, if it's newer than `current`.
func newerRelease(_ json: [String: Any], than current: String) -> Release? {
    guard let tag = json["tag_name"] as? String,
          let page = (json["html_url"] as? String).flatMap(URL.init(string:)) else { return nil }
    let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
    guard version.compare(current, options: .numeric) == .orderedDescending else { return nil }
    let assets = json["assets"] as? [[String: Any]] ?? []
    let dmg = assets.first { ($0["name"] as? String)?.hasSuffix(".dmg") == true }?["browser_download_url"] as? String
    return Release(version: version, page: page, dmg: dmg.flatMap(URL.init(string:)))
}

/// Downloads the release's disk image, swaps its app in for this one and arranges a
/// relaunch once this process exits. Throws with this copy untouched when it can't be
/// done in place, e.g. running from the disk image or a folder the user can't write.
func installRelease(_ release: Release) async throws {
    guard let dmg = release.dmg else { throw CocoaError(.fileNoSuchFile) }
    let fm = FileManager.default
    let (file, response) = try await URLSession.shared.download(from: dmg)
    defer { try? fm.removeItem(at: file) }
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    guard status == 200 else { throw HTTPError(status: status) }

    let mount = fm.temporaryDirectory.appending(path: "Whereabouts-update-\(UUID().uuidString)")
    _ = try await run("/usr/bin/hdiutil", ["attach", file.path, "-nobrowse", "-readonly", "-mountpoint", mount.path], timeout: 120)
    defer { _ = try? runSync("/usr/bin/hdiutil", ["detach", mount.path, "-force"], timeout: 30) }

    let new = mount.appending(path: "Whereabouts.app")
    guard let bundle = Bundle(url: new), bundle.bundleIdentifier == Bundle.main.bundleIdentifier,
          bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String == release.version
    else { throw CocoaError(.fileReadCorruptFile) }

    // Stage on the app's own volume so the swap is a single rename, and only swap in a
    // copy whose signature still checks out: a half-copied app would never launch again.
    let app = Bundle.main.bundleURL
    let staging = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: app, create: true)
    defer { try? fm.removeItem(at: staging) }
    let copy = staging.appending(path: app.lastPathComponent)
    try fm.copyItem(at: new, to: copy)
    _ = try await run("/usr/bin/codesign", ["--verify", "--strict", copy.path], timeout: 30)
    _ = try fm.replaceItemAt(app, withItemAt: copy)

    // The path rides in as $0, so it needs no quoting.
    let relaunch = Process()
    relaunch.executableURL = URL(filePath: "/bin/sh")
    relaunch.arguments = ["-c", "while kill -0 \(getpid()) 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$0\"", app.path]
    try relaunch.run()
}
