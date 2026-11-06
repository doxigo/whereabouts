import Foundation

@MainActor func updateIntegrationTest() async {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appending(path: "Whereabouts-update-test-\(UUID().uuidString)")
    do {
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let payload = root.appending(path: "payload")
        try fm.createDirectory(at: payload, withIntermediateDirectories: true)
        let candidate = payload.appending(path: "Whereabouts.app")
        try fm.copyItem(at: Bundle.main.bundleURL, to: candidate)
        let installed = root.appending(path: "Installed.app")
        try fm.copyItem(at: Bundle.main.bundleURL, to: installed)
        let marker = installed.appending(path: "old-installation")
        try Data("old".utf8).write(to: marker)

        let trust = try? UpdateTrust(app: Bundle.main.bundleURL)
        if let trust {
            try trust.validate(candidate)
            let disk = root.appending(path: "valid.dmg")
            _ = try await run("/usr/bin/hdiutil", ["create", "-srcfolder", payload.path, "-format", "UDZO", disk.path], timeout: 60)
            try await installDiskImage(disk, replacing: installed, version: appVersion, trust: trust)
            guard !fm.fileExists(atPath: marker.path), fm.fileExists(atPath: installed.appending(path: "Contents/MacOS/Whereabouts").path)
            else { throw UpdateError.invalidRelease }
            try trust.validate(installed)
            print("update selftest: signed DMG mounted, staged, verified, and replaced an isolated fixture")
        } else {
            print("update selftest: unsigned/ad-hoc build correctly disables installation; signed success path needs a signed build")
        }

        _ = try await run("/usr/bin/codesign", ["--force", "--sign", "-", candidate.path], timeout: 15)
        guard (try? UpdateTrust(app: candidate)) == nil else { throw UpdateError.invalidRelease }
        if let trust {
            let disk = root.appending(path: "untrusted.dmg")
            _ = try await run("/usr/bin/hdiutil", ["create", "-srcfolder", payload.path, "-format", "UDZO", disk.path], timeout: 60)
            var rejected = false
            do { try await installDiskImage(disk, replacing: installed, version: appVersion, trust: trust) }
            catch { rejected = true }
            guard rejected else { throw UpdateError.invalidRelease }
            try trust.validate(installed)
            print("update selftest: ad-hoc replacement rejected; installed fixture remains intact")
        }
        try Data("tampered".utf8).write(to: candidate.appending(path: "Contents/MacOS/Whereabouts"))
        guard (try? UpdateTrust(app: candidate)) == nil else { throw UpdateError.invalidRelease }
        print("update selftest: tampered code rejected; all checks passed")
        try fm.removeItem(at: root)
        exit(0)
    } catch {
        try? fm.removeItem(at: root)
        print("update selftest FAILED: \(error.localizedDescription)")
        exit(1)
    }
}
