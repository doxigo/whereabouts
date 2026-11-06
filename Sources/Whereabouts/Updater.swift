import Foundation
import Security

let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
let repoURL = URL(string: "https://github.com/doxigo/whereabouts")!

enum UpdateError: LocalizedError {
    case untrustedBuild, wrongSigner, invalidRelease
    var errorDescription: String? {
        switch self {
        case .untrustedBuild: "This build has no trusted signing identity. Download updates manually from GitHub."
        case .wrongSigner: "The update does not match this app's signing identity. The installed app was not changed."
        case .invalidRelease: "The update is not a valid Whereabouts release."
        }
    }
}

struct UpdateTrust {
    let requirement: SecRequirement
    let certificate: Data

    init(app: URL) throws {
        let code = try Self.code(at: app)
        var requirement: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(code, [], &requirement) == errSecSuccess, let requirement else {
            throw UpdateError.untrustedBuild
        }
        self.requirement = requirement
        certificate = try Self.certificate(of: code)
    }

    func validate(_ app: URL) throws {
        let code = try Self.code(at: app)
        guard SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures), requirement) == errSecSuccess,
              try Self.certificate(of: code) == certificate else { throw UpdateError.wrongSigner }
    }

    private static func code(at app: URL) throws -> SecStaticCode {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures), nil) == errSecSuccess
        else { throw UpdateError.untrustedBuild }
        return code
    }

    private static func certificate(of code: SecStaticCode) throws -> Data {
        var raw: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &raw) == errSecSuccess,
              let info = raw as? [String: Any],
              let flags = info[kSecCodeInfoFlags as String] as? UInt32, flags & 0x2 == 0,
              let certificates = info[kSecCodeInfoCertificates as String] as? [SecCertificate], let leaf = certificates.first
        else { throw UpdateError.untrustedBuild }
        return SecCertificateCopyData(leaf) as Data
    }
}

let canInstallUpdates = (try? UpdateTrust(app: Bundle.main.bundleURL)) != nil

func isReleaseURL(_ url: URL, download: Bool) -> Bool {
    url.scheme == "https" && url.host == "github.com" && url.user == nil && url.password == nil
        && url.path.hasPrefix("/doxigo/whereabouts/releases/" + (download ? "download/" : "tag/"))
}

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
          let page = (json["html_url"] as? String).flatMap(URL.init(string:)), isReleaseURL(page, download: false) else { return nil }
    let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
    guard version.compare(current, options: .numeric) == .orderedDescending else { return nil }
    let assets = json["assets"] as? [[String: Any]] ?? []
    let dmg = assets.first { ($0["name"] as? String)?.hasSuffix(".dmg") == true }?["browser_download_url"] as? String
    let url = dmg.flatMap(URL.init(string:)).flatMap { isReleaseURL($0, download: true) ? $0 : nil }
    return Release(version: version, page: page, dmg: url)
}

/// Downloads the release's disk image, swaps its app in for this one and arranges a
/// relaunch once this process exits. Throws with this copy untouched when it can't be
/// done in place, e.g. running from the disk image or a folder the user can't write.
func installRelease(_ release: Release) async throws {
    let trust = try UpdateTrust(app: Bundle.main.bundleURL)
    guard let dmg = release.dmg else { throw CocoaError(.fileNoSuchFile) }
    guard isReleaseURL(dmg, download: true) else { throw UpdateError.invalidRelease }
    let fm = FileManager.default
    let (file, response) = try await URLSession.shared.download(from: dmg)
    defer { try? fm.removeItem(at: file) }
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    guard status == 200, response.url?.scheme == "https" else { throw HTTPError(status: status) }

    let app = Bundle.main.bundleURL
    try await installDiskImage(file, replacing: app, version: release.version, trust: trust)

    // The path rides in as $0, so it needs no quoting.
    let relaunch = Process()
    relaunch.executableURL = URL(filePath: "/bin/sh")
    relaunch.arguments = ["-c", "while kill -0 \(getpid()) 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$0\"", app.path]
    try relaunch.run()
}

func installDiskImage(_ file: URL, replacing app: URL, version: String, trust: UpdateTrust) async throws {
    let fm = FileManager.default
    let mount = fm.temporaryDirectory.appending(path: "Whereabouts-update-\(UUID().uuidString)")
    _ = try await run("/usr/bin/hdiutil", ["attach", file.path, "-nobrowse", "-readonly", "-mountpoint", mount.path], timeout: 120)
    defer { _ = try? runSync("/usr/bin/hdiutil", ["detach", mount.path, "-force"], timeout: 30) }

    let new = mount.appending(path: "Whereabouts.app")
    guard let bundle = Bundle(url: new), bundle.bundleIdentifier == Bundle.main.bundleIdentifier,
          bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String == version
    else { throw CocoaError(.fileReadCorruptFile) }

    // Stage on the app's own volume so the swap is a single rename, and only swap in a
    // copy whose signature still checks out: a half-copied app would never launch again.
    let staging = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: app, create: true)
    defer { try? fm.removeItem(at: staging) }
    let copy = staging.appending(path: app.lastPathComponent)
    try fm.copyItem(at: new, to: copy)
    try trust.validate(copy)
    _ = try fm.replaceItemAt(app, withItemAt: copy)

}
