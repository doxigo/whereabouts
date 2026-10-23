import AppKit

if CommandLine.arguments.contains("--selftest") {
    selfTest()
    exit(0)
}

// Chrome passes the calling extension's origin to a native messaging host.
if CommandLine.arguments.dropFirst().first?.hasPrefix("chrome-extension://") == true {
    AlibiHost.serve()
}

MainActor.assumeIsolated {
    let delegate = AppDelegate()
    NSApplication.shared.delegate = delegate
    NSApplication.shared.setActivationPolicy(.accessory)
    NSApplication.shared.run()
}
